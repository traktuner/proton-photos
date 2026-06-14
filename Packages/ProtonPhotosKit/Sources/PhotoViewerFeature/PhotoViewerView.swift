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
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

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
        .onChange(of: model.current.uid) { resetZoom() }
    }

    @ViewBuilder private var content: some View {
        if let videoURL = model.videoURL {
            VideoPlayer(player: AVPlayer(url: videoURL))
                .ignoresSafeArea()
        } else if let image = model.image {
            GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: geo.size.width * scale, height: geo.size.height * scale)
                        .gesture(magnify)
                        .onTapGesture(count: 2) { toggleZoom() }
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(scale <= 1.01)              // only pan when zoomed in
                .scrollClipDisabled()
                .animation(.interactiveSpring(duration: 0.25), value: scale)
            }
        }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in scale = min(max(lastScale * value.magnification, 1), 6) }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 { resetZoom() }
            }
    }

    private func toggleZoom() {
        withAnimation(.snappy(duration: 0.25)) {
            if scale > 1 { scale = 1 } else { scale = 2.5 }
            lastScale = scale
        }
    }

    private func resetZoom() { scale = 1; lastScale = 1 }
    private func goPrevious() { resetZoom(); model.previous() }
    private func goNext() { resetZoom(); model.next() }

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
