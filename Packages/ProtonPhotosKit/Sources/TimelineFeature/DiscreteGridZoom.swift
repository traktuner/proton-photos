import CoreGraphics
import Foundation

// Discrete-only grid zoom (the ONLY zoom path). The + / − toolbar buttons are the source of truth;
// a trackpad pinch simply mirrors them — one pinch gesture = at most one discrete step. There is NO
// continuous live scaling, NO per-photo morphing, NO topology rebase. A level change runs a short
// full-grid crossfade (old grid dissolves into the new grid). Everything here is pure + headlessly
// testable; the AppKit coordinator (`PhotoGridView.Coordinator`) owns the snapshot/commit/crossfade.

/// Tuning constants for the discrete grid zoom, grouped so the pinch threshold and crossfade timing
/// are adjustable + testable in one place.
enum DiscreteGridZoomTuning {
    /// Accumulated trackpad magnification (sum of raw `event.magnification` deltas within one gesture)
    /// that triggers ONE discrete zoom step. Modest so a deliberate pinch fires quickly, but large
    /// enough to ignore trackpad noise. Spec range: 0.08–0.12.
    static let pinchStepThreshold: CGFloat = 0.10
    /// Full-grid crossfade duration when the level changes (old grid fades out over the new grid).
    /// Spec range: 0.12–0.20s.
    static let crossfadeDuration: TimeInterval = 0.16
    /// Minimum time between two pinch-triggered steps, so a single noisy gesture (or a spurious second
    /// begin/end cycle) cannot fire twice in a row.
    static let pinchCooldown: TimeInterval = 0.18
}

/// Direction of a discrete zoom step. `zoomIn` = bigger thumbnails (lower level index, toward 0, the
/// `+` button); `zoomOut` = smaller thumbnails (higher level index, the `−` button).
enum GridZoomDirection: Equatable { case zoomIn, zoomOut }

/// Why a discrete zoom happened — used only for the `[GridZoom]` runtime logs and tests.
enum GridZoomTrigger: String { case buttonPlus, buttonMinus, pinchIn, pinchOut }

/// The discrete-zoom transition state machine. A level change runs a short full-grid crossfade; while
/// it runs we must NOT start a second overlapping transition.
enum DiscreteZoomState: Equatable {
    case idle
    case transitioning(from: Int, to: Int)
    var isTransitioning: Bool { if case .transitioning = self { return true } else { return false } }
}

/// Clamp a zoom level into `0 ..< count`.
func clampGridLevel(_ level: Int, count: Int) -> Int { min(max(level, 0), max(0, count - 1)) }

/// The level reached by ONE discrete step in `direction` from `current`, clamped. zoomIn → toward 0
/// (bigger), zoomOut → toward `count-1` (smaller). Pure, so `+`/`−` and pinch share ONE definition of
/// what a step is.
func steppedGridLevel(current: Int, direction: GridZoomDirection, count: Int) -> Int {
    switch direction {
    case .zoomIn:  return clampGridLevel(current - 1, count: count)
    case .zoomOut: return clampGridLevel(current + 1, count: count)
    }
}

/// Pure pinch → single-step detector. Accumulates raw trackpad magnification deltas and emits a
/// direction EXACTLY ONCE per gesture, the moment `|accumulated|` crosses `threshold`. The grid is
/// never scaled continuously: everything past the threshold is ignored until the gesture ends and a
/// new one begins. Per spec, positive magnification → `zoomIn`; negative → `zoomOut`.
struct PinchStepDetector {
    var threshold: CGFloat
    private(set) var accumulated: CGFloat = 0
    private(set) var firedThisGesture = false
    private var active = false

    init(threshold: CGFloat = DiscreteGridZoomTuning.pinchStepThreshold) { self.threshold = threshold }

    /// Start a fresh gesture (trackpad `.began`). Resets accumulation and the one-shot latch.
    mutating func begin() { active = true; accumulated = 0; firedThisGesture = false }

    /// Feed one raw `event.magnification` delta. Returns a direction the single time the threshold is
    /// crossed within a gesture, then `nil` for the rest of that gesture (so there is no continuous
    /// stepping). Auto-begins a gesture if `.began` was never delivered.
    mutating func accumulate(_ delta: CGFloat) -> GridZoomDirection? {
        if !active { begin() }
        guard !firedThisGesture else { accumulated += delta; return nil }
        accumulated += delta
        if accumulated >= threshold { firedThisGesture = true; return .zoomIn }
        if accumulated <= -threshold { firedThisGesture = true; return .zoomOut }
        return nil
    }

    /// End the gesture (trackpad `.ended`/`.cancelled`). The next delta starts a new gesture.
    mutating func end() { active = false }
}

/// Drives the discrete-zoom state machine. It decides whether a requested level change may START now,
/// or must be queued (exactly one latest) because a crossfade is already running. Pure + testable; the
/// AppKit coordinator owns the actual snapshot/commit/crossfade and calls `finishTransition()` when the
/// crossfade completes.
struct DiscreteZoomController {
    private(set) var state: DiscreteZoomState = .idle
    private(set) var queuedTarget: Int?

    /// Request a transition `from → to`. Returns true if the caller should START the crossfade now;
    /// false if it was a no-op (same level) or got queued behind the running transition (latest wins).
    mutating func requestTransition(from: Int, to: Int) -> Bool {
        guard to != from else { return false }
        if state.isTransitioning {
            queuedTarget = (to == currentDestination) ? nil : to
            return false
        }
        state = .transitioning(from: from, to: to)
        return true
    }

    /// Mark the running transition finished (success OR failure). Returns the queued target to run
    /// next, if any, and clears it. Always returns the machine to `.idle` so a failed transition can
    /// never wedge the grid.
    mutating func finishTransition() -> Int? {
        state = .idle
        defer { queuedTarget = nil }
        return queuedTarget
    }

    private var currentDestination: Int? {
        if case .transitioning(_, let to) = state { return to } else { return nil }
    }
}

/// DEBUG-only tripwire proving the old continuous/live zoom path is unreachable from production. The
/// quarantined live-zoom functions increment this; the discrete path never touches it, and the runtime
/// logs `oldLiveZoomPathUsed=false` on every step. `OldLivePathDisabledTest` asserts it stays 0.
enum DiscreteGridZoomDiagnostics {
    nonisolated(unsafe) static var oldLiveZoomPathInvocations = 0
}
