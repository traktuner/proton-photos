import Foundation

/// Deterministic exponential backoff for backup sync work. Pure so every platform shares one
/// retry truth and tests can assert exact delays. No random jitter: this is a single-user client
/// queue, and determinism (crash-replayable, testable) is worth more here than fleet smearing.
public struct BackupRetryPolicy: Sendable, Equatable {
    /// Delay after the first failed attempt.
    public var baseDelay: TimeInterval
    /// Hard cap for any computed delay.
    public var maxDelay: TimeInterval
    /// Attempts after which an item is parked as `.failed` (surfaced as "needs attention")
    /// instead of being retried again.
    public var maxAttempts: Int

    public init(baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 900, maxAttempts: Int = 8) {
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(self.baseDelay, maxDelay)
        self.maxAttempts = max(1, maxAttempts)
    }

    /// The wait before the NEXT try, given how many attempts have already failed.
    /// `attempts <= 0` means nothing failed yet - no delay.
    public func delay(afterAttempts attempts: Int) -> TimeInterval {
        guard attempts > 0 else { return 0 }
        // Clamp the exponent so the pow can never overflow into infinity before the cap applies.
        let exponent = Double(min(attempts, 32) - 1)
        return min(maxDelay, baseDelay * pow(2, exponent))
    }

    /// True once an item has burned through its retry budget and must be parked, not retried.
    public func shouldPark(attempts: Int) -> Bool {
        attempts >= maxAttempts
    }
}
