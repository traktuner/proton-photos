import Foundation

// MARK: - Level-binding reconciliation (host-led commit vs SwiftUI @Binding echo)
//
// A trackpad pinch commits ENTIRELY on the AppKit side first: the host advances `coordinator.level` to the
// settled level N and only THEN pushes N to the SwiftUI `@Binding level` (`onZoomCommit`). SwiftUI defers the
// resulting body re-evaluation, so until the binding propagates, an `updateNSView` pass driven by some OTHER
// coincident parent-state change (selection, sidebar safe-area inset, route generation, item count, …) can be
// delivered carrying the PRE-commit binding value S (≠ N).
//
// The legacy reconciliation `if level != coordinator.level { animateToLevel(level) }` would then re-issue a
// `setLevel(S)` — which, with no explicit anchor, re-anchors at the VIEWPORT CENTRE (`MetalGridScrollHost`),
// pinning the centre item under the cursor instead of the cursor item. The grid visibly jumps to a different
// photo; worse, that spurious zoom drives `coordinator.level` back to S without re-syncing the binding, so the
// genuine `binding == N` pass then re-drives `animateToLevel(N)` — an N→S→N oscillation that matches the
// reported "reverse lands on yet another photo".
//
// THE RULE (pure, headless, unit-tested): after a host-led commit that actually CHANGED the level, remember the
// pre-commit level as a one-shot "stale echo". While that echo is armed, ignore exactly that stale binding
// value (more than one such pass may arrive before the committed value lands); the instant the binding agrees
// with the host (`binding == hostLevel`), clear the latch. Any OTHER binding value is a genuine external
// (+/- / keyboard / programmatic) change and is honoured immediately — which also clears the latch, so a
// legitimate change can never be swallowed for more than the single stale value, and the latch can never stick.
enum LevelBindingReconciler {
    enum Action: Equatable {
        case ignore            // already in sync, or a stale post-commit echo — do nothing
        case clearLatch        // the binding caught up to the host level — clear the echo guard, do nothing else
        case reDrive(Int)      // a genuine external level change — drive `animateToLevel(_)` (and clear the guard)
    }

    /// Decide what an `updateNSView` pass should do with a delivered `level`-binding value.
    /// - Parameters:
    ///   - binding:   the SwiftUI `@Binding level` value delivered to this pass.
    ///   - hostLevel: the host's authoritative `coordinator.level`.
    ///   - staleEcho: the pre-commit level whose lingering binding echo must be ignored (nil = none armed).
    static func decide(binding: Int, hostLevel: Int, staleEcho: Int?) -> Action {
        if binding == hostLevel { return .clearLatch }                  // binding consistent with the host
        if let staleEcho, binding == staleEcho { return .ignore }       // stale pre-commit echo → ignore (keep armed)
        return .reDrive(binding)                                        // genuine external change → honour + clear
    }
}
