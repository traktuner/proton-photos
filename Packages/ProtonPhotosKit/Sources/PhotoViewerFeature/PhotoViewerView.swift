import SwiftUI
import AVKit
import PhotosCore
import DesignSystem

/// Full-screen photo/video viewer with blur-up progressive loading and keyboard navigation.
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
                .id(model.current.uid)
                .transition(.opacity)

            controls
        }
        .onAppear { model.start() }
        .onHover { hovering = $0 }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { model.previous(); return .handled }
        .onKeyPress(.rightArrow) { model.next(); return .handled }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onKeyPress(.space) { model.next(); return .handled }
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
                .blur(radius: model.isSharp ? 0 : 14)
                .clipped()
                .animation(.easeOut(duration: 0.3), value: model.isSharp)
                .animation(.easeInOut(duration: 0.2), value: image)
        } else {
            ProtonSpinner(size: 34, lineWidth: 3)
        }
    }

    @ViewBuilder private var controls: some View {
        VStack {
            HStack {
                Spacer()
                closeButton
            }
            Spacer()
        }
        .padding(18)
        .opacity(hovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: hovering)

        HStack {
            navButton("chevron.left", enabled: model.canGoPrevious) { model.previous() }
            Spacer()
            navButton("chevron.right", enabled: model.canGoNext) { model.next() }
        }
        .padding(.horizontal, 18)
        .opacity(hovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.25)
        .disabled(!enabled)
    }
}
