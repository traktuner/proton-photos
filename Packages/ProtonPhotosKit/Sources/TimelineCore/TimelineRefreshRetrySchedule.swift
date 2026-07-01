import Foundation

public struct TimelineRefreshRetrySchedule: Sendable, Equatable {
    public let delays: [Duration]

    public init(delays: [Duration]) {
        self.delays = delays
    }

    /// Immediate refresh, then bounded eventual-consistency retries. Total wait: 30 seconds.
    public static let uploadDefault = TimelineRefreshRetrySchedule(
        delays: [.zero, .seconds(1), .seconds(3), .seconds(8), .seconds(18)]
    )
}
