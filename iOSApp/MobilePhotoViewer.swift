import AVFoundation
import AVKit
import DesignSystemCore
import MediaByteCache
import MediaCacheUIKitAdapter
import PhotosCore
import PhotoViewerCore
import PhotoViewerUIKitAdapter
import SwiftUI
import UIKit

/// Native full-screen photo/video viewer. Paging + chrome live here (pure presentation); the media decoding,
/// titles, video-playback and pinch-to-close semantics come from shared `PhotoViewerCore` and the shared
/// backend - no viewer business logic is reimplemented per platform.
struct MobilePhotoViewer: View {
    let items: [PhotoItem]
    let startIndex: Int
    let libraryModel: MobileLibraryModel

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var chromeVisible = true
    /// Bounded, shared image loader for the pages (thumbnail → screen-bounded preview, off-main + cached) -
    /// the shared `PhotoViewerUIKitAdapter` store, wired to the feed's RAM tier via a closure so the
    /// adapter never depends on a concrete feed type.
    @State private var imageStore: UIKitViewerImageStore

    init(items: [PhotoItem], startIndex: Int, libraryModel: MobileLibraryModel) {
        self.items = items
        self.startIndex = startIndex
        self.libraryModel = libraryModel
        _index = State(initialValue: min(max(startIndex, 0), max(items.count - 1, 0)))
        let feed = libraryModel.thumbnailFeed
        // Seed/reuse the E2EE originals cache via the shared helper, injected as a closure so the viewer
        // adapter stays decoupled from the cache layer. When the viewer decrypts an original (a no-preview
        // item), it lands in the encrypted cache and later opens / shares reuse it before the network.
        let originalFetch: (@Sendable (PhotoUID) async throws -> Data)?
        if let backend = libraryModel.backend, let originals = libraryModel.originalsCache {
            let provider = EncryptedOriginalProvider(
                media: backend, cache: originals,
                policy: .persisting(capBytes: libraryModel.originalsCacheCapBytes)
            )
            originalFetch = { try await provider.originalData(for: $0) }
        } else {
            originalFetch = nil
        }
        _imageStore = State(initialValue: UIKitViewerImageStore(
            thumbnailProvider: { feed?.memoryImage(for: $0) },
            media: libraryModel.backend,
            originalDataOverride: originalFetch))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // UIKit pager (UIPageViewController) instead of SwiftUI's page TabView, for ONE reason: rotation.
            // The SwiftUI pager keeps its width-bound content offset and page size through a device rotation,
            // so the photo rotated displaced in a corner and snapped to centre only afterwards (a rebuild via
            // `.id` was a hard cut instead). UIPageViewController participates in the size transition and keeps
            // the current page centred through the whole rotation - the Photos-app behavior.
            MobileViewerPager(count: items.count, index: $index) { i, isCurrent in
                MobileViewerPage(
                    item: items[i],
                    isCurrent: isCurrent,
                    libraryModel: libraryModel,
                    imageStore: imageStore,
                    onToggleChrome: { withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() } },
                    onCloseRequested: { dismiss() }
                )
            }
            .ignoresSafeArea()

            if chromeVisible {
                chrome
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
        .task {
            // Register the viewer's transient display cache with the shared memory governor (identity-keyed:
            // a newly opened viewer replaces the previous registration; the weak capture makes a dismissed
            // viewer's handler a no-op). Under `.minimal` the store purges every page except the visible one.
            UIKitMemoryPressureCoordinator.shared.attach(imageStore, key: "viewerImageStore") { [weak imageStore] tier in
                imageStore?.applyMemoryPressure(scale: tier.budgetScale, purge: tier.requiresImmediatePurge)
            }
        }
    }

    private var chrome: some View {
        VStack {
            HStack(alignment: .top) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .protonGlass(in: Circle())
                }
                .accessibilityLabel(String(localized: "viewer.close_a11y"))

                Spacer()

                if items.indices.contains(index) {
                    let title = ViewerTitleFormatter.make(
                        captureDate: items[index].captureTime,
                        index: index,
                        total: items.count
                    )
                    VStack(spacing: 1) {
                        Text(title.line1)
                            .font(.subheadline.weight(.semibold))
                        Text(title.line2)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .foregroundStyle(.white)
                    .lineLimit(1)
                }

                Spacer()

                // Balances the close button so the title stays centered.
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Spacer()
        }
    }
}

/// Native horizontal photo pager: `UIPageViewController(.scroll)` hosting the SwiftUI pages. Chosen over
/// SwiftUI's `TabView(.page)` because it participates in the device-rotation size transition - the current
/// page stays centred and refits THROUGH the rotation animation instead of snapping afterwards. Selection
/// syncs both ways via the `index` binding; `isCurrent` is re-injected into every live page on change, so
/// pages keep their bounded load/teardown behavior (current page only).
private struct MobileViewerPager<Page: View>: UIViewControllerRepresentable {
    let count: Int
    @Binding var index: Int
    @ViewBuilder let page: (Int, Bool) -> Page

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 12]   // the small black gutter between pages, like Photos
        )
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.view.backgroundColor = .clear
        pvc.setViewControllers([context.coordinator.pageController(at: index)], direction: .forward, animated: false)
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        // External index change (e.g. programmatic) → jump to that page; user swipes come back via the delegate.
        if let visible = (pvc.viewControllers?.first as? HostedPage)?.pageIndex, visible != index {
            pvc.setViewControllers([context.coordinator.pageController(at: index)],
                                   direction: visible < index ? .forward : .reverse, animated: false)
        }
        context.coordinator.refreshLivePages()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// Hosts one page and remembers which index it shows (the pager's data source is index-based).
    final class HostedPage: UIHostingController<AnyView> {
        let pageIndex: Int
        init(index: Int, root: AnyView) {
            self.pageIndex = index
            super.init(rootView: root)
            view.backgroundColor = .clear   // never flash the hosting default background between pages
        }
        @available(*, unavailable)
        @MainActor required dynamic init?(coder: NSCoder) { fatalError("not supported") }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: MobileViewerPager
        /// Live pages by index, kept to a window around the requested page. Evicted pages are still retained
        /// by UIPageViewController while on screen; we only lose SwiftUI-state reuse, and the viewer store's
        /// cache makes a re-created page's image instant.
        private var live = [Int: HostedPage]()

        init(parent: MobileViewerPager) { self.parent = parent }

        func pageController(at i: Int) -> HostedPage {
            if let vc = live[i] { return vc }
            let vc = HostedPage(index: i, root: AnyView(parent.page(i, i == parent.index)))
            live[i] = vc
            live = live.filter { abs($0.key - i) <= 2 }
            return vc
        }

        /// Re-inject `isCurrent` into every live page after a selection change, preserving the pages'
        /// current-only load/teardown gating.
        func refreshLivePages() {
            for (i, vc) in live { vc.rootView = AnyView(parent.page(i, i == parent.index)) }
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let i = (viewController as? HostedPage)?.pageIndex, i > 0 else { return nil }
            return pageController(at: i - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let i = (viewController as? HostedPage)?.pageIndex, i < parent.count - 1 else { return nil }
            return pageController(at: i + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let i = (pageViewController.viewControllers?.first as? HostedPage)?.pageIndex else { return }
            parent.index = i   // binding write → SwiftUI update → refreshLivePages flips isCurrent
        }
    }
}

/// A single viewer page - a zoomable image, or a native video player for video items.
private struct MobileViewerPage: View {
    let item: PhotoItem
    let isCurrent: Bool
    let libraryModel: MobileLibraryModel
    let imageStore: UIKitViewerImageStore
    let onToggleChrome: () -> Void
    let onCloseRequested: () -> Void

    var body: some View {
        if item.isVideo {
            MobileVideoPage(
                item: item,
                isCurrent: isCurrent,
                libraryModel: libraryModel,
                onCloseRequested: onCloseRequested
            )
        } else {
            MobileImagePage(
                item: item,
                isCurrent: isCurrent,
                imageStore: imageStore,
                streamer: libraryModel.backend,
                onToggleChrome: onToggleChrome,
                onCloseRequested: onCloseRequested
            )
        }
    }
}

/// Staged, bounded page loading (thumbnail → screen-bounded display image): the grid thumbnail shows instantly,
/// then - for the CURRENT page ONLY - a mid-size preview or bounded original fallback is fetched and decoded
/// off-main to a screen-bounded size and swapped in. Swipe-preview neighbours never fetch/decode (no fan-out),
/// and swiping away cancels an in-flight load (the `.task(id:)` re-runs on the isCurrent flip). No full-resolution
/// decode just because a page appeared.
private struct MobileImagePage: View {
    let item: PhotoItem
    let isCurrent: Bool
    let imageStore: UIKitViewerImageStore
    /// The shared streamer used to preload a Live Photo's paired motion clip (nil for non-Live items).
    let streamer: (any VideoStreamProvider)?
    let onToggleChrome: () -> Void
    let onCloseRequested: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    /// The displayed photo rect (aspect-fit area, zoom/pan-transformed) in page coordinates, reported live by
    /// the zoomable scroll view. Anchors the Live badge and the motion overlay to the PHOTO, not the viewer.
    @State private var photoFrame: CGRect?
    /// In-flight zoom-tier decode - replaced (cancelling the old fetch) when the zoom settles elsewhere.
    @State private var zoomDecodeTask: Task<Void, Never>?
    /// The decode cap of the image currently DISPLAYED (0 = grid thumbnail). Tier assignments are gated on
    /// `newCap >= displayedCap`, so a slower base-tier load can never DOWNGRADE a sharper zoom decode that
    /// landed while it was still in flight.
    @State private var displayedCap = 0
    /// Shared Live Photo motion controller for the current page.
    @State private var motion = LivePhotoMotionController()

    /// Shared still-to-motion transition timing.
    private let transition = ViewerMediaTransitionStyle.standard
    private struct LoadToken: Equatable { let uid: PhotoUID; let current: Bool }

    var body: some View {
        ZStack {
            if let image {
                MobileZoomableImage(
                    image: image,
                    onSingleTap: onToggleChrome,
                    onCloseRequested: onCloseRequested,
                    onMotionStart: item.isLivePhoto ? { motion.play() } : nil,
                    onMotionStop: item.isLivePhoto ? { motion.stop() } : nil,
                    onPhotoFrameChanged: { photoFrame = $0 },
                    onZoomSettled: { loadZoomedDecodeIfNeeded(zoom: $0) }
                )
            } else {
                ProgressView().tint(.white)
            }

            // The paired motion clip, crossfaded in over the still while the press is held (once preloaded).
            // Framed to the DISPLAYED photo rect (zoom- and pan-transformed), so a zoomed-in Live Photo plays
            // its motion at the same zoom/position as the still - never an unzoomed clip floating on top.
            if item.isLivePhoto, let player = motion.player {
                if let pf = photoFrame {
                    MobileMotionPlayerLayer(player: player)
                        .frame(width: pf.width, height: pf.height)
                        .position(x: pf.midX, y: pf.midY)
                        .allowsHitTesting(false)
                        .opacity(motion.isPlaying ? 1 : 0)
                        .animation(.easeInOut(duration: transition.opacityDuration), value: motion.isPlaying)
                } else {
                    MobileMotionPlayerLayer(player: player)
                        .allowsHitTesting(false)
                        .opacity(motion.isPlaying ? 1 : 0)
                        .animation(.easeInOut(duration: transition.opacityDuration), value: motion.isPlaying)
                }
            }

            // The LIVE affordance - GLUED to the photo's top-left corner (not the viewer's). When zoom/pan
            // pushes that corner off-screen, the badge clamps to the viewer's edge instead of leaving it.
            if item.isLivePhoto {
                MobileLiveBadge()
                    .opacity(motion.isPlaying ? 0 : 1)
                    .animation(.easeInOut(duration: transition.opacityDuration), value: motion.isPlaying)
                    .modifier(MobilePhotoAnchoredTopLeading(photoFrame: photoFrame))
                    .allowsHitTesting(false)
            }
        }
        // Gentle scale under the still-to-motion crossfade.
        .scaleEffect(motion.isPlaying ? transition.liveMotionScale : 1)
        .animation(.easeInOut(duration: transition.scaleDuration), value: motion.isPlaying)
        .task(id: LoadToken(uid: item.uid, current: isCurrent)) {
            prepareOrStopMotion()
            await load()
        }
        .onAppear {
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice("[ViewerPerf] page appear uid=\(MobileViewerLog.short(item.uid), privacy: .public) current=\(isCurrent) kind=photo")
            }
        }
        .onDisappear {
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice("[ViewerPerf] page disappear uid=\(MobileViewerLog.short(item.uid), privacy: .public)")
            }
            motion.teardown()
        }
    }

    /// Preloads motion only for the visible Live Photo page.
    private func prepareOrStopMotion() {
        guard item.isLivePhoto else { return }
        if isCurrent {
            motion.prepare(for: item, streamer: streamer) { isCurrent }
        } else {
            motion.teardown()
        }
    }

    private func load() async {
        // 1. Immediate grid thumbnail.
        if image == nil, let thumb = imageStore.thumbnail(for: item.uid) {
            image = thumb
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice("[ViewerPerf] display uid=\(MobileViewerLog.short(item.uid), privacy: .public) tier=thumbnail")
            }
        }
        // 2. Screen-bounded preview for the current page only.
        guard ViewerImageLoadPolicy.shouldLoadDisplay(distanceFromCurrent: isCurrent ? 0 : 1) else { return }
        // Use the screen as the decode bound; transition geometry can be temporarily thumbnail-sized.
        let cap = ViewerImageLoadPolicy.displayMaxPixelSize(viewportPoints: UIScreen.main.bounds.size, scale: displayScale)
        if let display = await imageStore.displayImage(for: item.uid, maxPixelSize: cap), !Task.isCancelled,
           cap >= displayedCap {
            image = display.image
            displayedCap = cap
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice("[ViewerPerf] display uid=\(MobileViewerLog.short(item.uid), privacy: .public) tier=\(display.source, privacy: .public)")
            }
        }
        // 3. Original bytes, still decoded to the bounded screen cap.
        guard !Task.isCancelled else { return }
        if let original = await imageStore.originalImage(for: item.uid, maxPixelSize: cap), !Task.isCancelled,
           cap >= displayedCap {
            image = original.image
            displayedCap = cap
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice("[ViewerPerf] display uid=\(MobileViewerLog.short(item.uid), privacy: .public) tier=\(original.source, privacy: .public)")
            }
        }
    }

    /// Zoom settled beyond fit → decode the original at the size this zoom actually needs and swap it in.
    /// The swap is SEAMLESS by construction: only `UIImageView.image` changes (same aspect ratio), the scroll
    /// view's zoomScale/contentOffset are untouched, so nothing moves - the pixels just get sharper. The store
    /// serves the bytes from the E2EE originals cache (already fetched by the base tier) and its
    /// `decodedCap` cache gate turns repeat settles at the same zoom into instant hits.
    private func loadZoomedDecodeIfNeeded(zoom: CGFloat) {
        guard zoom > 1.01, isCurrent else { return }
        let cap = ViewerImageLoadPolicy.zoomedMaxPixelSize(
            viewportPoints: UIScreen.main.bounds.size, scale: displayScale, zoom: zoom)
        zoomDecodeTask?.cancel()
        zoomDecodeTask = Task {
            guard let sharp = await imageStore.originalImage(for: item.uid, maxPixelSize: cap),
                  !Task.isCancelled else { return }
            image = sharp.image
            displayedCap = max(displayedCap, cap)
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice("[ViewerPerf] display uid=\(MobileViewerLog.short(item.uid), privacy: .public) tier=zoomed cap=\(cap)")
            }
        }
    }
}

/// Positions content at the photo's top-left corner (inset), clamping to the viewer's edges when zoom/pan
/// pushes that corner off-screen - the badge sticks to the photo but never leaves the viewer. Falls back to
/// the classic viewer-corner placement until the first photo frame arrives.
private struct MobilePhotoAnchoredTopLeading: ViewModifier {
    let photoFrame: CGRect?
    /// Inset from the photo's corner, and the minimum distance the badge keeps from the viewer edges
    /// (top clearance leaves room for the chrome's close/title row).
    private static let inset: CGFloat = 12
    private static let minTop: CGFloat = 64

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let anchor = anchorPoint(in: proxy.size)
            content
                .fixedSize()
                .position(x: anchor.x, y: anchor.y)
        }
    }

    private func anchorPoint(in viewport: CGSize) -> CGPoint {
        // Approximate badge half-size for centering via .position (the badge is a small fixed capsule).
        let half = CGSize(width: 34, height: 14)
        guard let pf = photoFrame else {
            return CGPoint(x: 16 + half.width, y: Self.minTop + half.height)
        }
        let x = max(pf.minX + Self.inset, Self.inset) + half.width
        let y = max(pf.minY + Self.inset, Self.minTop) + half.height
        // Never past the viewer's right/bottom edge either (extreme pans).
        return CGPoint(
            x: min(x, viewport.width - Self.inset - half.width),
            y: min(y, viewport.height - Self.inset - half.height)
        )
    }
}

/// Native video playback via AVKit over the shared `VideoStreamProvider` streaming asset. Until playback
/// visibly starts, the grid's thumbnail stands in as a poster with a native centered spinner - never a
/// black hole. A two-finger pinch (which the player's tap-driven controls ignore) shrinks the page onto
/// the fingers and either springs back or closes, same shared policy as photos.
private struct MobileVideoPage: View {
    let item: PhotoItem
    let isCurrent: Bool
    let libraryModel: MobileLibraryModel
    let onCloseRequested: () -> Void

    @State private var player: AVPlayer?
    /// The streaming asset is the ONLY strong owner of the range resource-loader, which AVFoundation holds
    /// weakly - it must live as long as the player, or every protonvideo:// range request goes unserved.
    @State private var streamingAsset: StreamingVideoAsset?
    @State private var failed = false
    @State private var poster: UIImage?
    /// Set by the periodic time observer on the first advancing playback time - the moment frames are
    /// actually rendering, which is when the poster and spinner may leave.
    @State private var playbackStarted = false
    @State private var timeObserverBox = VideoTimeObserverBox()
    @State private var pinch = ViewerPinchState()
    @State private var drag = ViewerDragState()
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if failed {
                ContentUnavailableView(
                    L10n.string("viewer.playback_failed"),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.white)
            }

            if !failed && !playbackStarted {
                // Poster + native centered spinner until the first frame is on screen. Hit-testing stays
                // off so the player's own controls are never blocked.
                ZStack {
                    if let poster {
                        Image(uiImage: poster)
                            .resizable()
                            .scaledToFit()
                    }
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .scaleEffect(pinch.displayScale * drag.scale, anchor: drag.isActive ? .center : pinch.anchor)
        .offset(drag.offset)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .simultaneousGesture(pinchToCloseGesture)
        .simultaneousGesture(dragToDismissGesture)
        .task(id: LoadToken(uid: item.uid, current: isCurrent)) { await prepare() }
        .onChange(of: isCurrent) { _, current in
            if current { player?.play() } else { player?.pause() }
        }
        .onAppear {
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice("[ViewerPerf] page appear uid=\(MobileViewerLog.short(item.uid), privacy: .public) current=\(isCurrent) kind=video")
            }
        }
        .onDisappear {
            if MobileViewerLog.isEnabled {
                MobileViewerLog.logger.notice("[ViewerPerf] page disappear uid=\(MobileViewerLog.short(item.uid), privacy: .public)")
            }
            teardown()
        }
    }

    private struct LoadToken: Equatable { let uid: PhotoUID; let current: Bool }

    /// One-finger drag-to-close: engages only on a clearly VERTICAL drag (shared policy), tracks the finger with a
    /// gentle shrink, and on release closes the viewer or springs back. Simultaneous, so the page TabView keeps its
    /// horizontal paging swipe and the player's tap-driven transport controls keep working untouched.
    private var dragToDismissGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if !drag.isActive {
                    guard ViewerDragDismissPolicy.engages(translation: value.translation, isZoomedIn: false) else { return }
                    drag.isActive = true
                }
                let progress = ViewerDragDismissPolicy.progress(
                    translationY: value.translation.height, viewportHeight: viewportHeight)
                drag.offset = value.translation
                drag.scale = ViewerDragDismissPolicy.displayScale(progress: progress)
            }
            .onEnded { value in
                guard drag.isActive else { return }
                drag.isActive = false
                if ViewerDragDismissPolicy.shouldDismiss(
                    translationY: value.translation.height, velocityY: value.velocity.height,
                    viewportHeight: viewportHeight) {
                    onCloseRequested()
                } else {
                    withAnimation(.spring(
                        duration: ViewerDragDismissPolicy.springBackDuration,
                        bounce: 1 - Double(ViewerDragDismissPolicy.springBackDamping)
                    )) {
                        drag.offset = .zero
                        drag.scale = 1
                    }
                }
            }
    }

    /// Two-finger pinch-to-close: engages only on a pinch-in (shared policy), scales the page about the
    /// pinch anchor, and on release either closes the viewer or springs back. Simultaneous, so the player's
    /// tap-driven transport controls keep working untouched.
    private var pinchToCloseGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if !pinch.isActive {
                    guard ViewerPinchDismissPolicy.engages(gestureScale: value.magnification, isZoomedIn: false)
                    else { return }
                    pinch.isActive = true
                    pinch.anchor = value.startAnchor
                }
                pinch.displayScale = ViewerPinchDismissPolicy.displayScale(gestureScale: value.magnification)
            }
            .onEnded { value in
                guard pinch.isActive else { return }
                pinch.isActive = false
                if ViewerPinchDismissPolicy.shouldDismiss(releaseScale: value.magnification) {
                    onCloseRequested()
                } else {
                    withAnimation(.spring(
                        duration: ViewerPinchDismissPolicy.springBackDuration,
                        bounce: 1 - Double(ViewerPinchDismissPolicy.springBackDamping)
                    )) {
                        pinch.displayScale = 1
                    }
                }
            }
    }

    private func prepare() async {
        // Poster (grid thumbnail) shows instantly on any page. The player + streaming resource loader are created
        // ONLY for the current page - a swipe-preview neighbour never spins up an AVPlayer / network loader.
        if poster == nil {
            poster = libraryModel.thumbnailFeed?.memoryImage(for: item.uid)
        }
        guard isCurrent, player == nil, let backend = libraryModel.backend else { return }
        if MobileViewerLog.isEnabled {
            MobileViewerLog.logger.notice("[ViewerPerf] video prepare start uid=\(MobileViewerLog.short(item.uid), privacy: .public)")
        }
        do {
            let streaming = try await backend.makeStreamingAsset(for: item.uid)
            guard !Task.isCancelled else { return }   // swiped away before the asset resolved → don't attach a player
            let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: streaming.asset))
            streamingAsset = streaming   // retain the resource loader for the player's lifetime
            player = newPlayer
            observeFirstFrame(of: newPlayer)
            if isCurrent { newPlayer.play() }
        } catch {
            failed = true
        }
    }

    /// A playback time that actually advances is the reliable "frames are on screen" signal - player/item
    /// status flips to ready well before the first frame renders, which would flash black.
    private func observeFirstFrame(of player: AVPlayer) {
        timeObserverBox.remove()
        timeObserverBox.observe(player: player, interval: CMTime(value: 1, timescale: 10)) { time in
            guard !playbackStarted, time.seconds > 0.05, player.timeControlStatus == .playing else { return }
            withAnimation(.easeOut(duration: 0.2)) { playbackStarted = true }
            timeObserverBox.remove()
        }
    }

    private func teardown() {
        timeObserverBox.remove()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        streamingAsset = nil
    }
}

/// Live pinch-to-close state for the SwiftUI (video) page.
private struct ViewerPinchState {
    var isActive = false
    var displayScale: CGFloat = 1
    var anchor: UnitPoint = .center
}

/// Live one-finger drag-to-close state for the SwiftUI (video) page.
private struct ViewerDragState {
    var isActive = false
    var offset: CGSize = .zero
    var scale: CGFloat = 1
}

/// Owns an `AVPlayer` periodic time-observer token - the token must be removed from the SAME player
/// instance it was added to, which a plain `@State Any?` cannot guarantee across view updates.
private final class VideoTimeObserverBox {
    private var token: Any?
    private weak var player: AVPlayer?

    func observe(player: AVPlayer, interval: CMTime, handler: @escaping (CMTime) -> Void) {
        remove()
        self.player = player
        token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main, using: handler)
    }

    func remove() {
        if let token, let player {
            player.removeTimeObserver(token)
        }
        token = nil
        player = nil
    }
}

/// UIScrollView-backed zoomable image: pinch + double-tap to zoom, single-tap toggles chrome. At minimum zoom
/// the scroll view does not pan, so the enclosing page TabView keeps its swipe - and a pinch-IN at minimum
/// zoom hands the image to the shared pinch-to-close interaction (`ViewerPinchDismissPolicy`): it sticks to
/// the fingers, springs back below the threshold, closes past it.
private struct MobileZoomableImage: UIViewRepresentable {
    let image: UIImage
    let onSingleTap: () -> Void
    let onCloseRequested: () -> Void
    /// Live Photo long-press: press-and-hold plays the paired motion clip, release stops it. Nil for a non-Live
    /// photo, in which case no long-press recognizer is installed.
    var onMotionStart: (() -> Void)? = nil
    var onMotionStop: (() -> Void)? = nil
    /// Reports the DISPLAYED photo rect (the aspect-fit image area, zoom- and pan-transformed) in the page's
    /// coordinate space whenever layout/zoom/pan changes it. Drives the photo-anchored Live badge and the
    /// motion overlay's geometry, so both stay glued to the photo instead of the viewer.
    var onPhotoFrameChanged: ((CGRect) -> Void)? = nil
    /// Fired when a zoom gesture/animation SETTLES, with the final zoom scale - the page uses it to swap in a
    /// sharper decode sized for that zoom (never during the gesture, so the interaction stays fluid).
    var onZoomSettled: ((CGFloat) -> Void)? = nil

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4
        scrollView.minimumZoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        // Pinch-to-close rides alongside the scroll view's own zoom pinch and takes over only when the
        // image is unzoomed and the fingers move inward (shared policy). It never blocks zooming.
        let dismissPinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDismissPinch(_:)))
        dismissPinch.delegate = context.coordinator
        scrollView.addGestureRecognizer(dismissPinch)

        // One-finger drag-to-close: begins ONLY on a clearly vertical drag while unzoomed (shared policy +
        // `gestureRecognizerShouldBegin`), so a horizontal drag falls through to the page TabView's swipe and a
        // zoomed image still pans normally. It tracks the finger and closes / springs back on release.
        let dismissPan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDismissPan(_:)))
        dismissPan.delegate = context.coordinator
        dismissPan.maximumNumberOfTouches = 1
        scrollView.addGestureRecognizer(dismissPan)
        context.coordinator.dismissPan = dismissPan

        // Live Photo long-press: a stationary press-and-hold plays the paired motion clip; release/cancel stops
        // it. Installed only for Live Photos (callbacks non-nil). Rides alongside the other recognizers, so any
        // drag cancels it back to the still and pans/zooms as usual.
        if onMotionStart != nil {
            let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
            longPress.minimumPressDuration = 0.3
            longPress.delegate = context.coordinator
            scrollView.addGestureRecognizer(longPress)
        }

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onCloseRequested = onCloseRequested
        context.coordinator.onMotionStart = onMotionStart
        context.coordinator.onMotionStop = onMotionStop
        context.coordinator.onPhotoFrameChanged = onPhotoFrameChanged
        context.coordinator.onZoomSettled = onZoomSettled
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
        }
        // Initial/refresh report, async: we're inside a SwiftUI view update, and the callback writes @State.
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.reportPhotoFrame()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap, onCloseRequested: onCloseRequested,
                    onMotionStart: onMotionStart, onMotionStop: onMotionStop)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        var onSingleTap: () -> Void
        var onCloseRequested: () -> Void
        var onMotionStart: (() -> Void)?
        var onMotionStop: (() -> Void)?
        var onPhotoFrameChanged: ((CGRect) -> Void)?
        var onZoomSettled: ((CGFloat) -> Void)?
        /// Last reported photo rect - reports are de-duplicated so a steady frame never spams @State updates.
        private var lastReportedPhotoFrame: CGRect = .null

        private var dismissPinchActive = false
        private var pinchStartCentroid: CGPoint = .zero
        weak var dismissPan: UIPanGestureRecognizer?
        private var dismissPanActive = false
        private var motionActive = false

        init(onSingleTap: @escaping () -> Void, onCloseRequested: @escaping () -> Void,
             onMotionStart: (() -> Void)?, onMotionStop: (() -> Void)?) {
            self.onSingleTap = onSingleTap
            self.onCloseRequested = onCloseRequested
            self.onMotionStart = onMotionStart
            self.onMotionStop = onMotionStop
        }

        /// Live Photo playback: begin on the long-press threshold, end on release/cancel. The `motionActive`
        /// guard means a stray terminal state without a matching `.began` can never fire a spurious stop.
        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began:
                motionActive = true
                onMotionStart?()
            case .ended, .cancelled, .failed:
                if motionActive {
                    motionActive = false
                    onMotionStop?()
                }
            default:
                break
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        /// The displayed photo rect: the aspect-FIT area of the image inside the (zoom-scaled) image view,
        /// converted to the scroll view's superview space - the same space the page's SwiftUI overlays use.
        func displayedPhotoFrame() -> CGRect? {
            guard let scrollView, let imageView, let img = imageView.image,
                  img.size.width > 0, img.size.height > 0 else { return nil }
            let fitted = AVMakeRect(aspectRatio: img.size, insideRect: imageView.bounds)
            return imageView.convert(fitted, to: scrollView.superview)
        }

        func reportPhotoFrame() {
            guard let frame = displayedPhotoFrame() else { return }
            // Sub-point changes are invisible; skip them so pan/zoom doesn't flood SwiftUI with state writes.
            if abs(frame.minX - lastReportedPhotoFrame.minX) < 0.5,
               abs(frame.minY - lastReportedPhotoFrame.minY) < 0.5,
               abs(frame.width - lastReportedPhotoFrame.width) < 0.5,
               abs(frame.height - lastReportedPhotoFrame.height) < 0.5 { return }
            lastReportedPhotoFrame = frame
            onPhotoFrameChanged?(frame)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { reportPhotoFrame() }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { reportPhotoFrame() }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            reportPhotoFrame()
            onZoomSettled?(scale)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        /// Gate the dismiss pan so it begins ONLY on a clearly vertical drag while the image is unzoomed - a
        /// horizontal drag then falls through to the page TabView's paging swipe, and a zoomed image keeps its
        /// scroll-view pan. Every other recognizer begins normally.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === dismissPan, let scrollView else { return true }
            let isZoomedIn = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            guard !isZoomedIn else { return false }
            let v = (gestureRecognizer as? UIPanGestureRecognizer)?.velocity(in: scrollView) ?? .zero
            return abs(v.y) > abs(v.x)
        }

        @objc func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
            guard let scrollView, let container = scrollView.superview else { return }
            let translation = gesture.translation(in: container)
            switch gesture.state {
            case .began, .changed:
                if !dismissPanActive {
                    let isZoomedIn = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
                    guard ViewerDragDismissPolicy.engages(
                        translation: CGSize(width: translation.x, height: translation.y), isZoomedIn: isZoomedIn)
                    else { return }
                    dismissPanActive = true
                }
                let progress = ViewerDragDismissPolicy.progress(
                    translationY: translation.y, viewportHeight: container.bounds.height)
                let scale = ViewerDragDismissPolicy.displayScale(progress: progress)
                scrollView.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
                    .scaledBy(x: scale, y: scale)
            case .ended, .cancelled, .failed:
                guard dismissPanActive else { return }
                dismissPanActive = false
                let velocity = gesture.velocity(in: container)
                if gesture.state == .ended, ViewerDragDismissPolicy.shouldDismiss(
                    translationY: translation.y, velocityY: velocity.y, viewportHeight: container.bounds.height) {
                    onCloseRequested()
                } else {
                    UIView.animate(
                        withDuration: ViewerDragDismissPolicy.springBackDuration,
                        delay: 0,
                        usingSpringWithDamping: ViewerDragDismissPolicy.springBackDamping,
                        initialSpringVelocity: 0,
                        options: [.allowUserInteraction, .beginFromCurrentState]
                    ) {
                        scrollView.transform = .identity
                    }
                }
            default:
                break
            }
        }

        @objc func handleSingleTap() { onSingleTap() }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let side = scrollView.bounds.size
                let zoomRect = CGRect(x: point.x - side.width / 6, y: point.y - side.height / 6,
                                      width: side.width / 3, height: side.height / 3)
                scrollView.zoom(to: zoomRect, animated: true)
            }
            // Programmatic zooms don't reliably deliver `scrollViewDidEndZooming` - settle explicitly once the
            // zoom animation is over, so a double-tap zoom also gets its sharper decode.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                self.reportPhotoFrame()
                self.onZoomSettled?(scrollView.zoomScale)
            }
        }

        @objc func handleDismissPinch(_ gesture: UIPinchGestureRecognizer) {
            guard let scrollView, let container = scrollView.superview else { return }
            switch gesture.state {
            case .began, .changed:
                if !dismissPinchActive {
                    let isZoomedIn = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
                    guard ViewerPinchDismissPolicy.engages(gestureScale: gesture.scale, isZoomedIn: isZoomedIn)
                    else { return }
                    dismissPinchActive = true
                    pinchStartCentroid = gesture.location(in: container)
                    // Take the gesture over from the scroll view's bounce-zoom for its remainder.
                    scrollView.pinchGestureRecognizer?.isEnabled = false
                    scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
                }
                let scale = ViewerPinchDismissPolicy.displayScale(gestureScale: gesture.scale)
                let centroid = gesture.location(in: container)
                let center = scrollView.center
                // Keep the image point that was under the fingers under the fingers: scale about the view
                // center, then translate so the engaged centroid tracks the live centroid.
                let tx = centroid.x - center.x - scale * (pinchStartCentroid.x - center.x)
                let ty = centroid.y - center.y - scale * (pinchStartCentroid.y - center.y)
                scrollView.transform = CGAffineTransform(translationX: tx, y: ty).scaledBy(x: scale, y: scale)
            case .ended, .cancelled, .failed:
                guard dismissPinchActive else { return }
                dismissPinchActive = false
                scrollView.pinchGestureRecognizer?.isEnabled = true
                if gesture.state == .ended, ViewerPinchDismissPolicy.shouldDismiss(releaseScale: gesture.scale) {
                    onCloseRequested()
                } else {
                    UIView.animate(
                        withDuration: ViewerPinchDismissPolicy.springBackDuration,
                        delay: 0,
                        usingSpringWithDamping: ViewerPinchDismissPolicy.springBackDamping,
                        initialSpringVelocity: 0,
                        options: [.allowUserInteraction, .beginFromCurrentState]
                    ) {
                        scrollView.transform = .identity
                    }
                }
            default:
                break
            }
        }
    }
}

/// Hosts the Live Photo motion clip's `AVPlayerLayer` over the still - aspect-fit, transparent, non-interactive
/// (the still underneath keeps the zoom/tap gestures). Mirrors the macOS `MotionPlayerLayerView`.
private struct MobileMotionPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .clear
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// The small "LIVE" affordance shown on a Live Photo page - signals the press-and-hold-to-play interaction.
private struct MobileLiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "livephoto")
            Text(verbatim: "LIVE")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .protonGlass(in: Capsule())
    }
}
