import SwiftUI
import AVKit
import PhotosCore
import DesignSystem

/// Full-screen photo/video viewer: shows the best available image sharp (no blur) with a Proton
/// loading spinner while the full original downloads, then enables pinch-to-zoom + pan.
public struct PhotoViewerView: View {
    @State private var model: PhotoViewerModel
    private let onClose: () -> Void

    @State private var hovering = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    public init(model: PhotoViewerModel, onClose: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content

            // Loading indicator: full original still downloading (and not a video).
            if model.videoURL == nil && !model.isSharp {
                ProtonSpinner(size: 36, lineWidth: 3)
                    .padding(20)
                    .background(.ultraThinMaterial, in: Circle())
            }

            controls
            shortcuts   // window-level key handling — works the instant the viewer opens
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
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(magnify)
                .simultaneousGesture(pan)
                .onTapGesture(count: 2) { toggleZoom() }
                .animation(.interactiveSpring(duration: 0.25), value: scale)
                .animation(.interactiveSpring(duration: 0.25), value: offset)
                .animation(.easeInOut(duration: 0.2), value: image)
        }
    }

    // MARK: Gestures

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in scale = min(max(lastScale * value.magnification, 1), 6) }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 { resetZoom() }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func toggleZoom() {
        if scale > 1 { resetZoom() } else { scale = 2.5; lastScale = 2.5 }
    }

    private func resetZoom() {
        scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
    }

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

    /// Hidden buttons give us reliable, focus-independent keyboard handling from the moment the
    /// viewer appears (no need to click a control first).
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
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.25)
        .disabled(!enabled)
    }
}
