import SwiftUI

/// The loading mark: the single-ink ProtonPhotos logo (`ProtonPhotosMono`, a template vector PDF) rendered as
/// a subtle low-opacity ink, with a soft bright highlight that flows diagonally (top-left → bottom-right)
/// **inside the logo strokes only**. The highlight is a moving `LinearGradient` masked by the logo's own
/// alpha - no outer glow, halo, drop shadow, or blurred aura, and no visible rectangle sweeping the screen.
/// Honors Reduce Motion (static ink, no shimmer). The ink is a template, so its color adapts to light/dark.
///
/// Shared verbatim by macOS (launch veil, over `FrostedGlassBackground`) and iOS (library loading
/// screen) - one implementation, no platform forks. Pure SwiftUI; the platform surface behind it
/// stays in the platform layer.
public struct LoadingMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    /// Base opacity of the resting ink (subtle "glass/ink"); the highlight rises far above this as it passes.
    private let baseOpacity = 0.28
    private let highlightOpacity = 0.95
    private let period = 1.6                 // seconds per sweep (within the 1.4–1.8s spec)
    private let bandHalfExtent = 0.4         // diagonal half-width of the soft highlight band, in unit space

    public var body: some View {
        // One shaping for both the visible ink and the mask, so the highlight lands exactly on the strokes.
        let shaped = Image("ProtonPhotosMono", bundle: .module)
            .resizable()
            .scaledToFit()

        ZStack {
            shaped
                .foregroundStyle(.primary)
                .opacity(baseOpacity)

            if !reduceMotion {
                // `TimelineView(.animation)` drives the sweep only while the mark is on screen; it stops the
                // moment the veil is removed, so there is no lingering animation cost.
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let progress = (t.truncatingRemainder(dividingBy: period)) / period   // 0…1, linear
                    // Band center sweeps from off the top-left to off the bottom-right and repeats; it is
                    // off-screen at both ends, so the loop has no visible jump.
                    let p = -0.3 + 1.6 * progress
                    Rectangle()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .primary.opacity(highlightOpacity), location: 0.5),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: UnitPoint(x: p - bandHalfExtent, y: p - bandHalfExtent),
                                endPoint: UnitPoint(x: p + bandHalfExtent, y: p + bandHalfExtent)
                            )
                        )
                        .mask(shaped)        // the bright band shows ONLY where the logo has ink
                }
            }
        }
        .accessibilityHidden(true)
    }
}
