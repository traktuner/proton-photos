import Foundation

/// Global back-off gate for Proton Drive's rate limits (HTTP 429). When the API tells us to slow
/// down (via `Retry-After`), every Drive request waits out the penalty window before proceeding —
/// mirroring how the official clients gate their request rate. Shared across all HTTP calls.
final class RateLimitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pausedUntil = Date.distantPast

    /// Block until any active rate-limit penalty has elapsed.
    func waitIfNeeded() async {
        while true {
            let remaining = lock.withLock { pausedUntil.timeIntervalSinceNow }
            guard remaining > 0 else { return }
            try? await Task.sleep(for: .seconds(min(remaining, 5)))
        }
    }

    /// Record a back-off (seconds) requested by the server. Extends the window if longer.
    func penalize(seconds: Double) {
        let clamped = max(1, min(seconds, 120))
        lock.withLock {
            let candidate = Date().addingTimeInterval(clamped)
            if candidate > pausedUntil { pausedUntil = candidate }
        }
        DebugLog.log("⚠️ RATE LIMIT (429): backing off \(Int(clamped))s")
    }
}
