import Foundation
import Observation

/// Account-level info surfaced in Settings — currently the Proton storage quota. Populated from the
/// `/core/v4/users` response that `DriveSession.fetchAccountData()` already fetches (and caches), so it's
/// available offline too (last-known values from the encrypted account cache). No extra network call.
@MainActor
@Observable
final class AccountInfo {
    static let shared = AccountInfo()

    private(set) var usedSpaceBytes: Int64?
    private(set) var maxSpaceBytes: Int64?

    private init() {}

    func update(usedBytes: Int64, maxBytes: Int64) {
        usedSpaceBytes = usedBytes
        maxSpaceBytes = maxBytes
    }
}
