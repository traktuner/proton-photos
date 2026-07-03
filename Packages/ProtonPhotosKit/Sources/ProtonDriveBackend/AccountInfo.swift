import Foundation
import Observation

/// Account-level info surfaced in Settings - currently the Proton storage quota. Populated from the
/// `/core/v4/users` response that `DriveSession.fetchAccountData()` already fetches (and caches), so it's
/// available offline too (last-known values from the encrypted account cache). No extra network call.
@MainActor
@Observable
public final class AccountInfo {
    public static let shared = AccountInfo()

    public private(set) var usedSpaceBytes: Int64?
    public private(set) var maxSpaceBytes: Int64?

    private init() {}

    public func update(usedBytes: Int64, maxBytes: Int64) {
        usedSpaceBytes = usedBytes
        maxSpaceBytes = maxBytes
    }
}
