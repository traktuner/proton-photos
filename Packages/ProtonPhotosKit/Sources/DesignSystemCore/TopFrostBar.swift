import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A light frosted-glass band pinned behind an inline navigation/toolbar title, shared by the macOS grid
/// and the iOS grid + map.
///
/// The content is a full-bleed Metal view, so the title would be unreadable over bright photos. SwiftUI's
/// `Material`/`glassEffect` can't sample a `CAMetalLayer` backdrop, but a genuine platform vibrancy view
/// (`NSVisualEffectView`/`UIVisualEffectView`) blurs sibling layers including the Metal one. The soft-bottom
/// fade and the frost intensity are applied INSIDE the platform view (a `CAGradientLayer` mask + view
/// alpha), not via SwiftUI `.mask`/`.opacity`. Height is supplied by the caller as a STABLE value (never
/// read live from the key window during body evaluation — that is what previously cycled).
public struct TopFrostBar: View {
    /// Total band height: the top safe-area / toolbar inset plus a little fade room below it.
    private let height: CGFloat
    /// 0…1 — dials the frost from barely-there to full, so it stays a subtle band rather than a dark strip.
    private let intensity: CGFloat

    public init(height: CGFloat, intensity: CGFloat = 0.6) {
        self.height = height
        self.intensity = intensity
    }

    public var body: some View {
        FrostBlur(intensity: intensity)
            .frame(height: max(48, height))
            .frame(maxWidth: .infinity)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }
}

// Shared gradient stops (mask alpha, top→bottom): uniform frost held across the bar, soft-faded only at
// the very bottom edge so it never reads as a hard opaque strip cutting through a photo row.
private let frostMaskColors: [CGColor] = [
    CGColor(gray: 0, alpha: 1),
    CGColor(gray: 0, alpha: 1),
    CGColor(gray: 0, alpha: 0),
]
private let frostMaskLocations: [NSNumber] = [0.0, 0.80, 1.0]

#if canImport(UIKit)
private struct FrostBlur: UIViewRepresentable {
    let intensity: CGFloat
    func makeUIView(context: Context) -> FrostBarView { FrostBarView(intensity: intensity) }
    func updateUIView(_ view: FrostBarView, context: Context) { view.setIntensity(intensity) }
}

private final class FrostBarView: UIView {
    private let effect = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let gradient = CAGradientLayer()

    init(intensity: CGFloat) {
        super.init(frame: .zero)
        effect.alpha = intensity
        addSubview(effect)
        gradient.colors = frostMaskColors
        gradient.locations = frostMaskLocations
        gradient.startPoint = CGPoint(x: 0.5, y: 0)   // UIKit: origin top-left → frost at top
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer.mask = gradient
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setIntensity(_ intensity: CGFloat) { effect.alpha = intensity }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effect.frame = bounds
        gradient.frame = bounds
        CATransaction.commit()
    }
}
#else
private struct FrostBlur: NSViewRepresentable {
    let intensity: CGFloat
    func makeNSView(context: Context) -> FrostBarView { FrostBarView(intensity: intensity) }
    func updateNSView(_ view: FrostBarView, context: Context) { view.setIntensity(intensity) }
}

private final class FrostBarView: NSView {
    private let effect = NSVisualEffectView()
    private let gradient = CAGradientLayer()

    init(intensity: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        effect.blendingMode = .withinWindow
        effect.material = .headerView
        effect.state = .followsWindowActiveState
        effect.alphaValue = intensity
        addSubview(effect)
        gradient.colors = frostMaskColors
        gradient.locations = frostMaskLocations
        gradient.startPoint = CGPoint(x: 0.5, y: 1)   // AppKit: origin bottom-left → frost at top
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.mask = gradient
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setIntensity(_ intensity: CGFloat) { effect.alphaValue = intensity }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effect.frame = bounds
        gradient.frame = bounds
        CATransaction.commit()
    }
}
#endif
