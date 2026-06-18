import SwiftUI
import PhotosCore
import DesignSystem
import MediaCache

public struct TimelineView: View {
    @State private var model: TimelineViewModel
    @Binding private var level: Int
    private let aspects: AspectRegistry
    private let onOpen: (PhotoItem, [PhotoItem]) -> Void
    private let proxy: GridProxy?
    private let selectionMode: Bool
    private let onSelectionChange: (Set<PhotoUID>) -> Void
    private let media: FullMediaProvider?
    private let favoriteUIDs: Set<PhotoUID>

    public init(
        model: TimelineViewModel,
        aspects: AspectRegistry,
        level: Binding<Int> = .constant(2),
        proxy: GridProxy? = nil,
        selectionMode: Bool = false,
        media: FullMediaProvider? = nil,
        favoriteUIDs: Set<PhotoUID> = [],
        onSelectionChange: @escaping (Set<PhotoUID>) -> Void = { _ in },
        onOpen: @escaping (PhotoItem, [PhotoItem]) -> Void = { _, _ in }
    ) {
        _model = State(initialValue: model)
        self.aspects = aspects
        _level = level
        self.proxy = proxy
        self.selectionMode = selectionMode
        self.media = media
        self.favoriteUIDs = favoriteUIDs
        self.onSelectionChange = onSelectionChange
        self.onOpen = onOpen
    }

    public var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProtonLoadingView(caption: "Building your library…")
            case .empty:
                emptyState
            case let .failed(message):
                errorState(message)
            case let .loaded(sections):
                // Precompute aspect ratios here (MainActor). Reading the registry establishes the
                // observation dependency, so the grid re-justifies as ratios are learned.
                let _ = aspects.version
                let sectionAspects = sections.map { section in
                    section.items.map { min(max(aspects.aspect(for: $0.uid), 0.45), 3.2) }
                }
                PhotoGridView(
                    sections: sections,
                    allItems: model.allItems,
                    feed: model.feed,
                    sectionAspects: sectionAspects,
                    level: $level,
                    onOpen: onOpen,
                    proxy: proxy,
                    selectionMode: selectionMode,
                    onSelectionChange: onSelectionChange,
                    favoriteUIDs: favoriteUIDs,
                    media: media
                )
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .background(ProtonColor.backgroundNorm)
        .task { await model.load() }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(ProtonColor.textHint)
            Text("No photos yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ProtonColor.textNorm)
            Text("Photos you upload to Proton will appear here.")
                .font(.system(size: 13))
                .foregroundStyle(ProtonColor.textWeak)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(ProtonColor.warning)
            Text("Couldn’t load your library")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ProtonColor.textNorm)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(ProtonColor.textWeak)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Retry") { Task { await model.load() } }
                .buttonStyle(.glassProminent)
                .frame(width: 140)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
