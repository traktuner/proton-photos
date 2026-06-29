import SwiftUI
import AppKit
import PhotosCore
import DesignSystem
import MediaCache

public struct TimelineView: View {
    @State private var model: TimelineViewModel
    @Binding private var level: Int
    /// Retained for source compatibility with the public init; the production grid no longer consults media
    /// aspect for layout (the engine is square-only; aspect lives only in `TileContentFitter`).
    private let aspects: AspectRegistry
    private let onOpen: (PhotoItem, [PhotoItem]) -> Void
    private let proxy: GridProxy?
    private let routeScrollGeneration: Int
    private let routeInitialScrollAnchor: GridScrollAnchor?
    private let searchText: String
    private let selectionMode: Bool
    private let onSelectionChange: (Set<PhotoUID>) -> Void
    private let media: FullMediaProvider?
    private let metadataProvider: PhotoMetadataProvider?
    private let favoriteUIDs: Set<PhotoUID>

    public init(
        model: TimelineViewModel,
        aspects: AspectRegistry,
        level: Binding<Int> = .constant(3),
        proxy: GridProxy? = nil,
        routeScrollGeneration: Int = 0,
        routeInitialScrollAnchor: GridScrollAnchor? = nil,
        searchText: String = "",
        selectionMode: Bool = false,
        media: FullMediaProvider? = nil,
        metadataProvider: PhotoMetadataProvider? = nil,
        favoriteUIDs: Set<PhotoUID> = [],
        onSelectionChange: @escaping (Set<PhotoUID>) -> Void = { _ in },
        onOpen: @escaping (PhotoItem, [PhotoItem]) -> Void = { _, _ in }
    ) {
        _model = State(initialValue: model)
        self.aspects = aspects
        _level = level
        self.proxy = proxy
        self.routeScrollGeneration = routeScrollGeneration
        self.routeInitialScrollAnchor = routeInitialScrollAnchor
        self.searchText = searchText
        self.selectionMode = selectionMode
        self.media = media
        self.metadataProvider = metadataProvider
        self.favoriteUIDs = favoriteUIDs
        self.onSelectionChange = onSelectionChange
        self.onOpen = onOpen
    }

    public var body: some View {
        Group {
            switch model.state {
            case .loading:
                // No heavy "Preparing Library" card: a faint shimmer skeleton (never a black screen) sits
                // behind the translucent loading veil applied below, so the surface stays visible through it.
                loadingGridSkeleton
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                emptyState
            case let .failed(message):
                errorState(message)
            case let .loaded(sections):
                let visibleSections = Self.filteredSections(
                    sections,
                    query: searchText,
                    context: TimelineSearchContext(activeFilter: model.filter, favoriteUIDs: favoriteUIDs)
                )
                let visibleItems = visibleSections.flatMap(\.items)
                // Production timeline is MetalGrid-ONLY: the canonical `SquareTileGridEngine` owns all
                // geometry (square slots). No legacy-grid fallback, no aspect-driven justified layout,
                // no silent feature-flag switch — media aspect never reaches the layout (it lives only in
                // `TileContentFitter`, inside the renderer).
                if visibleSections.isEmpty, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    searchEmptyState
                } else {
                    // Only the L4/L5 scrubber consumes markers; the full-library month scan at the common normal
                    // levels (L0–L3) would be wasted O(library) work, so derive only when it can be shown.
                    let monthMarkers = level >= 4
                        ? MetalGridProductionAdapter.dateMarkers(sections: visibleSections, granularity: .month)
                        : []
                    ZStack(alignment: .trailing) {
                        MetalProductionGridView(
                            sections: visibleSections,
                            allItems: visibleItems,
                            feed: model.feed,
                            level: $level,
                            routeScrollGeneration: routeScrollGeneration,
                            routeInitialScrollAnchor: routeInitialScrollAnchor,
                            onOpen: onOpen,
                            proxy: proxy,
                            selectionMode: selectionMode,
                            onSelectionChange: onSelectionChange,
                            favoriteUIDs: favoriteUIDs,
                            media: media,
                            metadataProvider: metadataProvider
                        )
                        .ignoresSafeArea(edges: .bottom)

                        if level >= 4, monthMarkers.count > 1 {
                            TimelineDateScrubber(markers: monthMarkers) { marker in
                                proxy?.scrollToFlatIndex?(marker.index)
                            }
                        }
                    }
                }
            }
        }
        .background(timelineSurfaceBackground)
        .task { await model.load() }
        .onAppear { MetalGridRuntime.logResolutionOnce() }
    }

    private var timelineSurfaceBackground: Color {
        Color(nsColor: MetalGridPalette.background)
    }

    private var loadingGridSkeleton: some View {
        GeometryReader { geometry in
            let columns = max(4, Int(geometry.size.width / 190))
            let spacing: CGFloat = 8
            let tileWidth = max(80, (geometry.size.width - CGFloat(columns + 1) * spacing) / CGFloat(columns))
            let tileHeight = max(72, tileWidth * 0.78)
            let rowCount = max(4, Int(geometry.size.height / (tileHeight + spacing)) + 1)
            VStack(spacing: spacing) {
                ForEach(0..<rowCount, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<columns, id: \.self) { column in
                            RoundedRectangle(cornerRadius: 7)
                                .fill(placeholderColor(row: row, column: column))
                                .frame(width: tileWidth, height: tileHeight)
                        }
                    }
                }
            }
            .padding(spacing)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .opacity(0.82)
            .allowsHitTesting(false)
        }
    }

    private func placeholderColor(row: Int, column: Int) -> Color {
        let phase = Double((row * 7 + column * 3) % 9) / 100
        return Color.white.opacity(0.045 + phase)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.string("empty.no_photos_title"), systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(L10n.string("empty.no_photos_description"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(timelineSurfaceBackground)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label(L10n.string("error.load_library_title"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .textSelection(.enabled)
        } actions: {
            Button(L10n.string("action.retry")) { Task { await model.load() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(timelineSurfaceBackground)
    }

    private var searchEmptyState: some View {
        ContentUnavailableView.search(text: searchText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(timelineSurfaceBackground)
    }

    nonisolated static func filteredSections(_ sections: [TimelineSection], query: String,
                                             context: TimelineSearchContext = TimelineSearchContext()) -> [TimelineSection] {
        TimelineSearch.filter(sections, query: query, context: context)
    }
}

private struct TimelineDateScrubber: View {
    let markers: [TimelineDateMarker]
    let onJump: (TimelineDateMarker) -> Void

    @State private var activeIndex: Int?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geometry in
            let active = activeIndex.flatMap { markers[safe: $0] }
            ZStack(alignment: .trailing) {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(width: hovering || active != nil ? 7 : 4)
                    .opacity(hovering || active != nil ? 0.72 : 0.22)
                    .padding(.trailing, 10)

                if let active, let index = activeIndex {
                    Text(active.text)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                        .position(x: geometry.size.width - 66,
                                  y: markerY(index: index, height: geometry.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = markerIndex(at: value.location.y, height: geometry.size.height)
                        guard activeIndex != index, let marker = markers[safe: index] else { return }
                        activeIndex = index
                        onJump(marker)
                    }
                    .onEnded { _ in activeIndex = nil }
            )
            .onHover { hovering = $0 }
        }
        .frame(width: hovering || activeIndex != nil ? 112 : 32)
        .padding(.trailing, 8)
        .padding(.vertical, 96)
        .allowsHitTesting(markers.count > 1)
    }

    private func markerIndex(at y: CGFloat, height: CGFloat) -> Int {
        guard markers.count > 1 else { return 0 }
        let normalized = min(max(y / max(height, 1), 0), 1)
        return min(markers.count - 1, max(0, Int((normalized * CGFloat(markers.count)).rounded(.down))))
    }

    private func markerY(index: Int, height: CGFloat) -> CGFloat {
        guard markers.count > 1 else { return height / 2 }
        let q = CGFloat(index) / CGFloat(markers.count - 1)
        return min(max(12, q * height), max(12, height - 12))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
