import SwiftUI
import PhotosCore
import DesignSystem
import MediaCache

public struct TimelineView: View {
    @State private var model: TimelineViewModel
    @Binding private var level: Int
    /// Production renderer selector. Default ON; the Settings ▸ Developer toggle / `MetalGrid.enabled`
    /// UserDefaults key / `-MetalGrid.enabled NO` launch arg flip it. The legacy NSCollectionView grid
    /// stays available as a fallback. Reactive so toggling rebuilds the grid.
    @AppStorage(MetalGridFeatureFlag.userDefaultsKey) private var metalEnabled = true
    private let aspects: AspectRegistry
    private let onOpen: (PhotoItem, [PhotoItem]) -> Void
    private let proxy: GridProxy?
    private let selectionMode: Bool
    private let onSelectionChange: (Set<PhotoUID>) -> Void
    private let media: FullMediaProvider?
    private let metadataProvider: PhotoMetadataProvider?
    private let favoriteUIDs: Set<PhotoUID>

    public init(
        model: TimelineViewModel,
        aspects: AspectRegistry,
        level: Binding<Int> = .constant(2),
        proxy: GridProxy? = nil,
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
                ProtonLoadingView(caption: "Building your library…")
            case .empty:
                emptyState
            case let .failed(message):
                errorState(message)
            case let .loaded(sections):
                if metalEnabled && MetalGridRuntime.isMetalRenderable {
                    // Production Metal-backed grid (default). The Apple-matched detent zoom needs per-item
                    // aspect ratios for its justified levels; reading `aspects.version` re-justifies as ratios
                    // are learned (memoized in the model, so a sidebar drag won't rebuild the whole library).
                    let _ = aspects.version
                    let metalAspects = model.sectionAspects(for: sections, registry: aspects)
                    MetalProductionGridView(
                        sections: sections,
                        allItems: model.allItems,
                        feed: model.feed,
                        sectionAspects: metalAspects,
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
                } else {
                    // Fallback: legacy NSCollectionView grid.
                    // Aspect ratios (MainActor). Reading the registry version establishes the observation
                    // dependency so the grid re-justifies as ratios are learned; the actual per-section
                    // array is memoized in the model so an unrelated re-render (e.g. a sidebar-width drag,
                    // which re-evaluates this body every tick) does not rebuild it for the whole library.
                    let _ = aspects.version
                    let sectionAspects = model.sectionAspects(for: sections, registry: aspects)
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
                        media: media,
                        metadataProvider: metadataProvider
                    )
                    .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .background(ProtonColor.backgroundNorm)
        .task { await model.load() }
        .onAppear { MetalGridRuntime.logResolutionOnce() }
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
