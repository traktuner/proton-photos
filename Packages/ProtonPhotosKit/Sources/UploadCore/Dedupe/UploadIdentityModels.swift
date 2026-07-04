import Foundation
import PhotosCore

// MARK: - Source identity

/// Stable, platform-neutral identity of ONE uploadable resource at its source. Every upload path
/// (macOS file/folder pickers today, iOS/iPadOS PhotoKit auto-backup later) describes its work in
/// these terms, so the dedupe pipeline has a single identity vocabulary across platforms.
public struct UploadSourceIdentity: Sendable, Hashable, Codable {
    /// Which adapter produced the resource - the namespace of `identifier`.
    public enum Kind: String, Sendable, Codable {
        /// A file on disk; `identifier` is the absolute file-system path.
        case fileURL
        /// A PhotoKit asset resource; `identifier` is the `PHAsset.localIdentifier`. Defined now
        /// so the future iOS auto-backup source shares the manifest without a schema change.
        case photoLibraryAsset
    }

    /// The role of this resource within its compound (a Live Photo is one compound with a primary
    /// photo + a paired video resource; a plain photo/video is a compound of one primary).
    public enum Resource: String, Sendable, Codable {
        case primary
        /// A Live Photo's paired video (uploaded with `mainPhotoUid` pointing at the primary).
        case livePairedVideo
    }

    public let kind: Kind
    public let identifier: String
    public let resource: Resource

    public init(kind: Kind, identifier: String, resource: Resource = .primary) {
        self.kind = kind
        self.identifier = identifier
        self.resource = resource
    }

    /// Identity of a local file upload (the macOS manual path).
    public static func file(_ url: URL, resource: Resource = .primary) -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .fileURL, identifier: url.standardizedFileURL.path, resource: resource)
    }
}

// MARK: - Resource descriptor

/// Everything a source adapter must state about one resource BEFORE any bytes are read - the input
/// to hashing, cache validity, and the duplicate check. Platform adapters only construct these;
/// they never make dedupe decisions themselves.
public struct UploadResourceDescriptor: Sendable {
    public let source: UploadSourceIdentity
    /// Local file readable for streaming (the original on macOS; a temp export for PhotoKit).
    public let fileURL: URL
    /// The claimed original filename (used for Proton name correction + the name hash).
    public let filename: String
    public let fileSize: Int64
    public let modificationDate: Date
    /// The primary resource of this compound when `source.resource` is secondary - lets a future
    /// Live Photo path upload only the missing paired video via `mainPhotoUid`.
    public let mainResource: UploadSourceIdentity?

    public init(
        source: UploadSourceIdentity,
        fileURL: URL,
        filename: String,
        fileSize: Int64,
        modificationDate: Date,
        mainResource: UploadSourceIdentity? = nil
    ) {
        self.source = source
        self.fileURL = fileURL
        self.filename = filename
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.mainResource = mainResource
    }
}

// MARK: - Computed identity

/// The Proton-compatible identity of one resource: what the duplicate check compares and what the
/// upload itself needs (`expectedSHA1`). Hashes are lowercase hex.
public struct UploadIdentity: Sendable, Equatable {
    /// Proton-corrected filename (invalid characters replaced, whitespace trimmed) - the name that
    /// is actually uploaded AND hashed, so local and remote agree.
    public let correctedName: String
    /// HMAC-SHA256(correctedName, photos root hash key) - Proton's duplicate lookup key.
    public let nameHash: String
    /// Lowercase hex SHA-1 of the raw file bytes.
    public let sha1Hex: String
    /// The same SHA-1 as 20 raw bytes - passed to the SDK upload as `expectedSHA1`.
    public let sha1Digest: Data
    /// HMAC-SHA256(sha1Hex, photos root hash key) - Proton's content identity.
    public let contentHash: String

    public init(correctedName: String, nameHash: String, sha1Hex: String, sha1Digest: Data, contentHash: String) {
        self.correctedName = correctedName
        self.nameHash = nameHash
        self.sha1Hex = sha1Hex
        self.sha1Digest = sha1Digest
        self.contentHash = contentHash
    }
}

// MARK: - Remote duplicate state

/// One remote row from Proton's find-duplicates endpoint (`DuplicateHashes[]`), reduced to what
/// the decision policy needs. Backend adapters map wire JSON to this; the policy never sees
/// transport types.
public struct RemotePhotoDuplicate: Sendable, Equatable {
    /// `LinkState` raw values of the duplicates payload (Proton Drive iOS 1.61.0,
    /// `FindDuplicatesEndpoint`). A missing state (`nil`) means the link was deleted.
    public enum LinkState: Int, Sendable {
        case draft = 0
        case active = 1
        case trashed = 2
    }

    /// The remote NAME hash this row matched (wire key `Hash`).
    public let nameHash: String
    /// The remote content hash HMAC (wire key `ContentHash`), when the server returns one.
    public let contentHash: String?
    public let linkState: LinkState?
    public let linkID: String?
    /// The uploading client's self-chosen identifier (Proton currently ignores it during the
    /// duplicate check; carried for a future stale-draft cleanup).
    public let clientUID: String?

    public init(
        nameHash: String,
        contentHash: String?,
        linkState: LinkState?,
        linkID: String?,
        clientUID: String? = nil
    ) {
        self.nameHash = nameHash
        self.contentHash = contentHash
        self.linkState = linkState
        self.linkID = linkID
        self.clientUID = clientUID
    }
}

// MARK: - Decision

/// The dedupe outcome for one compound - the single vocabulary every platform's upload path acts
/// on. Produced ONLY by `UploadDuplicateDecisionPolicy` so the semantics have one implementation.
///
/// Deliberately NO rename case: Proton photo shares tolerate duplicate name hashes, so a name
/// match with different content uploads as a brand-new photo under the SAME name.
public enum UploadDuplicateDecision: Sendable, Equatable {
    /// Why a compound is skipped instead of uploaded.
    public enum SkipReason: Sendable, Equatable {
        /// An ACTIVE remote photo already has this exact name + content (and, for compounds, all
        /// secondary resources). Nothing to do.
        case activeDuplicate
        /// The identical photo sits in the user's trash - they deleted it intentionally, so
        /// re-uploading would resurrect unwanted data.
        case trashedDuplicate
        /// A remote DRAFT occupies this name hash (an upload in progress, possibly by another
        /// client). Proton skips rather than racing it.
        case draftExists
        /// The identical photo existed remotely and was deleted (state absent) - treated as a
        /// deliberate user deletion.
        case deletedRemotely
        /// The server confirmed a duplicate but the response was missing the link id - the data
        /// is inconsistent, so the safe action is to not upload.
        case inconsistentRemoteState
        /// The persistent manifest remembers this exact resource as already uploaded / an active
        /// duplicate - skipped without a remote round-trip.
        case knownFromManifest
    }

    /// No remote occupant blocks the compound - push the bytes (with the unchanged name).
    case upload
    /// The compound (primary + all secondaries) is already represented remotely; do not upload.
    /// `remoteLinkID` identifies the existing primary when the server/manifest provided it.
    case skip(SkipReason, remoteLinkID: String?)
    /// The primary photo exists remotely and stays untouched, but these secondary resources are
    /// missing and should be uploaded with `mainPhotoUid = primaryLinkID`.
    case uploadMissingSecondaries(primaryLinkID: String, missing: [UploadSourceIdentity])

    /// True for every case that must NOT upload the primary resource.
    public var skipsPrimaryUpload: Bool {
        if case .upload = self { return false }
        return true
    }
}

// MARK: - Persistent manifest record

/// One row of the persistent upload-identity manifest: enough to skip rehashing an unchanged local
/// resource and to remember a still-valid duplicate decision. Never stores plaintext content -
/// only names, sizes, dates, and hex hashes.
public struct UploadIdentityRecord: Sendable, Equatable {
    public var source: UploadSourceIdentity
    public var filename: String
    public var correctedName: String
    public var fileSize: Int64
    public var modificationDate: Date
    public var sha1Hex: String
    public var nameHash: String
    public var contentHash: String
    /// Fingerprint of the photos-root hash key the HMACs were computed with (an irreversible
    /// digest prefix, never key material). A different epoch - the photos share was recreated -
    /// invalidates the cached HMACs while the SHA-1 stays reusable.
    public var hashKeyEpoch: String
    /// The remote photo this resource is known to be (an ACTIVE duplicate or our own completed
    /// upload), as `volumeID` + `linkID`.
    public var remoteVolumeID: String?
    public var remoteLinkID: String?
    /// Raw persisted form of the last decision (see `UploadIdentityManifestStore.Outcome`).
    public var outcome: String?
    public var updatedAt: Date

    public init(
        source: UploadSourceIdentity,
        filename: String,
        correctedName: String,
        fileSize: Int64,
        modificationDate: Date,
        sha1Hex: String,
        nameHash: String,
        contentHash: String,
        hashKeyEpoch: String,
        remoteVolumeID: String? = nil,
        remoteLinkID: String? = nil,
        outcome: String? = nil,
        updatedAt: Date
    ) {
        self.source = source
        self.filename = filename
        self.correctedName = correctedName
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.sha1Hex = sha1Hex
        self.nameHash = nameHash
        self.contentHash = contentHash
        self.hashKeyEpoch = hashKeyEpoch
        self.remoteVolumeID = remoteVolumeID
        self.remoteLinkID = remoteLinkID
        self.outcome = outcome
        self.updatedAt = updatedAt
    }

    /// Conservative cache validity for the SHA-1: reusable ONLY when every cheap attribute still
    /// matches exactly. Any drift - size, mtime, name, or a different claimed filename - forces a
    /// rehash. Equal mtimes compare in the same `timeIntervalSince1970` projection they were
    /// persisted in, so filesystem/date round-trips stay exact.
    public func isValid(for descriptor: UploadResourceDescriptor) -> Bool {
        source == descriptor.source
            && filename == descriptor.filename
            && fileSize == descriptor.fileSize
            && modificationDate.timeIntervalSince1970 == descriptor.modificationDate.timeIntervalSince1970
    }

    /// Cached HMACs (name/content hash) are additionally keyed by the hash-key epoch.
    public func isValid(for descriptor: UploadResourceDescriptor, hashKeyEpoch epoch: String) -> Bool {
        isValid(for: descriptor) && hashKeyEpoch == epoch
    }
}

// MARK: - Pipeline seams

/// Persistent identity manifest - implemented by `UploadIdentityManifestStore` (SQLite) in
/// production and by an in-memory fake in tests.
public protocol UploadIdentityStore: Sendable {
    func record(for source: UploadSourceIdentity) -> UploadIdentityRecord?
    func upsert(_ record: UploadIdentityRecord)
}

/// Local content hashing (streaming SHA-1). Separated behind a protocol so tests can fake byte
/// identity without files, and so a future PhotoKit source can substitute hash-while-exporting.
/// Async so hashing runs off the pipeline actor - concurrent items hash concurrently and the
/// queue stays responsive during a multi-gigabyte video.
public protocol UploadHashing: Sendable {
    /// The 20-byte SHA-1 of the resource's bytes. Must stream (O(buffer) memory) and must honour
    /// task cancellation between chunks.
    func sha1(of descriptor: UploadResourceDescriptor) async throws -> Data
}

/// Default file-URL hasher used by every platform's local-file path.
public struct UploadFileHasher: UploadHashing {
    public init() {}

    public func sha1(of descriptor: UploadResourceDescriptor) async throws -> Data {
        try UploadContentSHA1.digest(ofFileAt: descriptor.fileURL)
    }
}

/// Proton-keyed identity hashing + the remote duplicate lookup. Implemented in ProtonDriveBackend
/// (the only layer that can reach the photos root hash key and the authenticated API).
public protocol UploadDuplicateChecking: Sendable {
    /// HMAC-SHA256 over the corrected name, keyed with the photos root hash key. Lowercase hex.
    func nameHash(forCorrectedName name: String) async throws -> String
    /// HMAC-SHA256 over the lowercase-hex SHA-1 string, same key. Lowercase hex.
    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String
    /// Remote occupants of the given name hashes. Callers pass at most
    /// `UploadDedupePipeline.protonDuplicateBatchSize` hashes per call.
    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate]
    /// Irreversible fingerprint of the current photos-root hash key (for manifest validity) -
    /// never the key itself.
    func hashKeyEpoch() async throws -> String
}

/// The pipeline seam `UploadManager` drives: resolve one descriptor to its identity + decision.
/// ONE implementation (`UploadDedupePipeline`) serves every platform.
public protocol UploadIdentityResolving: Sendable {
    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult
    /// Batch-prefetch duplicate states for a fresh enqueue batch (Proton queries name hashes in
    /// chunks of 150). Best-effort: failures surface later through per-item `resolve`.
    func prime(_ descriptors: [UploadResourceDescriptor]) async
    /// Records that `descriptor` was uploaded as `remoteLinkID` so later runs can skip it without
    /// a remote round-trip.
    func recordUploaded(_ descriptor: UploadResourceDescriptor, identity: UploadIdentity, remoteVolumeID: String, remoteLinkID: String) async
}

public extension UploadIdentityResolving {
    func prime(_ descriptors: [UploadResourceDescriptor]) async {}
}

/// The outcome of the pre-upload phase for one resource.
public struct UploadPreflightResult: Sendable, Equatable {
    public let identity: UploadIdentity
    public let decision: UploadDuplicateDecision

    public init(identity: UploadIdentity, decision: UploadDuplicateDecision) {
        self.identity = identity
        self.decision = decision
    }
}
