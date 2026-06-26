import Foundation

/// Production animation constants for the shared-element photo open/close zoom springs.
///
/// This was formerly a live-tunable `@Observable` singleton driven by a developer "Animation Tuning"
/// window. That window (and the runtime tuning UI) has been removed — accepted animations use fixed
/// production constants in code. Only the photo open/close springs are consumed, so only they remain.
/// Durations are in seconds.
public enum AnimationTuning {
    /// Shared-element photo OPEN spring (grid → fullscreen viewer).
    public static let zoomOpenResponse: Double = 0.34
    public static let zoomOpenDamping: Double = 0.86
    /// Shared-element photo CLOSE spring (viewer → grid).
    public static let zoomCloseResponse: Double = 0.32
    public static let zoomCloseDamping: Double = 0.88
}
