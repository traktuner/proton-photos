import Foundation

/// One item the backup could not save, projected for a user-facing list. `reason` is always a clear,
/// already-localized sentence (never a raw error code); `isPermanent` marks the ones where retrying
/// cannot help (the local file is gone) so the UI can say so honestly and not offer a pointless retry.
public struct BackupFailedItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let filename: String
    public let reason: String
    public let isPermanent: Bool

    public init(id: String, filename: String, reason: String, isPermanent: Bool) {
        self.id = id
        self.filename = filename
        self.reason = reason
        self.isPermanent = isPermanent
    }
}
