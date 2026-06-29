import SwiftUI
import AVKit
import AVFoundation
import PhotosCore
import DesignSystem

/// `AVPlayerView` that turns a pinch-OUT into the SAME "fly closed" dismiss the still image uses — so a PLAYING
/// video can be pinched/swiped shut too (previously the gesture only existed on the image path, so it did nothing
/// over a video). It only REPORTS progress; the host's shared zoom overlay renders the shrink into the exact grid
/// cell, identical to the image path.
private final class DismissableAVPlayerView: AVPlayerView {
    var onPinchDismissBegan: () -> Void = {}
    var onPinchDismissChanged: (CGFloat) -> Void = { _ in }
    var onPinchDismissEnded: (Bool) -> Void = { _ in }

    private var dismissing = false
    private var dismissProgress: CGFloat = 0

    override func magnify(with event: NSEvent) {
        // Only a pinch-OUT flies the video closed; pinch-in / anything else falls through to AVKit.
        guard dismissing || event.magnification < 0 else { super.magnify(with: event); return }
        switch event.phase {
        case .began:
            dismissing = true
            dismissProgress = 0
            onPinchDismissBegan()
        case .changed:
            dismissProgress = max(0, dismissProgress - event.magnification)   // outward pinch = negative
            onPinchDismissChanged(max(0, min(1, 1 - dismissProgress)))        // 1 = fullscreen, 0 = the grid cell
        case .ended, .cancelled:
            let shouldClose = event.phase == .ended && dismissProgress > 0.07  // a small/quick pinch is enough
            dismissing = false
            onPinchDismissEnded(shouldClose)
        default:
            break
        }
    }
}

/// Native AppKit video view. SwiftUI's `VideoPlayer` crashes on this macOS (a `_AVKit_SwiftUI`
/// generic-metadata fatalError), and `AVPlayerView` is the better macOS surface anyway — native
/// floating controls, scrubbing, Picture-in-Picture.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    var isDismissing: Bool = false
    var onPinchDismissBegan: () -> Void = {}
    var onPinchDismissChanged: (CGFloat) -> Void = { _ in }
    var onPinchDismissEnded: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> DismissableAVPlayerView {
        let view = DismissableAVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = true
        view.onPinchDismissBegan = onPinchDismissBegan
        view.onPinchDismissChanged = onPinchDismissChanged
        view.onPinchDismissEnded = onPinchDismissEnded
        player.play()
        return view
    }

    func updateNSView(_ view: DismissableAVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        view.onPinchDismissBegan = onPinchDismissBegan
        view.onPinchDismissChanged = onPinchDismissChanged
        view.onPinchDismissEnded = onPinchDismissEnded
        // While the host's zoom overlay renders the shrink, hide the LIVE video so the GRID shows through behind it
        // (the still-image path hides its image for the same reason). Hide via the LAYER, not `alphaValue`: an
        // alpha-0 NSView stops hit-testing, so a fresh "pinch to recover" would leak to the grid; the layer trick
        // keeps the view receiving the gesture.
        view.layer?.opacity = isDismissing ? 0 : 1
    }
}

/// A bare `AVPlayerLayer` (NO controls, NO chrome) for the Live Photo motion clip — it's crossfaded over the
/// still by the SwiftUI `.opacity`, so there is no player overlay and no black load gap, just the "ghost" motion.
private struct MotionPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let v = PlayerLayerHostView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ v: PlayerLayerHostView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

/// Layer-backed NSView whose backing layer IS an `AVPlayerLayer`, so the motion frame fills the view and
/// resizes with it without any manual frame bookkeeping.
private final class PlayerLayerHostView: NSView {
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Full-screen photo/video viewer: shows the best available image sharp (no blur) with a Liquid
/// Glass loading indicator while the full original downloads, then pinch-to-zoom + two-finger pan.
public struct PhotoViewerView: View {
    @State private var model: PhotoViewerModel
    private let onClose: () -> Void
    private let isFavorite: (PhotoUID) -> Bool
    private let onToggleFavorite: (PhotoUID) -> Void
    private let onTrash: (PhotoItem) -> Void
    private let onPinchDismissBegan: () -> Void
    private let onPinchDismissChanged: (CGFloat) -> Void
    private let onPinchDismissEnded: (Bool) -> Void
    /// True while the interactive pinch-dismiss is in flight: the host's shared zoom overlay is rendering the live
    /// shrink-into-the-cell, so THIS view hides its own background + image (but stays mounted + hit-testable so the
    /// pinch keeps delivering to its scroll view, never leaking to the grid behind).
    private let isDismissing: Bool

    @State private var hovering = false

    /// Measured width of the viewer region, fed by `.onGeometryChange` (an after-layout EFFECT, NOT a
    /// GeometryReader child value). Used ONLY to clamp the fixed-width info inspector; the media content fills
    /// the remaining width flexibly so it never depends on a not-yet-measured value. Keeping the `model`-reading
    /// body OFF a GeometryReader child value is what avoids the Swift-6 `swift_task_isCurrentExecutor`
    /// false-positive SIGSEGV (#76804) on SwiftUI's `syncMainIfReferences` update path — see PhotoViewerModel.
    @State private var containerWidth: CGFloat = 0

    /// Measured size of the media (content) area, used to place the LIVE badge on the displayed image's
    /// top-left CORNER — the image is aspect-fit (letterboxed), so a portrait photo in a wide window must show
    /// the badge inset to the image edge, not at the window edge.
    @State private var contentSize: CGSize = .zero

    public init(model: PhotoViewerModel,
                isFavorite: @escaping (PhotoUID) -> Bool = { _ in false },
                onToggleFavorite: @escaping (PhotoUID) -> Void = { _ in },
                onTrash: @escaping (PhotoItem) -> Void = { _ in },
                onClose: @escaping () -> Void,
                onPinchDismissBegan: @escaping () -> Void = {},
                onPinchDismissChanged: @escaping (CGFloat) -> Void = { _ in },
                onPinchDismissEnded: @escaping (Bool) -> Void = { _ in },
                isDismissing: Bool = false) {
        _model = State(initialValue: model)
        self.isFavorite = isFavorite
        self.onToggleFavorite = onToggleFavorite
        self.onTrash = onTrash
        self.onClose = onClose
        self.onPinchDismissBegan = onPinchDismissBegan
        self.onPinchDismissChanged = onPinchDismissChanged
        self.onPinchDismissEnded = onPinchDismissEnded
        self.isDismissing = isDismissing
    }

    public var body: some View {
        ZStack {
            // Warm Apple-Photos background fills the whole window (behind the now-opaque top bar too). Hidden while
            // an interactive dismiss runs so the grid shows through behind the shrinking photo (the overlay owns it).
            ViewerVisualConstants.backgroundColor.ignoresSafeArea()
                .opacity(isDismissing ? 0 : 1)

            viewerBody

            loadingOverlay.opacity(isDismissing ? 0 : 1)

            navigationControls.opacity(isDismissing ? 0 : 1)
            shortcuts
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }   // closing cancels in-flight work + stops playback
        .onHover { hovering = $0 }
        .onExitCommand { onClose() }   // Esc closes the photo
    }

    /// The media + info inspector. This view does NOT ignore the top safe area: the native window toolbar
    /// is the viewer's opaque top bar, so SwiftUI already lays this region out *below* it. The media is
    /// laid out in its final frame from the first frame — no extra toolbar offset, no shrink-then-settle,
    /// no black top gap.
    private var viewerBody: some View {
        // The inspector is a FIXED-width panel (clamped to the window) that does NOT change the container width,
        // so `containerWidth` is independent of whether the inspector is shown — no measurement feedback loop.
        let inspectorWidth = model.showInfo
            ? ViewerChromeLayout.clampedInspectorWidth(in: CGRect(x: 0, y: 0, width: containerWidth, height: 0))
            : 0
        return HStack(spacing: 0) {
            // The media fills the remaining width FLEXIBLY (`maxWidth: .infinity`), so it never depends on a
            // not-yet-measured `containerWidth` and there is no first-frame collapse. The measured width only feeds
            // the inspector clamp above.
            self.content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
                // LIVE badge: top-left ON THE IMAGE (offset by the aspect-fit letterbox), not the window edge.
                .overlay(alignment: .topLeading) {
                    if model.player == nil, model.current.isLivePhoto, model.image != nil, !isDismissing {
                        let inset = livePhotoBadgeImageInset(in: contentSize)
                        livePhotoBadge.offset(x: inset.width, y: inset.height)
                    }
                }
            if model.showInfo {
                InfoPanelView(item: model.current, metadata: model.metadata) {
                    withAnimation(.easeInOut(duration: 0.25)) { model.toggleInfo() }
                }
                .frame(width: inspectorWidth)
                .frame(maxHeight: .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // `.onGeometryChange` runs its `action` as an after-layout EFFECT (onChange-style), NOT as a
        // `GeometryReader.Child` attribute value. Its `transform` reads ONLY `proxy.size.width` and returns a plain
        // `CGFloat` (no `model`, no reference capture), so the tracked value never routes through
        // `Attribute.syncMainIfReferences` — the path that hits the #76804 executor-equality SIGSEGV. macOS 13+ for
        // this single-value variant, so unconditionally available on the macOS 26 target (no `#available` gate).
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            containerWidth = newWidth
        }
    }

    /// Top-left inset of the displayed (aspect-fit) image within the content area, so the LIVE badge sits on the
    /// IMAGE's corner regardless of aspect ratio: a portrait photo in a wide window is letterboxed left/right, so
    /// the badge follows the letterbox edge, not the window edge. Returns `.zero` before the image/size is known.
    private func livePhotoBadgeImageInset(in area: CGSize) -> CGSize {
        guard let img = model.image else { return .zero }
        let iw = img.size.width, ih = img.size.height
        guard iw > 0, ih > 0, area.width > 0, area.height > 0 else { return .zero }
        let scale = min(area.width / iw, area.height / ih)        // aspect-fit (matches the image view's gravity)
        return CGSize(width: max(0, (area.width - iw * scale) / 2),
                      height: max(0, (area.height - ih * scale) / 2))
    }

    @ViewBuilder private var content: some View {
        if let player = model.player {
            PlayerView(player: player,             // single AVPlayer (streaming or downloaded) + pinch-out-to-dismiss
                       isDismissing: isDismissing,
                       onPinchDismissBegan: onPinchDismissBegan,
                       onPinchDismissChanged: onPinchDismissChanged,
                       onPinchDismissEnded: onPinchDismissEnded)
        } else if let image = model.image {
            // Still image (incl. a Live Photo's key frame), with the motion clip crossfaded OVER it. Hover the
            // LIVE badge or force-click the photo to play the motion.
            ZStack {
                ZoomableImageView(image: image,                      // pinch-zoom + interactive pinch-out-to-dismiss
                                  isDismissing: isDismissing,
                                  onPinchDismissBegan: onPinchDismissBegan,
                                  onPinchDismissChanged: onPinchDismissChanged,
                                  onPinchDismissEnded: onPinchDismissEnded,
                                  onForceClick: { model.playMotion() })
                if model.current.isLivePhoto, let motion = model.motionPlayer {
                    MotionPlayerLayerView(player: motion)
                        .opacity(model.isMotionPlaying ? 1 : 0)
                        .animation(.easeInOut(duration: 0.16), value: model.isMotionPlaying)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// Apple-style LIVE indicator, top-left in full view. Hovering it plays the motion clip (instant — it's
    /// preloaded); moving off stops it. Native Liquid Glass (a custom view OUTSIDE the toolbar, so `.glassEffect`
    /// applies). A force-click anywhere on the photo plays it too (see `onForceClick`).
    private var livePhotoBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "livephoto")
                .font(.system(size: 12, weight: .medium))
            Text(verbatim: "LIVE")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glassEffect(in: Capsule())
        .padding(.top, 14)
        .padding(.leading, 14)
        .onHover { hovering in
            if hovering { model.playMotion() } else { model.stopMotion() }
        }
        .accessibilityLabel(Text(verbatim: "Live Photo"))
    }

    /// Loading / error affordance for the media (image original or video). The cardinal rule: this is
    /// driven entirely by `videoState`, so the UI is always in exactly one of — preparing, buffering
    /// (with a real reason), playing (no overlay), or failed (readable error + Retry). There is no
    /// branch that can leave a spinner up forever.
    @ViewBuilder private var loadingOverlay: some View {
        if let error = model.videoState.error {
            failureCard(error)
        } else if model.videoState.isBusy {
            // Buffering/seeking sit OVER a live player (non-blocking, native controls still usable);
            // resolving/downloading have no player yet, so they're a centered blocking spinner.
            busyOverlay
                .allowsHitTesting(false)
        } else if model.player == nil && !model.isSharp && model.isLoadingOriginal {
            imageLoadingOverlay   // still images: percent while the original downloads
        }
    }

    @ViewBuilder private func failureCard(_ error: VideoPlaybackError) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
            Text(L10n.string("viewer.playback_failed"))
                .font(.headline)
            Text(error.userMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if error.isRetryable {
                Button(L10n.string("action.retry")) { model.retry() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(22)
        .glassEffect(in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var busyOverlay: some View {
        let progress = model.videoState.progress
        if case .downloading = model.videoState, progress > 0.001, progress < 0.995 {
            VStack(spacing: 8) {
                ProgressView().controlSize(.large)
                Text("\(Int(progress * 100))%")
                    .font(.headline.monospacedDigit())
            }
            .padding(18)
            .glassEffect(in: RoundedRectangle(cornerRadius: 12))
        } else {
            ProgressView().controlSize(.large)
                .padding(16)
                .glassEffect(in: Circle())
        }
    }

    @ViewBuilder private var imageLoadingOverlay: some View {
        if model.originalProgress > 0.001, model.originalProgress < 0.995 {
            VStack(spacing: 8) {
                ProgressView().controlSize(.large)
                Text("\(Int(model.originalProgress * 100))%")
                    .font(.headline.monospacedDigit())
            }
            .padding(18)
            .glassEffect(in: RoundedRectangle(cornerRadius: 12))
        } else {
            ProgressView().controlSize(.large)
                .padding(16)
                .glassEffect(in: Circle())
        }
    }

    private func goPrevious() { model.previous() }
    private func goNext() { model.next() }

    // MARK: Controls + shortcuts

    @ViewBuilder private var navigationControls: some View {
        HStack {
            iconButton("chevron.left", size: 40, enabled: model.canGoPrevious) { goPrevious() }
            Spacer()
            iconButton("chevron.right", size: 40, enabled: model.canGoNext) { goNext() }
        }
        .padding(.horizontal, 18)
        .opacity(hovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }

    private var shortcuts: some View {
        ZStack {
            Button("", action: goPrevious).keyboardShortcut(.leftArrow, modifiers: [])
            Button("", action: goNext).keyboardShortcut(.rightArrow, modifiers: [])
            Button("", action: { model.next() }).keyboardShortcut(.space, modifiers: [])
            Button("", action: onClose).keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func iconButton(_ symbol: String, size: CGFloat, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(accessibilityTitle(for: symbol), systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Rectangle())   // whole frame is clickable, not just the glyph pixels
        }
        .buttonStyle(.plain)
        .glassEffect(in: Circle())
        .opacity(enabled ? 1 : 0.25)
        .disabled(!enabled)
        .accessibilityLabel(accessibilityTitle(for: symbol))
    }

    private func accessibilityTitle(for symbol: String) -> String {
        switch symbol {
        case "chevron.left": L10n.string("a11y.previous_photo")
        case "chevron.right": L10n.string("a11y.next_photo")
        default: L10n.string("a11y.action")
        }
    }
}
