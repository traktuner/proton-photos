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
                libraryLoadingState
            case .empty:
                emptyState
            case let .failed(message):
                errorState(message)
            case let .loaded(sections):
                let visibleSections = Self.filteredSections(sections, query: searchText)
                let visibleItems = visibleSections.flatMap(\.items)
                // Production timeline is MetalGrid-ONLY: the canonical `SquareTileGridEngine` owns all
                // geometry (square slots). No legacy-grid fallback, no aspect-driven justified layout,
                // no silent feature-flag switch — media aspect never reaches the layout (it lives only in
                // `TileContentFitter`, inside the renderer).
                if visibleSections.isEmpty, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    searchEmptyState
                } else {
                    MetalProductionGridView(
                        sections: visibleSections,
                        allItems: visibleItems,
                        feed: model.feed,
                        level: $level,
                        onOpen: onOpen,
                        proxy: proxy,
                        selectionMode: selectionMode,
                        onSelectionChange: onSelectionChange,
                        favoriteUIDs: favoriteUIDs,
                        media: media,
                        metadataProvider: metadataProvider
                    )
                    .ignoresSafeArea(edges: .bottom)
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

    private var libraryLoadingState: some View {
        ZStack {
            timelineSurfaceBackground.ignoresSafeArea()
            loadingGridSkeleton
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.large)
                Text("Preparing Library")
                    .font(.headline)
                Text("Decrypting metadata and warming thumbnails")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Label("No photos yet", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Photos you upload to Proton will appear here.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(timelineSurfaceBackground)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t load your library", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .textSelection(.enabled)
        } actions: {
            Button("Retry") { Task { await model.load() } }
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

    nonisolated static func filteredSections(_ sections: [TimelineSection], query: String) -> [TimelineSection] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sections }
        return sections.compactMap { section in
            let sectionMatches = searchableText(for: section).contains(q)
            let items = sectionMatches ? section.items : section.items.filter { searchableText(for: $0).contains(q) }
            guard !items.isEmpty else { return nil }
            return TimelineSection(id: section.id, date: section.date, title: section.title, items: items)
        }
    }

    private nonisolated static func searchableText(for section: TimelineSection) -> String {
        [
            section.id,
            section.title,
            section.date.formatted(date: .abbreviated, time: .omitted),
            section.date.formatted(.dateTime.year().month().day())
        ]
        .joined(separator: " ")
        .lowercased()
    }

    private nonisolated static func searchableText(for item: PhotoItem) -> String {
        [
            item.uid.nodeID,
            item.uid.volumeID,
            item.mediaType,
            item.isVideo ? "video" : "photo",
            item.isLivePhoto ? "live photo" : "",
            item.captureTime.formatted(date: .abbreviated, time: .shortened),
            item.captureTime.formatted(.dateTime.year().month().day().hour().minute())
        ]
        .joined(separator: " ")
        .lowercased()
    }
}
