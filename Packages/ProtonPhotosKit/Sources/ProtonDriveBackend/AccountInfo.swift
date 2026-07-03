import Foundation
import Observation

/// Account-level info surfaced in Settings - the Proton storage quota and the primary address. Populated from
/// the `/core/v4/users` + `/addresses` responses that `DriveSession.fetchAccountData()` already fetches (and
/// caches), so it's available offline too (last-known values from the encrypted account cache). No extra
/// network call.
@MainActor
@Observable
public final class AccountInfo {
    public static let shared = AccountInfo()

    public private(set) var usedSpaceBytes: Int64?
    public private(set) var maxSpaceBytes: Int64?
    /// The account's primary email address, shown in the Settings account section. Nil until the address list
    /// has been decoded (live or cached).
    public private(set) var primaryEmail: String?

    private init() {}

    public func update(usedBytes: Int64, maxBytes: Int64) {
        usedSpaceBytes = usedBytes
        maxSpaceBytes = maxBytes
    }

    public func update(primaryEmail: String?) {
        guard let primaryEmail, !primaryEmail.isEmpty else { return }
        self.primaryEmail = primaryEmail
    }
}
