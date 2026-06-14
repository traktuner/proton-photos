import SwiftUI
import AVKit
import PhotosCore
import DesignSystem

/// Full-screen photo/video viewer: shows the best available image sharp (no blur) with a Liquid
/// Glass loading indicator while the full original downloads, then pinch-to-zoom + two-finger pan.
public struct PhotoViewerView: View {
    @State private var model: PhotoViewerModel
    private let onClose: () -> Void

    @State private var hovering = false

    public init(model: PhotoViewerModel, onClose: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content

            if model.videoURL == nil && !model.isSharp {
                ProtonSpinner(size: 30, lineWidth: 2.5)
                    .padding(16)
                    .glassEffect(in: Circle())
            }

            controls
            shortcuts
        }
        .onAppear { model.start() }
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var content: some View {
        if let videoURL = model.videoURL {
            VideoPlayer(player: AVPlayer(url: videoURL))
                .ignoresSafeArea()
        } else if let image = model.image {
            ZoomableImageView(image: image)   // native pinch-zoom-at-cursor + two-finger pan
                .ignoresSafeArea()
        }
    }

    private func goPrevious() { model.previous() }
    private func goNext() { model.next() }

    // MARK: Controls + shortcuts

    @ViewBuilder private var controls: some View {
        VStack {
            HStack {
                Spacer()
                iconButton("xmark", size: 34) { onClose() }
            }
            Spacer()
        }
        .padding(18)
        .opacity(hovering ? 1 : 0)
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
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .opacity(enabled ? 1 : 0.25)
        .disabled(!enabled)
    }
}
