import SwiftUI

public extension View {
    @ViewBuilder
    func protonGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            glassEffect(in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder
    func protonProminentGlassButton() -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}
