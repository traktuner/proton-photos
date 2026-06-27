import SwiftUI
import AVKit
import AVFoundation
import PhotosCore
import DesignSystem

/// Native AppKit video view. SwiftUI's `VideoPlayer` crashes on this macOS (a `_AVKit_SwiftUI`
/// generic-metadata fatalError), and `AVPlayerView` is the better macOS surface anyway — native
/// floating controls, scrubbing, Picture-in-Picture.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = true
        player.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Full-screen photo/video viewer: shows the best available image sharp (no blur) with a Liquid
/// Glass loading indicator while the full original downloads, then pinch-to-zoom + two-finger pan.
public struct PhotoViewerView: View {
    @State private var model: PhotoViewerModel
    private let onClose: () -> Void
    private let isFavorite: (PhotoUID) -> Bool
    private let onToggleFavorite: (PhotoUID) -> Void
    private let onTrash: (PhotoItem) -> Void

    @State private var hovering = false

    public init(model: PhotoViewerModel,
                isFavorite: @escaping (PhotoUID) -> Bool = { _ in false },
                onToggleFavorite: @escaping (PhotoUID) -> Void = { _ in },
                onTrash: @escaping (PhotoItem) -> Void = { _ in },
                onClose: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.isFavorite = isFavorite
        self.onToggleFavorite = onToggleFavorite
        self.onTrash = onTrash
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            // Warm Apple-Photos background fills the whole window (behind the now-opaque top bar too).
            ViewerVisualConstants.backgroundColor.ignoresSafeArea()

            viewerBody

            loadingOverlay

            navigationControls
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
        GeometryReader { geometry in
            let content = CGRect(origin: .zero, size: geometry.size)
            let inspectorWidth = model.showInfo ? ViewerChromeLayout.clampedInspectorWidth(in: content) : 0
            HStack(spacing: 0) {
                self.content
                    .frame(width: max(0, content.width - inspectorWidth), height: content.height)
                    .clipped()
                if model.showInfo {
                    InfoPanelView(item: model.current, metadata: model.metadata) {
                        withAnimation(.easeInOut(duration: 0.25)) { model.toggleInfo() }
                    }
                    .frame(width: inspectorWidth, height: content.height)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let player = model.player {
            PlayerView(player: player)             // single AVPlayer (streaming or downloaded)
        } else if let image = model.image {
            ZoomableImageView(image: image, onPinchClose: onClose)   // pinch-zoom + pinch-out-to-close
        }
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else {
            ProgressView().controlSize(.large)
                .padding(16)
                .background(.regularMaterial, in: Circle())
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else {
            ProgressView().controlSize(.large)
                .padding(16)
                .background(.regularMaterial, in: Circle())
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
        .background(.regularMaterial, in: Circle())
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
