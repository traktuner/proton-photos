import Foundation

/// Time-aware hysteresis over `BackupStatusPresentation` so the backup row reads calmly.
///
/// The umbrella headline is already stable (the presentation maps every active phase to the same
/// key), but the calm subtitle still tracks the underlying phase, which cycles checking↔uploading
/// many times a second while a drain is in flight. This stabilizer dwells that subtitle: once the
/// displayed subtitle changes it will not change again for `dwell`, so the row switches text at most
/// about once a second. Numeric progress within an unchanged subtitle passes through immediately (it
/// advances slowly on its own), and any STRUCTURAL change - entering/leaving active, or reaching a
/// terminal/paused/attention state - applies at once so nothing important is delayed.
///
/// It is a pure value type driven by an injected clock: the caller feeds each incoming presentation
/// via `ingest(_:now:)`, renders `Decision.display`, and - when `Decision.wakeAt` is non-nil -
/// schedules a SINGLE `wake(now:)` at that time to apply a deferred switch. No repeating timer.
public struct BackupStatusStabilizer: Sendable {

    public struct Decision: Sendable, Equatable {
        /// The presentation to show right now.
        public var display: BackupStatusPresentation
        /// If non-nil, the caller should call `wake(now:)` once at this instant to apply a subtitle
        /// change that is currently being held back. nil = nothing pending.
        public var wakeAt: Date?
    }

    /// Minimum time the active subtitle stays put before it may change again.
    public let dwell: TimeInterval

    private var displayed: BackupStatusPresentation?
    private var latestIncoming: BackupStatusPresentation?
    /// When the currently-displayed ACTIVE subtitle was last applied.
    private var subtitleAppliedAt: Date?

    public init(dwell: TimeInterval = 1.2) {
        self.dwell = max(0, dwell)
    }

    /// Feed the newest presentation and get what to display now.
    public mutating func ingest(_ incoming: BackupStatusPresentation, now: Date) -> Decision {
        latestIncoming = incoming
        return evaluate(now: now)
    }

    /// Re-evaluate a previously-held switch (call once at the `wakeAt` the last decision returned).
    public mutating func wake(now: Date) -> Decision {
        evaluate(now: now)
    }

    /// The presentation currently on screen, if any (nil before the first ingest).
    public var current: BackupStatusPresentation? { displayed }

    private mutating func evaluate(now: Date) -> Decision {
        guard let incoming = latestIncoming else {
            return Decision(display: displayed ?? Self.restingIdle, wakeAt: nil)
        }
        guard let current = displayed else {
            apply(incoming, at: now)
            return Decision(display: incoming, wakeAt: nil)
        }

        // Structural change - entering/leaving active, or any non-active target (completed, paused,
        // waiting, attention, idle) - is never delayed.
        if !incoming.isActive || !current.isActive {
            apply(incoming, at: now)
            return Decision(display: incoming, wakeAt: nil)
        }

        // Both active and the calm subtitle is unchanged: let numbers/progress through immediately.
        if Self.sameSubtitle(current, incoming) {
            displayed = incoming
            return Decision(display: incoming, wakeAt: nil)
        }

        // Both active but the subtitle differs: hold the current coherent presentation until the
        // dwell elapses, so the visible text switches at most once per `dwell`.
        let due = (subtitleAppliedAt ?? now).addingTimeInterval(dwell)
        if now >= due {
            apply(incoming, at: now)
            return Decision(display: incoming, wakeAt: nil)
        }
        return Decision(display: current, wakeAt: due)
    }

    private mutating func apply(_ presentation: BackupStatusPresentation, at now: Date) {
        displayed = presentation
        subtitleAppliedAt = presentation.isActive ? now : nil
    }

    private static func sameSubtitle(_ a: BackupStatusPresentation, _ b: BackupStatusPresentation) -> Bool {
        a.headlineKey == b.headlineKey && a.detailKey == b.detailKey && a.accessory == b.accessory
    }

    private static let restingIdle = BackupStatusPresentation(BackupStatus())
}
