import SwiftUI

public extension View {
    /// Spins the view steadily clockwise while `active` is true, then settles back upright. Used for
    /// the backup status glyph (the two circling arrows) so the icon visibly turns while a backup or
    /// check is running. Honors Reduce Motion by holding still.
    func spinsWhileActive(_ active: Bool, period: Double = 1.1) -> some View {
        modifier(ActivitySpin(active: active, period: period))
    }
}

private struct ActivitySpin: ViewModifier {
    let active: Bool
    let period: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(angle))
            .onChange(of: active, initial: true) { _, isActive in
                guard !reduceMotion else { angle = 0; return }
                if isActive {
                    angle = 0
                    withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
                        angle = 360
                    }
                } else {
                    // Drop the repeating animation and ease the glyph back to rest.
                    withAnimation(.easeOut(duration: 0.2)) { angle = 0 }
                }
            }
    }
}
