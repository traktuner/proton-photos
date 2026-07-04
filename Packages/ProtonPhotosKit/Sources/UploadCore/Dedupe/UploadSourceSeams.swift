import Foundation

// MARK: - Compounds

/// One logical photo as an upload unit: a primary resource plus its secondary resources (a Live
/// Photo's paired video). Manual file uploads are single-resource compounds; the future iOS
/// PhotoKit auto-backup emits real ones. The dedupe policy already understands compounds
/// (`UploadDuplicateDecisionPolicy.decide(primary:secondaries:remoteItems:)`), so wiring compound
/// sources requires no new duplicate semantics.
public struct UploadCompoundDescriptor: Sendable {
    public let primary: UploadResourceDescriptor
    public let secondaries: [UploadResourceDescriptor]

    public init(primary: UploadResourceDescriptor, secondaries: [UploadResourceDescriptor] = []) {
        self.primary = primary
        self.secondaries = secondaries
    }
}

// MARK: - Platform source seam

/// A platform upload source: enumerate compounds for the shared pipeline. Platform adapters
/// implement ONLY this - identity, dedupe, and upload policy stay in core.
///
/// The future `PhotoKitUploadSource` (iOS/iPadOS) streams each `PHAssetResource` into a temp
/// upload file while feeding the same bytes to an `UploadSHA1Accumulator`, so originals are read
/// exactly once; the resulting descriptor points at the temp file and the digest is injected via
/// a caching `UploadHashing` so the pipeline never re-reads it.
public protocol UploadCompoundSource: Sendable {
    /// The compounds this source currently offers, in upload order. Implementations should be
    /// lazy (PhotoKit enumerations are large) and honour task cancellation.
    func compounds() -> AsyncThrowingStream<UploadCompoundDescriptor, any Error>
}

// MARK: - Background checkpoint seam

/// Checkpointing for a future background auto-backup: which sources are done, which remain. The
/// persistent identity manifest already survives crashes (hashes + uploaded outcomes are written
/// as they happen); this seam adds the queue-level bookkeeping a background task needs to resume
/// enumeration without rescanning the whole library.
public protocol UploadBackupCheckpointing: Sendable {
    /// Marks one source (asset/file) as fully handled - uploaded or confirmed duplicate.
    func markCompleted(_ source: UploadSourceIdentity) async
    /// True when the source was already handled by a previous run.
    func isCompleted(_ source: UploadSourceIdentity) async -> Bool
}
