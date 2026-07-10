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
        /// A photo-library asset resource. Platform adapters should prefer the provider's stable
        /// cloud identifier when available and fall back to a local identifier only when they must.
        /// Defined now so future iOS/iPadOS/macOS photo-library backup sources share the manifest
        /// without a schema change.
        case photoLibraryAsset
    }

    /// The role of this resource within its compound. Kept as an open raw-value wrapper because
    /// PhotoKit can expose more than the original Live-Photo pair: RAW alternates, edited renders,
    /// adjustment data, proxy resources, and future resource types must be representable without a
    /// schema migration or a platform-specific fork.
    public struct Resource: RawRepresentable, Sendable, Hashable, Codable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue.isEmpty ? Self.primary.rawValue : rawValue
        }

        public static let primary = Resource(rawValue: "primary")
        /// Backward-compatible identity for the classic Live Photo paired video.
        public static let livePairedVideo = Resource(rawValue: "livePairedVideo")

        public static func photoKit(role: String, ordinal: Int) -> Resource {
            Resource(rawValue: "photoKit.\(role).\(max(0, ordinal))")
        }
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
    /// Local file readable for upload. For a deferred PhotoKit descriptor this is a placeholder;
    /// the precomputed digest is sufficient for dedupe and Core materializes a real file only for
    /// an `.upload` decision.
    public let fileURL: URL
    /// The claimed original filename (used for Proton name correction + the name hash).
    public let filename: String
    public let fileSize: Int64
    public let modificationDate: Date
    /// Digest produced while the source streamed its bytes. PhotoKit supplies it before any temp
    /// export; local-file adapters leave it nil and use the shared streaming file hasher.
    public let precomputedSHA1Digest: Data?
    /// The primary resource of this compound when `source.resource` is secondary - lets a future
    /// Live Photo path upload only the missing paired video via `mainPhotoUid`.
    public let mainResource: UploadSourceIdentity?

    public init(
        source: UploadSourceIdentity,
        fileURL: URL,
        filename: String,
        fileSize: Int64,
        modificationDate: Date,
        precomputedSHA1Digest: Data? = nil,
        mainResource: UploadSourceIdentity? = nil
    ) {
        self.source = source
        self.fileURL = fileURL
        self.filename = filename
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.precomputedSHA1Digest = precomputedSHA1Digest
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
    /// Any row proving THIS CONTENT is already represented remotely for this account: same
    /// content-hash HMAC under the same key epoch, with a trustworthy outcome (`uploaded` or
    /// `duplicateActive`) and a remote link. Source-path and filename independent - this is what
    /// lets a copied folder (or a renamed file) skip re-uploading bytes the account already owns.
    /// Trashed/deleted outcomes are deliberately NOT trustworthy here.
    func trustedRecord(contentHash: String, hashKeyEpoch: String) -> UploadIdentityRecord?
    @discardableResult
    func upsert(_ record: UploadIdentityRecord) -> Bool
}

/// One active remote photo identity retained by the local content index. The hash is already keyed
/// to the account's photos root; no plaintext filename or media bytes are stored.
public struct UploadRemoteContentIndexRecord: Sendable, Equatable {
    public var contentHash: String
    public var hashKeyEpoch: String
    public var remoteLinkID: String

    public init(contentHash: String, hashKeyEpoch: String, remoteLinkID: String) {
        self.contentHash = contentHash
        self.hashKeyEpoch = hashKeyEpoch
        self.remoteLinkID = remoteLinkID
    }
}

/// Durable volume-event frontier for the remote content index. A page is applied transactionally
/// with its next event ID, so a crash either replays the whole page or resumes after all its rows.
public struct UploadRemoteContentIndexCheckpoint: Sendable, Equatable {
    public var eventID: String
    public var refreshedAt: Date

    public init(eventID: String, refreshedAt: Date) {
        self.eventID = eventID
        self.refreshedAt = refreshedAt
    }
}

/// One active remote compound proved by encrypted source metadata. `remoteLinkIDs` contains the
/// primary and every related resource that contributed to `resourceCount`; any event touching one
/// of those links invalidates the whole proof.
public struct UploadRemoteAssetIndexRecord: Sendable, Equatable {
    public var externalIdentity: UploadBackupExternalIdentity
    public var resourceCount: Int
    public var remoteLinkIDs: [String]
    public var hashKeyEpoch: String

    public init(
        externalIdentity: UploadBackupExternalIdentity,
        resourceCount: Int,
        remoteLinkIDs: [String],
        hashKeyEpoch: String
    ) {
        self.externalIdentity = externalIdentity
        self.resourceCount = max(1, resourceCount)
        self.remoteLinkIDs = remoteLinkIDs
        self.hashKeyEpoch = hashKeyEpoch
    }
}

/// Persistent, platform-neutral cache for account-wide content dedupe. Proton-specific code owns
/// remote enumeration and event decoding; Core owns the transactional storage contract.
public protocol UploadRemoteContentIndexStore: Sendable {
    func remoteContentRecord(contentHash: String, hashKeyEpoch: String) -> UploadRemoteContentIndexRecord?
    func remoteContentIndexCheckpoint(hashKeyEpoch: String) -> UploadRemoteContentIndexCheckpoint?
    func hasRemoteAssetIndexCheckpoint(hashKeyEpoch: String) -> Bool
    func remoteAssetRecords(
        for identities: [UploadBackupExternalIdentity],
        hashKeyEpoch: String
    ) -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord]
    /// True when at least one active remote photo could not provide a SHA-1 identity. A content miss
    /// is not safe to interpret as unique while this is true.
    func hasUnresolvedRemoteContent(hashKeyEpoch: String) -> Bool
    @discardableResult
    func replaceRemoteContentIndex(
        _ records: [UploadRemoteContentIndexRecord],
        remoteAssetRecords: [UploadRemoteAssetIndexRecord],
        unresolvedRemoteLinkIDs: [String],
        hashKeyEpoch: String,
        checkpoint: UploadRemoteContentIndexCheckpoint
    ) -> Bool
    @discardableResult
    func applyRemoteContentIndexChanges(
        upserting records: [UploadRemoteContentIndexRecord],
        upsertingRemoteAssetRecords: [UploadRemoteAssetIndexRecord],
        unresolvedRemoteLinkIDs: [String],
        removingRemoteLinkIDs: [String],
        hashKeyEpoch: String,
        checkpoint: UploadRemoteContentIndexCheckpoint
    ) -> Bool
    @discardableResult
    func upsertRemoteContentRecord(_ record: UploadRemoteContentIndexRecord) -> Bool
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
        if let digest = descriptor.precomputedSHA1Digest {
            guard digest.count == 20 else {
                throw UploadError.backend("Invalid precomputed SHA-1 digest")
            }
            return digest
        }
        return try UploadContentSHA1.digest(ofFileAt: descriptor.fileURL)
    }
}

/// Proton-keyed identity hashing + the remote duplicate lookup. Implemented in ProtonDriveBackend
/// (the only layer that can reach the photos root hash key and the authenticated API).
public protocol UploadDuplicateChecking: Sendable {
    /// HMAC-SHA256 over the corrected name, keyed with the photos root hash key. Lowercase hex.
    func nameHash(forCorrectedName name: String) async throws -> String
    /// Batch form used by large backup lookaheads. Implementations that own the key material can
    /// resolve it once and hash the whole batch without one actor hop per filename.
    func nameHashes(forCorrectedNames names: [String]) async throws -> [String]
    /// HMAC-SHA256 over the lowercase-hex SHA-1 string, same key. Lowercase hex.
    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String
    /// Remote occupants of the given name hashes. Callers pass at most
    /// `UploadDedupePipeline.protonDuplicateBatchSize` hashes per call.
    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate]
    /// Optional stronger lookup: an active remote photo with the same content hash, independent
    /// of filename/name hash. Backends that cannot provide a remote content index return nil.
    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate?
    /// Exact active-remote proofs for source identities stored in Proton's encrypted metadata.
    /// Missing entries are unknown, never negative proof.
    func findRemoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord]
    /// Drops backend-owned remote duplicate/content caches. Called whenever the upload resolver's
    /// remote view is known stale; the next lookup must re-read server state.
    func invalidateCachedRemoteState() async
    /// Updates backend-owned content indexes after this client commits an upload. This is a local
    /// optimization only; the upload manifest remains the authoritative durability boundary.
    func recordUploaded(contentHash: String, remoteLinkID: String) async
    /// Irreversible fingerprint of the current photos-root hash key (for manifest validity) -
    /// never the key itself.
    func hashKeyEpoch() async throws -> String
}

public extension UploadDuplicateChecking {
    func nameHashes(forCorrectedNames names: [String]) async throws -> [String] {
        var hashes: [String] = []
        hashes.reserveCapacity(names.count)
        for name in names {
            hashes.append(try await nameHash(forCorrectedName: name))
        }
        return hashes
    }
    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate? { nil }
    func findRemoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] { [:] }
    func invalidateCachedRemoteState() async {}
    func recordUploaded(contentHash: String, remoteLinkID: String) async {}
}

/// Fail-closed resolver used when the account's identity manifest cannot be opened. Uploading
/// without duplicate checks would violate the "same bytes upload once" contract, so every resolve
/// fails before any media bytes can leave the device.
public struct DedupeUnavailableIdentityResolver: UploadIdentityResolving {
    private let message: String

    public init(message: String = "Duplicate protection is unavailable; upload cannot start safely.") {
        self.message = message
    }

    public func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        throw UploadError.backend(message)
    }

    public func prime(_ descriptors: [UploadResourceDescriptor]) async {}
    public func recordUploaded(_ descriptor: UploadResourceDescriptor, identity: UploadIdentity, remoteVolumeID: String, remoteLinkID: String) async throws {}
    public func invalidateCachedRemoteState() async {}
    public func uploadDidFail(_ descriptor: UploadResourceDescriptor) async {}
}

/// The pipeline seam `UploadManager` drives: resolve one descriptor to its identity + decision.
/// ONE implementation (`UploadDedupePipeline`) serves every platform.
public protocol UploadIdentityResolving: Sendable {
    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult
    func remoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord]
    /// Batch-prefetch duplicate states for a fresh enqueue batch (Proton queries name hashes in
    /// chunks of 150). Best-effort: failures surface later through per-item `resolve`.
    func prime(_ descriptors: [UploadResourceDescriptor]) async
    /// Records that `descriptor` was uploaded as `remoteLinkID` so later runs can skip it without
    /// a remote round-trip.
    func recordUploaded(_ descriptor: UploadResourceDescriptor, identity: UploadIdentity, remoteVolumeID: String, remoteLinkID: String) async throws
    /// Drops any batch-cached remote duplicate state so the next `resolve` re-queries the server.
    /// MUST be called after a failed/cancelled upload attempt and before re-checking a
    /// draft-blocked item: the server may have committed work the cache predates (e.g. an upload
    /// whose success response was lost), and acting on the stale view would double-upload.
    func invalidateCachedRemoteState() async
    /// MUST be called when an upload attempt for a `.upload` decision ends without
    /// `recordUploaded` (error, cancel, stop). Settles the same-content coalescing claim so
    /// identical items waiting on this upload re-resolve instead of hanging, and drops the
    /// cached remote view. Exactly one of `recordUploaded`/`uploadDidFail` must follow every
    /// `.upload` decision.
    func uploadDidFail(_ descriptor: UploadResourceDescriptor) async
}

public extension UploadIdentityResolving {
    func remoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] { [:] }
    func prime(_ descriptors: [UploadResourceDescriptor]) async {}
    func invalidateCachedRemoteState() async {}
    func uploadDidFail(_ descriptor: UploadResourceDescriptor) async {}
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
