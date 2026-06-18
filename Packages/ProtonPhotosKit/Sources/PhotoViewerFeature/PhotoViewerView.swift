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
            Color.black.ignoresSafeArea()

            content

            loadingOverlay

            infoPanel
            controls
            shortcuts
        }
        .onAppear { model.start() }
        .onHover { hovering = $0 }
        .onExitCommand { onClose() }   // Esc closes the photo
    }

    @ViewBuilder private var infoPanel: some View {
        if model.showInfo {
            HStack(spacing: 0) {
                Spacer()
                InfoPanelView(item: model.current, metadata: model.metadata) {
                    withAnimation(.easeInOut(duration: 0.25)) { model.toggleInfo() }
                }
                .transition(.move(edge: .trailing))
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder private var content: some View {
        if let player = model.player {
            PlayerView(player: player)             // single AVPlayer (streaming or downloaded)
                .ignoresSafeArea()
        } else if let image = model.image {
            ZoomableImageView(image: image, onPinchClose: onClose)   // pinch-zoom + pinch-out-to-close
                .ignoresSafeArea()
        }
    }

    /// Loading / error affordance for the media (image original or video). Shows a real percentage
    /// while bytes download, a spinner while resolving, and a user-visible error if playback fails —
    /// never an infinite spinner once the video path reports `.failed`.
    @ViewBuilder private var loadingOverlay: some View {
        if let message = model.videoState.errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
                Text("Wiedergabe fehlgeschlagen")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .padding(22)
            .glassEffect(in: RoundedRectangle(cornerRadius: 16))
        } else if model.player == nil && !model.isSharp {
            let progress = max(model.originalProgress, model.videoState.progress)
            if model.isLoadingOriginal, progress > 0.001, progress < 0.995 {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(18)
                .glassEffect(in: RoundedRectangle(cornerRadius: 16))
            } else {
                ProgressView().controlSize(.large).tint(.white)
                    .padding(16)
                    .glassEffect(in: Circle())
            }
        }
    }

    private func goPrevious() { model.previous() }
    private func goNext() { model.next() }

    // MARK: Controls + shortcuts

    @ViewBuilder private var controls: some View {
        VStack {
            HStack(spacing: 12) {
                Spacer()
                iconButton(isFavorite(model.current.uid) ? "heart.fill" : "heart", size: 40) {
                    onToggleFavorite(model.current.uid)
                }
                iconButton("trash", size: 40) { onTrash(model.current) }
                iconButton("info.circle", size: 40) {
                    withAnimation(.easeInOut(duration: 0.25)) { model.toggleInfo() }
                }
                iconButton("xmark", size: 40) { onClose() }
            }
            Spacer()
        }
        .padding(18)
        .padding(.trailing, model.showInfo ? 320 : 0)   // keep clear of the info panel
        .opacity(hovering || model.showInfo ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: model.showInfo)
        .animation(.easeInOut(duration: 0.15), value: hovering)

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
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentShape(Rectangle())   // whole frame is clickable, not just the glyph pixels
        }
        .buttonStyle(.plain)
        // Dark-tinted glass so the white glyphs stay legible over light photos too.
        .glassEffect(.regular.tint(.black.opacity(0.32)).interactive(), in: Circle())
        .opacity(enabled ? 1 : 0.25)
        .disabled(!enabled)
    }
}
