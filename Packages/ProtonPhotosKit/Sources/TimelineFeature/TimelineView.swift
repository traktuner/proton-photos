import SwiftUI
import AppKit
import PhotosCore
import DesignSystem
import GridCore
import TimelineCore

public struct TimelineView: View {
    @State private var model: TimelineViewModel
    @Binding private var level: Int
    /// Leading overlap of the floating sidebar (0 when collapsed). The grid lays its tiles out past this inset
    /// itself, but the SwiftUI placeholder/empty/error states are plain centered views - without this they'd
    /// center over the FULL detail width (which runs under the sidebar) and read as shifted too far left.
    @Environment(\.gridLeadingEventInset) private var leadingInset: CGFloat
    private let onOpen: (PhotoItem, [PhotoItem]) -> Void
    private let proxy: GridProxy<PhotoUID>?
    private let routeScrollGeneration: Int
    private let routeInitialScrollAnchor: GridScrollAnchor<PhotoUID>?
    private let searchText: String
    private let selectionMode: Bool
    private let onSelectionChange: (Set<PhotoUID>) -> Void
    private let media: FullMediaProvider?
    private let metadataProvider: PhotoMetadataProvider?
    private let favoriteUIDs: Set<PhotoUID>
    private let isOffline: Bool
    private let gridProfile: GridLevelProfile
    private let gridProfileResolver: TimelineGridProfileResolver?
    private let gridFillOrder: GridFillOrder
    private let initialViewportPlacement: TimelineInitialViewportPlacement

    public init(
        model: TimelineViewModel,
        level: Binding<Int>? = nil,
        gridProfile: GridLevelProfile = TimelineGridProfiles.productionDefaultProfile,
        gridFillOrder: GridFillOrder = .newestBottomTrailing,
        initialViewportPlacement: TimelineInitialViewportPlacement = .automatic,
        proxy: GridProxy<PhotoUID>? = nil,
        routeScrollGeneration: Int = 0,
        routeInitialScrollAnchor: GridScrollAnchor<PhotoUID>? = nil,
        searchText: String = "",
        selectionMode: Bool = false,
        media: FullMediaProvider? = nil,
        metadataProvider: PhotoMetadataProvider? = nil,
        favoriteUIDs: Set<PhotoUID> = [],
        isOffline: Bool = false,
        onSelectionChange: @escaping (Set<PhotoUID>) -> Void = { _ in },
        onOpen: @escaping (PhotoItem, [PhotoItem]) -> Void = { _, _ in }
    ) {
        _model = State(initialValue: model)
        _level = level ?? .constant(gridProfile.defaultLevel)
        self.gridProfile = gridProfile
        self.gridFillOrder = gridFillOrder
        self.initialViewportPlacement = initialViewportPlacement
        let productionConfig = TimelineGridProfileConfiguration.production
        self.gridProfileResolver = gridProfile == productionConfig.defaultProfile ? productionConfig.resolver : nil
        self.proxy = proxy
        self.routeScrollGeneration = routeScrollGeneration
        self.routeInitialScrollAnchor = routeInitialScrollAnchor
        self.searchText = searchText
        self.selectionMode = selectionMode
        self.media = media
        self.metadataProvider = metadataProvider
        self.favoriteUIDs = favoriteUIDs
        self.isOffline = isOffline
        self.onSelectionChange = onSelectionChange
        self.onOpen = onOpen
    }

    public var body: some View {
        Group {
            switch model.state {
            case .loading:
                // Route switches (RAW / album / trash …) show the same animated Proton mark as the app's launch
                // veil - never a black surface, never a stale grid. The leading inset keeps the 64pt mark
                // centered in the VISIBLE area when the floating sidebar is open.
                if isOffline {
                    OfflineContentUnavailableView()
                        .padding(.leading, leadingInset)
                } else {
                    LoadingMark()
                        .frame(width: 64, height: 64)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.leading, leadingInset)
                }
            case .empty:
                emptyState
                    .padding(.leading, leadingInset)
            case let .failed(message):
                if isOffline {
                    OfflineContentUnavailableView()
                        .padding(.leading, leadingInset)
                } else {
                    errorState(message)
                        .padding(.leading, leadingInset)
                }
            case .loaded:
                let showsMonthLabels = gridProfile.showsMonthLabels(level: level)
                let visibleContent = model.visibleContent(
                    searchText: searchText,
                    favoriteUIDs: favoriteUIDs,
                    includeMonthMarkers: showsMonthLabels
                )
                // Production timeline is MetalGrid-ONLY: the canonical `SquareTileGridEngine` owns all
                // geometry (square slots). No legacy-grid fallback, no aspect-driven justified layout,
                // no silent feature-flag switch - media aspect never reaches the layout (it lives only in
                // `TileContentFitter`, inside the renderer).
                if visibleContent.isEmptySearchResult {
                    searchEmptyState
                        .padding(.leading, leadingInset)
                } else {
                    ZStack(alignment: .trailing) {
                        MetalProductionGridView(
                            sections: visibleContent.sections,
                            allItems: visibleContent.items,
                            feed: model.feed,
                            level: $level,
                            routeScrollGeneration: routeScrollGeneration,
                            routeInitialScrollAnchor: routeInitialScrollAnchor,
                            gridProfile: gridProfile,
                            gridProfileResolver: gridProfileResolver,
                            gridFillOrder: gridFillOrder,
                            initialViewportPlacement: initialViewportPlacement,
                            onOpen: onOpen,
                            proxy: proxy,
                            selectionMode: selectionMode,
                            onSelectionChange: onSelectionChange,
                            favoriteUIDs: favoriteUIDs,
                            media: media,
                            metadataProvider: metadataProvider
                        )
                        .ignoresSafeArea(edges: .bottom)

                        if showsMonthLabels, visibleContent.monthMarkers.count > 1 {
                            TimelineDateScrubber(markers: visibleContent.monthMarkers) { marker in
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

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyStateCopy.title, systemImage: emptyStateCopy.systemImage)
        } description: {
            Text(emptyStateCopy.description)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(timelineSurfaceBackground)
    }

    private var emptyStateCopy: (title: String, description: String, systemImage: String) {
        switch model.filter {
        case .all:
            return (
                L10n.string("empty.no_photos_title"),
                L10n.string("empty.no_photos_description"),
                "photo.on.rectangle.angled"
            )
        case .tag(let tag):
            return (
                L10n.string("empty.filter_title \(tag.title)"),
                L10n.string("empty.filter_description"),
                tag.systemImage
            )
        case .album:
            return (
                L10n.string("empty.album_title"),
                L10n.string("empty.album_description"),
                "rectangle.stack"
            )
        case .trash:
            return (
                L10n.string("empty.trash_title"),
                L10n.string("empty.trash_description"),
                "trash"
            )
        case .map:
            return (
                L10n.string("empty.no_photos_title"),
                L10n.string("empty.no_photos_description"),
                "map"
            )
        }
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label(L10n.string("error.load_library_title"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .textSelection(.enabled)
        } actions: {
            Button(L10n.string("action.retry")) { Task { await model.retry() } }
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
                Color.clear
                    .frame(width: hovering || active != nil ? 7 : 4)
                    .protonGlass(in: Capsule(style: .continuous))
                    .opacity(hovering || active != nil ? 0.72 : 0.22)
                    .padding(.trailing, 10)

                if let active, let index = activeIndex {
                    Text(active.text)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .protonGlass(in: Capsule(style: .continuous))
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
