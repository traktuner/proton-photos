import AVFoundation
import AVKit
import DesignSystemCore
import PhotosCore
import PhotoViewerCore
import PhotoViewerUIKitAdapter
import SwiftUI
import UIKit

/// Native full-screen photo/video viewer. Paging + chrome live here (pure presentation); the media decoding,
/// titles, video-playback and pinch-to-close semantics come from shared `PhotoViewerCore` and the shared
/// backend — no viewer business logic is reimplemented per platform.
struct MobilePhotoViewer: View {
    let items: [PhotoItem]
    let startIndex: Int
    let libraryModel: MobileLibraryModel

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var chromeVisible = true

    init(items: [PhotoItem], startIndex: Int, libraryModel: MobileLibraryModel) {
        self.items = items
        self.startIndex = startIndex
        self.libraryModel = libraryModel
        _index = State(initialValue: min(max(startIndex, 0), max(items.count - 1, 0)))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(items.indices, id: \.self) { i in
                    MobileViewerPage(
                        item: items[i],
                        isCurrent: i == index,
                        libraryModel: libraryModel,
                        onToggleChrome: { withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() } },
                        onCloseRequested: { dismiss() }
                    )
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if chromeVisible {
                chrome
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
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
                        .background(.ultraThinMaterial, in: Circle())
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

/// A single viewer page — a zoomable image, or a native video player for video items.
private struct MobileViewerPage: View {
    let item: PhotoItem
    let isCurrent: Bool
    let libraryModel: MobileLibraryModel
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
                libraryModel: libraryModel,
                onToggleChrome: onToggleChrome,
                onCloseRequested: onCloseRequested
            )
        }
    }
}

/// Loads the placeholder thumbnail immediately, then the full-resolution original, and shows it zoomable.
private struct MobileImagePage: View {
    let item: PhotoItem
    let libraryModel: MobileLibraryModel
    let onToggleChrome: () -> Void
    let onCloseRequested: () -> Void

    @State private var image: UIImage?
    @State private var isLoadingFull = false

    var body: some View {
        ZStack {
            if let image {
                MobileZoomableImage(image: image, onSingleTap: onToggleChrome, onCloseRequested: onCloseRequested)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: item.uid) { await load() }
    }

    private func load() async {
        // Instant placeholder from the in-memory thumbnail cache (already decoded for the grid).
        if image == nil, let thumb = libraryModel.thumbnailFeed?.memoryImage(for: item.uid) {
            image = thumb
        }
        guard !isLoadingFull, let backend = libraryModel.backend else { return }
        isLoadingFull = true
        defer { isLoadingFull = false }
        do {
            let data = try await backend.originalData(for: item.uid)
            if let full = UIKitViewerImageAdapter.image(from: data) {
                image = full
            }
        } catch {
            // Keep the thumbnail placeholder on failure — better than a blank page.
        }
    }
}

/// Native video playback via AVKit over the shared `VideoStreamProvider` streaming asset. Until playback
/// visibly starts, the grid's thumbnail stands in as a poster with a native centered spinner — never a
/// black hole. A two-finger pinch (which the player's tap-driven controls ignore) shrinks the page onto
/// the fingers and either springs back or closes, same shared policy as photos.
private struct MobileVideoPage: View {
    let item: PhotoItem
    let isCurrent: Bool
    let libraryModel: MobileLibraryModel
    let onCloseRequested: () -> Void

    @State private var player: AVPlayer?
    /// The streaming asset is the ONLY strong owner of the range resource-loader, which AVFoundation holds
    /// weakly — it must live as long as the player, or every protonvideo:// range request goes unserved.
    @State private var streamingAsset: StreamingVideoAsset?
    @State private var failed = false
    @State private var poster: UIImage?
    /// Set by the periodic time observer on the first advancing playback time — the moment frames are
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
        .task(id: item.uid) { await prepare() }
        .onChange(of: isCurrent) { _, current in
            if current { player?.play() } else { player?.pause() }
        }
        .onDisappear { teardown() }
    }

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
        guard player == nil, let backend = libraryModel.backend else { return }
        if poster == nil {
            poster = libraryModel.thumbnailFeed?.memoryImage(for: item.uid)
        }
        do {
            let streaming = try await backend.makeStreamingAsset(for: item.uid)
            let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: streaming.asset))
            streamingAsset = streaming   // retain the resource loader for the player's lifetime
            player = newPlayer
            observeFirstFrame(of: newPlayer)
            if isCurrent { newPlayer.play() }
        } catch {
            failed = true
        }
    }

    /// A playback time that actually advances is the reliable "frames are on screen" signal — player/item
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

/// Owns an `AVPlayer` periodic time-observer token — the token must be removed from the SAME player
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
/// the scroll view does not pan, so the enclosing page TabView keeps its swipe — and a pinch-IN at minimum
/// zoom hands the image to the shared pinch-to-close interaction (`ViewerPinchDismissPolicy`): it sticks to
/// the fingers, springs back below the threshold, closes past it.
private struct MobileZoomableImage: UIViewRepresentable {
    let image: UIImage
    let onSingleTap: () -> Void
    let onCloseRequested: () -> Void

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

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onCloseRequested = onCloseRequested
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap, onCloseRequested: onCloseRequested)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        var onSingleTap: () -> Void
        var onCloseRequested: () -> Void

        private var dismissPinchActive = false
        private var pinchStartCentroid: CGPoint = .zero
        weak var dismissPan: UIPanGestureRecognizer?
        private var dismissPanActive = false

        init(onSingleTap: @escaping () -> Void, onCloseRequested: @escaping () -> Void) {
            self.onSingleTap = onSingleTap
            self.onCloseRequested = onCloseRequested
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        /// Gate the dismiss pan so it begins ONLY on a clearly vertical drag while the image is unzoomed — a
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
