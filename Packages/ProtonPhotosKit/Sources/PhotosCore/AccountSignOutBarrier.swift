import Foundation

/// Owns one ordered account cleanup and rejects overlapping sign-out work.
@MainActor
public final class AccountSignOutBarrier {
    public private(set) var isRunning = false
    private var task: Task<Void, Never>?

    public init() {}

    @discardableResult
    public func begin(_ operation: @escaping @MainActor @Sendable () async -> Void) -> Bool {
        guard task == nil else { return false }
        isRunning = true
        task = Task { @MainActor [self] in
            await operation()
            task = nil
            isRunning = false
        }
        return true
    }

    public func waitUntilFinished() async {
        await task?.value
    }
}
