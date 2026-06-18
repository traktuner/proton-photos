import Foundation
import Observation

/// Live-tunable animation timings, shared across the whole app via `.shared`. The animation code
/// reads these at fire time, so changing a value (from the Animation Tuning window) takes effect on
/// the very next animation — no rebuild. Durations are in seconds; the tuning UI shows milliseconds.
@MainActor
@Observable
public final class AnimationTuning {
    public static let shared = AnimationTuning()
    private init() {}

    // Pinch / zoom-level grid transition.
    public var pinchDissolve: Double = 0.32      // per-photo crossfade fade-out
    public var pinchSettle: Double = 0.50        // bounce settle of the leftover lens scale
    public var pinchLiveSensitivity: Double = 2.4   // grid levels traversed per unit of (shaped) magnification
    public var pinchLiveExponent: Double = 0.70     // <1 → more responsive to tiny finger motion near zero

    // Sidebar slide (spring).
    public var sidebarResponse: Double = 0.40
    public var sidebarDamping: Double = 0.82

    // Shared-element photo open/close (springs).
    public var zoomOpenResponse: Double = 0.34
    public var zoomOpenDamping: Double = 0.86
    public var zoomCloseResponse: Double = 0.32
    public var zoomCloseDamping: Double = 0.88

    // Info panel slide.
    public var infoPanel: Double = 0.25

    /// (label, keyPath, range) for every tunable, so the tuning UI can render generically.
    public static let fields: [(String, ReferenceWritableKeyPath<AnimationTuning, Double>, ClosedRange<Double>)] = [
        ("Pinch crossfade", \.pinchDissolve, 0.05...0.8),
        ("Pinch settle bounce", \.pinchSettle, 0.1...1.2),
        ("Pinch sensitivity", \.pinchLiveSensitivity, 1.0...4.5),
        ("Pinch exponent", \.pinchLiveExponent, 0.4...1.0),
        ("Sidebar response", \.sidebarResponse, 0.1...0.9),
        ("Sidebar damping", \.sidebarDamping, 0.4...1.0),
        ("Photo open response", \.zoomOpenResponse, 0.1...0.8),
        ("Photo open damping", \.zoomOpenDamping, 0.4...1.0),
        ("Photo close response", \.zoomCloseResponse, 0.1...0.8),
        ("Photo close damping", \.zoomCloseDamping, 0.4...1.0),
        ("Info panel", \.infoPanel, 0.05...0.6),
    ]

    public func reset() {
        pinchDissolve = 0.32; pinchSettle = 0.50
        pinchLiveSensitivity = 2.4; pinchLiveExponent = 0.70
        sidebarResponse = 0.40; sidebarDamping = 0.82
        zoomOpenResponse = 0.34; zoomOpenDamping = 0.86
        zoomCloseResponse = 0.32; zoomCloseDamping = 0.88
        infoPanel = 0.25
    }
}
