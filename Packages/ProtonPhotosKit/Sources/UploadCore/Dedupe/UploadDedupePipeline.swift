import Foundation

/// The one universal pre-upload pipeline: manifest-cached hashing → Proton name/content identity →
/// batched remote duplicate lookup → `UploadDuplicateDecisionPolicy`. `UploadManager` drives it for
/// every platform; platform adapters only supply `UploadResourceDescriptor`s.
///
/// Local performance beyond Proton (all remote-invisible):
/// - unchanged files (same name/size/mtime) reuse their persisted SHA-1 and HMACs,
/// - resources the manifest knows as uploaded / active duplicates skip the remote query entirely
///   (Proton keeps an equivalent local skip cache in UserDefaults),
/// - duplicate queries are cached per enqueue batch, coalesced across concurrent items, and
///   batched at Proton's 150-hash request size via `prime`.
public actor UploadDedupePipeline: UploadIdentityResolving {

    /// Proton Drive iOS 1.61.0 queries the duplicates endpoint in groups of 150 name hashes.
    public static let protonDuplicateBatchSize = 150

    private let store: any UploadIdentityStore
    private let hasher: any UploadHashing
    private let checker: any UploadDuplicateChecking
    private let batchSize: Int
    private let now: @Sendable () -> Date

    /// Per-batch remote view: name hash → the remote items carrying it ([] = server says free).
    private var duplicateCache: [String: [RemotePhotoDuplicate]] = [:]
    /// In-flight lookups, one entry per name hash, so concurrent items never double-query.
    private var inFlight: [String: Task<[String: [RemotePhotoDuplicate]], any Error>] = [:]
    /// Bumped by `invalidateCachedRemoteState` so lookups that were already in flight when the
    /// view was invalidated cannot repopulate the cache with pre-invalidation data.
    private var cacheGeneration = 0

    public init(
        store: any UploadIdentityStore,
        hasher: any UploadHashing = UploadFileHasher(),
        checker: any UploadDuplicateChecking,
        batchSize: Int = UploadDedupePipeline.protonDuplicateBatchSize,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.hasher = hasher
        self.checker = checker
        self.batchSize = max(1, batchSize)
        self.now = now
    }

    // MARK: - UploadIdentityResolving

    public func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        let corrected = ProtonPhotoNameCorrection.correctedName(for: descriptor.filename)
        let epoch = try await checker.hashKeyEpoch()
        let cached = store.record(for: descriptor.source)
        let hmacReusable = cached.map { $0.isValid(for: descriptor, hashKeyEpoch: epoch) && $0.correctedName == corrected } ?? false

        // Manifest fast path: this exact resource (same name/size/mtime/key epoch) is known to be
        // on the server - uploaded by us or confirmed as an active duplicate. No hash, no query.
        if let cached, hmacReusable,
           let outcome = cached.outcome.flatMap(UploadIdentityManifestStore.Outcome.init(rawValue:)),
           outcome == .uploaded || outcome == .duplicateActive,
           let remoteLink = cached.remoteLinkID,
           let digest = UploadContentSHA1.digest(fromHex: cached.sha1Hex) {
            let identity = UploadIdentity(
                correctedName: cached.correctedName, nameHash: cached.nameHash,
                sha1Hex: cached.sha1Hex, sha1Digest: digest, contentHash: cached.contentHash
            )
            return UploadPreflightResult(identity: identity, decision: .skip(.knownFromManifest, remoteLinkID: remoteLink))
        }

        // Content identity - reuse the persisted SHA-1 only while name/size/mtime are unchanged;
        // when unsure, rehash (streamed, cancellable).
        let sha1Digest: Data
        if let cached, cached.isValid(for: descriptor),
           let digest = UploadContentSHA1.digest(fromHex: cached.sha1Hex) {
            sha1Digest = digest
        } else {
            sha1Digest = try await hasher.sha1(of: descriptor)
        }
        let sha1Hex = UploadContentSHA1.hexString(digest: sha1Digest)

        // Proton-keyed hashes - reused only when the key epoch also matches.
        let nameHash: String
        let contentHash: String
        if let cached, hmacReusable, cached.sha1Hex == sha1Hex {
            nameHash = cached.nameHash
            contentHash = cached.contentHash
        } else {
            nameHash = try await checker.nameHash(forCorrectedName: corrected)
            contentHash = try await checker.contentHash(forSHA1Hex: sha1Hex)
        }
        let identity = UploadIdentity(
            correctedName: corrected, nameHash: nameHash,
            sha1Hex: sha1Hex, sha1Digest: sha1Digest, contentHash: contentHash
        )

        // Persist the identity before the remote check so a crash never re-pays the hashing.
        // An outcome from a still-valid prior row survives; anything stale is dropped.
        var record = UploadIdentityRecord(
            source: descriptor.source,
            filename: descriptor.filename,
            correctedName: corrected,
            fileSize: descriptor.fileSize,
            modificationDate: descriptor.modificationDate,
            sha1Hex: sha1Hex,
            nameHash: nameHash,
            contentHash: contentHash,
            hashKeyEpoch: epoch,
            remoteVolumeID: hmacReusable ? cached?.remoteVolumeID : nil,
            remoteLinkID: hmacReusable ? cached?.remoteLinkID : nil,
            outcome: hmacReusable ? cached?.outcome : nil,
            updatedAt: now()
        )
        store.upsert(record)

        let remoteItems = try await duplicates(forNameHash: nameHash)
        try Task.checkCancellation()

        let decision = UploadDuplicateDecisionPolicy.decide(
            primary: .init(source: descriptor.source, nameHash: nameHash, contentHash: contentHash),
            remoteItems: remoteItems
        )

        // Durable outcomes: active duplicates are remembered (Proton keeps an equivalent local
        // skip cache); trashed is recorded for observability but NOT trusted by the fast path -
        // the user can restore or purge the trash, so it re-checks every run. Draft/deleted are
        // transient and never persisted.
        switch decision {
        case let .skip(.activeDuplicate, remoteLinkID):
            record.outcome = UploadIdentityManifestStore.Outcome.duplicateActive.rawValue
            record.remoteLinkID = remoteLinkID
            record.updatedAt = now()
            store.upsert(record)
        case .skip(.trashedDuplicate, _):
            record.outcome = UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue
            record.updatedAt = now()
            store.upsert(record)
        default:
            break
        }
        return UploadPreflightResult(identity: identity, decision: decision)
    }

    /// Drops the cached remote view (and detaches in-flight lookups) so the next `resolve`
    /// re-queries the server. Called after failed/cancelled upload attempts and before
    /// draft-blocked re-checks - the moments where the server may know more than the cache.
    public func invalidateCachedRemoteState() async {
        cacheGeneration += 1
        duplicateCache.removeAll()
        // Don't cancel running lookups (their callers still get server truth as of their start),
        // but stop new callers from joining them and stop their results from repopulating the
        // invalidated cache (guarded by `cacheGeneration` in `lookup`).
        inFlight.removeAll()
    }

    /// Batch-prefetch for a fresh enqueue: computes name hashes (no content hashing) and queries
    /// the duplicates endpoint in Proton-sized chunks, so per-item `resolve` calls become cache
    /// hits. Clears the previous batch's remote view first - every enqueue sees fresh state.
    public func prime(_ descriptors: [UploadResourceDescriptor]) async {
        await invalidateCachedRemoteState()
        guard let epoch = try? await checker.hashKeyEpoch() else { return }

        var pending: [String] = []
        var pendingSet: Set<String> = []
        for descriptor in descriptors {
            let corrected = ProtonPhotoNameCorrection.correctedName(for: descriptor.filename)
            let cached = store.record(for: descriptor.source)
            let hmacReusable = cached.map { $0.isValid(for: descriptor, hashKeyEpoch: epoch) && $0.correctedName == corrected } ?? false

            let nameHash: String
            if let cached, hmacReusable {
                // Fast-path rows won't query at resolve time either - skip them here too.
                if let outcome = cached.outcome.flatMap(UploadIdentityManifestStore.Outcome.init(rawValue:)),
                   outcome == .uploaded || outcome == .duplicateActive, cached.remoteLinkID != nil {
                    continue
                }
                nameHash = cached.nameHash
            } else {
                guard let hash = try? await checker.nameHash(forCorrectedName: corrected) else { continue }
                nameHash = hash
            }
            if duplicateCache[nameHash] == nil, inFlight[nameHash] == nil, pendingSet.insert(nameHash).inserted {
                pending.append(nameHash)
            }
        }

        var start = 0
        while start < pending.count {
            let chunk = Array(pending[start ..< min(start + batchSize, pending.count)])
            _ = try? await lookup(batch: chunk)
            start += batchSize
        }
    }

    public func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async {
        guard let epoch = try? await checker.hashKeyEpoch() else { return }
        store.upsert(UploadIdentityRecord(
            source: descriptor.source,
            filename: descriptor.filename,
            correctedName: identity.correctedName,
            fileSize: descriptor.fileSize,
            modificationDate: descriptor.modificationDate,
            sha1Hex: identity.sha1Hex,
            nameHash: identity.nameHash,
            contentHash: identity.contentHash,
            hashKeyEpoch: epoch,
            remoteVolumeID: remoteVolumeID,
            remoteLinkID: remoteLinkID,
            outcome: UploadIdentityManifestStore.Outcome.uploaded.rawValue,
            updatedAt: now()
        ))
    }

    // MARK: - Duplicate lookup (cached / coalesced / batched)

    private func duplicates(forNameHash nameHash: String) async throws -> [RemotePhotoDuplicate] {
        if let hit = duplicateCache[nameHash] { return hit }
        if let running = inFlight[nameHash] {
            return try await running.value[nameHash] ?? []
        }
        return try await lookup(batch: [nameHash])[nameHash] ?? []
    }

    private func lookup(batch nameHashes: [String]) async throws -> [String: [RemotePhotoDuplicate]] {
        let checker = self.checker
        let generation = cacheGeneration
        let task = Task { () -> [String: [RemotePhotoDuplicate]] in
            let items = try await checker.findDuplicates(nameHashes: nameHashes)
            // Every requested hash gets an entry - [] distinguishes "server says free" from
            // "never asked" in the cache.
            var grouped = Dictionary(uniqueKeysWithValues: nameHashes.map { ($0, [RemotePhotoDuplicate]()) })
            for item in items { grouped[item.nameHash, default: []].append(item) }
            return grouped
        }
        for hash in nameHashes { inFlight[hash] = task }
        defer {
            for hash in nameHashes where inFlight[hash] == task { inFlight[hash] = nil }
        }
        let grouped = try await task.value
        // A view invalidated while this lookup ran must stay invalidated - the result predates it.
        if generation == cacheGeneration {
            for (hash, items) in grouped { duplicateCache[hash] = items }
        }
        return grouped
    }
}
