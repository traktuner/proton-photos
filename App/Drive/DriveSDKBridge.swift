import Foundation
import AVFoundation
import PhotosCore
import ProtonAuth
import ProtonDriveSDK
import UploadCore

/// Bridges the feature modules to the Proton Drive SDK. Owns the `ProtonPhotosClient`, wires in
/// our HTTP + account clients, resolves the photos root, and adapts SDK types to `PhotosCore`.
///
/// Everything SDK-specific is isolated here so feature modules stay SDK-agnostic and new SDK
/// capabilities (albums, sharing, upload) can be added without touching the UI layer.
actor DriveSDKBridge: PhotosRepository, ThumbnailProvider, ThumbnailBatchLoader, FullMediaProvider, VideoStreamProvider, PhotoMetadataProvider, BurstGroupProvider, PhotoLibraryProvider, FavoritesProvider, TrashProvider, LibraryStatsProvider {
    private let photosClient: ProtonPhotosClient
    private let driveSession: DriveSession
    private let rateLimit = RateLimitGate()
    private var photosRoot: SDKNodeUid?
    private var photosShareID: String?
    /// App-owned SQLite timeline metadata store (`library-v1.sqlite`, PhotosCore). The bridge is
    /// the macOS adapter: it chooses the path + desktop SQLite tuning and injects both; schema and
    /// save/load logic live in Core.
    private let timelineStore: TimelineMetadataStore?
    /// Drive key-derivation + block decryption for video streaming (built once at sign-in).
    private let crypto: DriveCrypto
    private var streamSource: PhotoVideoStreamSource?

    /// The SDK cache directory (`Caches/ProtonPhotos/sdk`) holding the SDK's entity SQLite store
    /// (and the encrypted account-data cache). The app-owned timeline metadata store lives in
    /// `LibraryDatabaseLocation` (Application Support) since the DB v1 reset; only its legacy
    /// `timeline-v3` predecessor is still purged from here. Single source of truth for the path.
    static var sdkCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProtonPhotos/sdk", isDirectory: true)
    }

    /// macOS desktop SQLite tuning for the app-owned library DB - adapter-injected, mirroring the
    /// `GridTextureBudget` pattern. 256MB mmap + 8MiB page cache are fine on the Mac; iOS/iPadOS
    /// adapters must build their own conservative policy instead of inheriting these numbers. The WAL
    /// cap is still bounded so large refreshes cannot leave a permanently inflated sidecar behind.
    private static let libraryDatabasePolicy = LibraryDatabasePolicy(
        mmapBytes: 268_435_456,
        cacheSizeKiB: 8_192,
        busyTimeoutMs: 3_000,
        journalSizeLimitBytes: 16 * 1024 * 1024,
        walCheckpointRowThreshold: 10_000
    )

    /// Full sign-out / master-reset: erase the SDK metadata SQLite stores for `uid` (security
    /// follow-up #2 - non-secret node metadata that must not survive sign-out) AND the app-owned
    /// `library-v1.sqlite` account directory. The encrypted caches, video blocks, and account-data
    /// cache are erased by their own paths; this covers the remaining account-tied data at rest.
    /// Wired from `AppModel.signOut`.
    static func purgeMetadata(uid: String) {
        SDKMetadataStore.purgeMetadata(in: sdkCacheDirectory, uid: uid)
        LibraryDatabaseLocation.purgeAccountData(uid: uid)
    }

    init(session: ProtonSession, store: SessionKeychainStore) async throws {
        let driveSession = DriveSession(session: session, store: store, config: .externalDriveProtonPhotos)
        self.driveSession = driveSession

        DebugLog.log("bridge: fetching account data…")
        // Build the account client (fetch + decrypt the user's keys) up front. If the network is unavailable
        // (cold OFFLINE launch), fall back to the encrypted account cache persisted on a previous online launch,
        // so the library still opens (read-only, on cached data) instead of failing the whole signed-in UI.
        let account: AccountData
        do {
            account = try await driveSession.fetchAccountData()
            DebugLog.log("bridge: account ok - \(account.addresses.count) addresses, \(account.userKeys.count) user keys")
        } catch {
            guard let cached = driveSession.cachedAccountData() else { throw error }
            account = cached
            DebugLog.log("bridge: OFFLINE - using cached account data (\(cached.addresses.count) addresses)")
        }
        let accountClient = try SDKAccountClientBuilder.build(account: account, keyPassword: session.keyPassword)
        DebugLog.log("bridge: account client built (\(accountClient.unlockedByKeyID.count) unlocked keys)")

        // Crypto for streaming: the same address keys, kept as (armored, passphrase) so we can
        // derive share/node keys and the per-file content session key on demand.
        self.crypto = DriveCrypto(account: account, keyPassword: session.keyPassword)

        let caches = Self.sdkCacheDirectory
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        // Purge any plaintext secret cache left by an older build (we now keep secrets in-memory only).
        for name in ["secrets.sqlite", "secrets.sqlite-wal", "secrets.sqlite-shm"] {
            try? FileManager.default.removeItem(at: caches.appendingPathComponent(name))
        }
        // Persisted timeline (per account) for instant startup. DB v1 reset: the store lives in
        // PhotosCore at Application Support/ProtonPhotos/<uid>/library-v1.sqlite (backup-excluded,
        // re-derivable). The superseded Caches-dir timeline-v3 store is deleted best-effort - no
        // data migration; the next refresh repopulates the new store.
        let libraryDirectory = LibraryDatabaseLocation.prepareAccountDirectory(uid: session.uid)
        self.timelineStore = TimelineMetadataStore(
            url: libraryDirectory.appendingPathComponent(LibraryDatabaseLocation.databaseFileName),
            policy: Self.libraryDatabasePolicy
        )
        // Sweep ALL superseded timeline formats (any account): the uid-scoped delete alone leaves
        // orphans behind for accounts that last signed in on older builds.
        SDKMetadataStore.purgeOrphanedLegacyTimelineStores(in: caches)

        // SECURITY: the SDK secret cache holds DECRYPTED Proton key material (share/node/content keys). The
        // SDK writes it UNENCRYPTED unless a `secretCacheEncryptionKey` is supplied - and the ProtonPhotos
        // client create-path doesn't forward that key to the native core anyway. So we keep secrets
        // IN-MEMORY only (omit `secretCachePath`): nothing decryptable is persisted at rest. Cost: the
        // secret cache is re-derived on each cold start. `entityCachePath` (non-secret node metadata) stays
        // on disk for fast startup. See OFFLINE_THUMBNAIL_SECURITY_REPORT.md.
        let config = ProtonDriveClientConfiguration(
            baseURL: "https://drive-api.proton.me/",   // trailing slash required by the C# core
            clientUID: session.uid,
            entityCachePath: caches.appendingPathComponent("entities.sqlite").path
        )

        self.photosClient = try await ProtonPhotosClient(
            configuration: config,
            httpClient: SDKHttpClient(driveSession: driveSession, rateLimit: rateLimit),
            accountClient: accountClient,
            logCallback: { _ in },
            featureFlagProviderCallback: { _, completion in completion(false) },
            recordMetricEventCallback: { _ in }
        )
        DebugLog.log("bridge: ProtonPhotosClient created ✓")
    }

    // MARK: - PhotosRepository

    func loadTimeline() async throws -> [TimelineSection] {
        do {
            let root = try await resolvePhotosRoot()
            DebugLog.log("timeline: photos root \(root.volumeID.prefix(8))…/\(root.nodeID.prefix(8))… - enumerating")
            // Loading path stays on the SDK's enumerateTimeline - it's SQLite-cached and fast. We
            // deliberately do NOT swap in the direct photos-listing endpoint here: that would do a
            // full uncached re-pagination every launch (a performance regression). The Live Photo
            // metadata (Tags/RelatedPhotos) the SDK currently drops will arrive natively once the
            // SDK reaches feature parity - PhotoItem already carries `isLivePhoto`/`relatedVideoID`,
            // so that switch is zero-effort. `DriveSession.fetchPhotosList` stays available as the
            // ready fallback for when we want to enrich without waiting for the SDK.
            let items = try await photosClient.enumerateTimeline(in: root)
            DebugLog.log("timeline: enumerated \(items.count) items ✓")
            let videoNodeIDs: Set<String>
            do {
                let videos = try await driveSession.fetchPhotosList(volumeID: root.volumeID, tag: PhotoTag.videos.rawValue)
                videoNodeIDs = Set(videos.map(\.linkID))
                DebugLog.log("timeline: video tag enrichment found \(videoNodeIDs.count) videos")
            } catch {
                videoNodeIDs = []
                DebugLog.log("timeline: video tag enrichment skipped - \(error)")
            }
            // Live Photos (server tag 3): the SDK's `enumerateTimeline` drops Tags/RelatedPhotos, so "Alle Fotos"
            // items would never be marked Live. Enrich here via the REST photos-listing (same pattern as the
            // video tag-2 enrichment above) so the LIVE badge + motion work everywhere - not just the Live-Photos
            // filter. Map each live photo's node → its paired video link.
            let livePhotoVideoIDs: [String: String]
            do {
                let lives = try await driveSession.fetchPhotosList(volumeID: root.volumeID, tag: PhotoTag.livePhotos.rawValue)
                livePhotoVideoIDs = Dictionary(lives.compactMap { e in e.relatedVideoLinkID.map { (e.linkID, $0) } },
                                               uniquingKeysWith: { first, _ in first })
                DebugLog.log("timeline: live-photo tag enrichment found \(livePhotoVideoIDs.count) live photos")
            } catch {
                livePhotoVideoIDs = [:]
                DebugLog.log("timeline: live-photo tag enrichment skipped - \(error)")
            }
            let burstMemberIDs: [String: [String]]
            do {
                let bursts = try await driveSession.fetchPhotosList(volumeID: root.volumeID, tag: PhotoTag.bursts.rawValue)
                burstMemberIDs = Self.burstMemberLookup(from: bursts)
                DebugLog.log("timeline: burst tag enrichment found \(burstMemberIDs.count) burst members")
            } catch {
                burstMemberIDs = [:]
                DebugLog.log("timeline: burst tag enrichment skipped - \(error)")
            }
            let sections = Self.group(
                items,
                videoNodeIDs: videoNodeIDs,
                livePhotoVideoIDs: livePhotoVideoIDs,
                burstMemberIDs: burstMemberIDs
            )
            writeTimelineCache(sections)
            return sections
        } catch {
            DebugLog.log("timeline: FAILED - \(error)")
            throw error
        }
    }

    /// Last-known timeline from disk, for instant startup (no spinner). Reads from SQLite - then
    /// `loadTimeline()` refreshes in the background.
    func cachedTimeline() -> [TimelineSection]? {
        guard let items = timelineStore?.load(), !items.isEmpty else { return nil }
        DebugLog.log("timeline: served \(items.count) items from SQLite cache ✓")
        return [TimelineSection(id: "all", date: items.first?.captureTime ?? .distantPast, title: "", items: items)]
    }

    private func writeTimelineCache(_ sections: [TimelineSection]) {
        guard let store = timelineStore else { return }
        let result = store.save(sections.flatMap(\.items))
        if result.skippedUnchanged {
            DebugLog.log("timeline: cache unchanged - save skipped (digest match)")
        } else {
            DebugLog.log("timeline: cache saved gen=\(result.generation) upserts=\(result.upsertedRows) swept=\(result.sweptRows) ok=\(result.succeeded)")
        }
    }

    // MARK: - LibraryStatsProvider

    /// Rows persisted in the local SQLite timeline store - surfaced as "metadata rows" in Settings.
    func metadataRowCount() async -> Int {
        timelineStore?.count() ?? 0
    }

    // MARK: - ThumbnailProvider

    func thumbnail(for uid: PhotoUID) async throws -> Data {
        try await singleThumbnail(uid, type: .thumbnail)
    }

    // MARK: - ThumbnailBatchLoader

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        let sdkUids = uids.map { SDKNodeUid(volumeID: $0.volumeID, nodeID: $0.nodeID) }
        let failures = BatchFailureBox()
        do {
            try await photosClient.downloadThumbnails(
                photoUids: sdkUids,
                type: .thumbnail,
                cancellationToken: UUID(),
                onThumbnailDownloaded: { result in
                    switch result {
                    case let .success(item?):
                        let uid = PhotoUID(volumeID: item.fileUid.volumeID, nodeID: item.fileUid.nodeID)
                        switch item.result {
                        case let .success(data):
                            onLoaded(uid, data)
                        case let .failure(error):
                            failures.recordItem(uid, reason: error.localizedDescription)
                        }
                    case .success(nil):
                        break   // yield without an attributable item (unparseable uid) - nothing to record
                    case let .failure(error):
                        failures.recordStream(error.localizedDescription)
                    }
                }
            )
        } catch {
            failures.recordStream((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        let result = failures.result
        if result != .delivered {
            let sample = result.itemErrors.first.map { "\($0.key.nodeID.prefix(8))…: \($0.value)" } ?? "-"
            DebugLog.log("[ThumbBatch] n=\(uids.count) itemErrors=\(result.itemErrors.count) (\(sample)) batchError=\(result.batchError ?? "-")")
        }
        return result
    }

    // MARK: - FullMediaProvider

    func preview(for uid: PhotoUID) async throws -> Data {
        try await singleThumbnail(uid, type: .preview)
    }

    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let source = try await fileSource()
        return try await source.originalData(uid: uid, onProgress: onProgress)
    }

    private func singleThumbnail(_ uid: PhotoUID, type: ThumbnailData.ThumbnailType) async throws -> Data {
        let sdkUid = SDKNodeUid(volumeID: uid.volumeID, nodeID: uid.nodeID)
        let box = DataBox()
        try await photosClient.downloadThumbnails(
            photoUids: [sdkUid],
            type: type,
            cancellationToken: UUID(),
            onThumbnailDownloaded: { result in
                if case let .success(item?) = result, case let .success(data) = item.result {
                    box.set(data)
                }
            }
        )
        guard let data = box.value else { throw CocoaError(.fileReadUnknown) }
        return data
    }

    // MARK: - Photos root resolution

    private func resolvePhotosRoot() async throws -> SDKNodeUid {
        if let photosRoot { return photosRoot }
        let response = try await driveSession.getJSON("/drive/shares?ShareType=4", as: SharesListResponse.self)
        guard let share = response.shares.first(where: { $0.state == 1 && $0.locked != true }) else {
            throw DriveBridgeError.noPhotosShare
        }
        let root = SDKNodeUid(volumeID: share.volumeID, nodeID: share.linkID)
        photosRoot = root
        photosShareID = share.shareID
        return root
    }

    /// Lazily builds (and caches) the streaming/metadata source once the photos share id is known.
    private func fileSource() async throws -> PhotoVideoStreamSource {
        _ = try await resolvePhotosRoot()   // ensures photosShareID is populated
        guard let shareID = photosShareID else { throw DriveBridgeError.noPhotosShare }
        if let streamSource { return streamSource }
        let source = PhotoVideoStreamSource(session: driveSession, crypto: crypto, shareID: shareID)
        streamSource = source
        return source
    }

    // MARK: - PhotoLibraryProvider

    func albums() async throws -> [PhotoAlbum] {
        let root = try await resolvePhotosRoot()
        let source = try await fileSource()
        let raw = try await driveSession.fetchAlbums(volumeID: root.volumeID)
        var result: [PhotoAlbum] = []
        for a in raw {
            let title = (try? await source.nodeName(linkID: a.linkID)) ?? "Album"
            result.append(PhotoAlbum(id: a.linkID, title: title ?? "Album",
                                     photoCount: a.photoCount ?? 0, coverLinkID: a.coverLinkID))
        }
        return result
    }

    /// Sets an album's cover to an already-uploaded photo (direct REST; the SDK has no album API). The photo's
    /// `nodeID` is its Drive link id.
    func setAlbumCover(albumID: String, photoUID: PhotoUID) async throws {
        let root = try await resolvePhotosRoot()
        try await driveSession.setAlbumCover(volumeID: root.volumeID, albumLinkID: albumID, coverLinkID: photoUID.nodeID)
    }

    func timeline(filter: PhotoFilter) async throws -> [TimelineSection] {
        switch filter {
        case .all:
            return try await loadTimeline()
        case .tag(let tag):
            let root = try await resolvePhotosRoot()
            let entries = try await driveSession.fetchPhotosList(volumeID: root.volumeID, tag: tag.rawValue)
            return Self.group(entries, volumeID: root.volumeID)
        case .album(let id, _):
            let root = try await resolvePhotosRoot()
            let entries = try await driveSession.fetchAlbumPhotos(volumeID: root.volumeID, albumLinkID: id)
            return Self.group(entries, volumeID: root.volumeID)
        case .trash:
            let root = try await resolvePhotosRoot()
            let links = try await driveSession.listTrash(volumeID: root.volumeID).filter { $0.type != 1 }   // drop folders; keep files/unknown
            let photos = links
                .compactMap { l -> PhotoItem? in
                    guard let id = l.linkID else { return nil }
                    let isVideo = l.mimeType?.hasPrefix("video/") == true
                    return PhotoItem(uid: PhotoUID(volumeID: root.volumeID, nodeID: id),
                                     captureTime: Date(timeIntervalSince1970: l.captureTime),
                                     mediaType: isVideo ? "video/quicktime" : "image/jpeg",
                                     tags: isVideo ? [.videos] : [])
                }
                .sorted(by: TimelineOrder.areInIncreasingOrder)
            return [TimelineSection(id: "trash", date: photos.first?.captureTime ?? .distantPast, title: "", items: photos)]
        case .map:
            return []   // the Map route renders the map, not a timeline
        }
    }

    // MARK: - FavoritesProvider

    func favoriteUIDs() async throws -> Set<PhotoUID> {
        let root = try await resolvePhotosRoot()
        let entries = try await driveSession.fetchPhotosList(volumeID: root.volumeID, tag: PhotoTag.favorites.rawValue)
        return Set(entries.map { PhotoUID(volumeID: root.volumeID, nodeID: $0.linkID) })
    }

    func setFavorite(_ uid: PhotoUID, _ favorite: Bool) async throws {
        let root = try await resolvePhotosRoot()
        try await driveSession.setFavorite(volumeID: root.volumeID, linkID: uid.nodeID, favorite)
    }

    // MARK: - TrashProvider

    func trash(_ uids: [PhotoUID]) async throws {
        let root = try await resolvePhotosRoot()
        try await driveSession.trash(volumeID: root.volumeID, linkIDs: uids.map(\.nodeID))
    }

    func restore(_ uids: [PhotoUID]) async throws {
        let root = try await resolvePhotosRoot()
        try await driveSession.restore(volumeID: root.volumeID, linkIDs: uids.map(\.nodeID))
    }

    /// Builds timeline sections from direct-listing entries (tag filters + album contents).
    private static func group(_ entries: [PhotosListEntry], volumeID: String) -> [TimelineSection] {
        let burstMemberIDs = burstMemberLookup(from: entries)
        let photos = entries
            .map { e -> PhotoItem in
                photoItem(from: e, volumeID: volumeID, burstMemberIDs: burstMemberIDs[e.linkID] ?? [])
            }
            .sorted(by: TimelineOrder.areInIncreasingOrder)
        return [TimelineSection(id: "filtered", date: photos.first?.captureTime ?? .distantPast, title: "", items: photos)]
    }

    // MARK: - PhotoMetadataProvider

    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata {
        let source = try await fileSource()
        let raw = try await source.fileMetadata(linkID: uid.nodeID)
        let xa = raw.xattr
        var mod: Date?
        if let s = xa?.common?.modificationTime {
            mod = ISO8601DateFormatter().date(from: s)
        }
        return PhotoMetadata(
            filename: raw.filename,
            mimeType: raw.mimeType,
            fileSize: raw.size ?? xa?.common?.size,
            pixelWidth: xa?.media?.width,
            pixelHeight: xa?.media?.height,
            device: xa?.camera?.device,
            durationSeconds: xa?.media?.duration,
            modificationTime: mod,
            latitude: xa?.location?.latitude,
            longitude: xa?.location?.longitude
        )
    }

    // MARK: - BurstGroupProvider

    func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] {
        let root = try await resolvePhotosRoot()
        let burstEntries = try await driveSession.fetchPhotosList(volumeID: root.volumeID, tag: PhotoTag.bursts.rawValue)
        let lookup = Self.burstMemberLookup(from: burstEntries)
        guard let memberIDs = lookup[uid.nodeID], memberIDs.count > 1 else { return [] }

        let entriesByID = Dictionary(burstEntries.map { ($0.linkID, $0) }, uniquingKeysWith: { first, _ in first })
        let anchorEntry = entriesByID[uid.nodeID] ?? burstEntries.first { entry in
            memberIDs.contains(entry.linkID)
        }
        let anchorTime = anchorEntry.map { Date(timeIntervalSince1970: $0.captureTime) } ?? .distantPast

        return memberIDs.enumerated().map { offset, id in
            if let entry = entriesByID[id] {
                return Self.photoItem(from: entry, volumeID: root.volumeID, burstMemberIDs: memberIDs)
            }
            return Self.syntheticBurstMember(
                id: id,
                volumeID: root.volumeID,
                memberIDs: memberIDs,
                anchorTime: anchorTime,
                offset: offset
            )
        }
    }

    // MARK: - VideoStreamProvider

    func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset {
        let source = try await fileSource()

        // Throws `.notAVideo` cheaply for images, so the viewer falls back to its image path.
        let prepared = try await source.prepare(uid: uid)
        let loader = ProtonVideoResourceLoader(prepared: prepared, source: source, crypto: crypto)
        // Unique per-item URL so AVFoundation never reuses a cached asset/loader across videos.
        let host = uid.nodeID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "stream"
        let asset = AVURLAsset(url: URL(string: "protonvideo://\(host)")!)
        let queue = DispatchQueue(label: "me.proton.photos.video-loader")
        asset.resourceLoader.setDelegate(loader, queue: queue)
        return StreamingVideoAsset(asset: asset, retaining: loader)
    }

    func prefetchEncrypted(for uid: PhotoUID) async throws {
        let source = try await fileSource()
        try await source.prefetchEncrypted(uid: uid)
    }

    // MARK: - Mapping

    private static func group(_ items: [PhotoTimelineItem], videoNodeIDs: Set<String> = [],
                              livePhotoVideoIDs: [String: String] = [:],
                              burstMemberIDs: [String: [String]] = [:]) -> [TimelineSection] {
        let photos = items
            .map { item -> PhotoItem in
                let nodeID = item.nodeUid.nodeID
                let isVideo = videoNodeIDs.contains(nodeID)
                let relatedVideo = livePhotoVideoIDs[nodeID]   // a live photo's paired video link, if any
                let burstMembers = burstMemberIDs[nodeID] ?? []
                var tags: Set<PhotoTag> = []
                if isVideo { tags.insert(.videos) }
                if relatedVideo != nil { tags.insert(.motionPhotos) }
                if burstMembers.count > 1 { tags.insert(.bursts) }
                return PhotoItem(uid: PhotoUID(volumeID: item.nodeUid.volumeID, nodeID: nodeID),
                                 captureTime: Date(timeIntervalSince1970: item.captureTime),
                                 mediaType: isVideo ? "video/quicktime" : "image/jpeg",
                                 isLivePhoto: relatedVideo != nil,
                                 relatedVideoID: relatedVideo,
                                 tags: tags,
                                 burstMemberIDs: burstMembers) }
            // Ascending (oldest first): oldest at the top, newest at the BOTTOM - like Apple Photos.
            // The grid opens scrolled to the bottom so the newest photos are shown first. The
            // comparator is the canonical (t, vol, node) timeline order, matching the DB index, so
            // equal-second captures keep a stable position across refreshes and relaunches.
            .sorted(by: TimelineOrder.areInIncreasingOrder)

        // ONE continuous section - no per-day/month breaks. Apple's "All Photos" is a single
        // uninterrupted justified run, which also keeps pinch-zoom smooth (no divider lines to
        // disturb the re-justify) and makes thumbnail sizing consistent across the whole library.
        return [TimelineSection(id: "all", date: photos.first?.captureTime ?? .distantPast, title: "", items: photos)]
    }

    private static func tags(from rawValues: [Int]) -> Set<PhotoTag> {
        Set(rawValues.compactMap(PhotoTag.init(rawValue:)))
    }

    private static func photoItem(from entry: PhotosListEntry, volumeID: String, burstMemberIDs: [String] = []) -> PhotoItem {
        let isVideo = entry.tags.contains(PhotoTag.videos.rawValue)
        var tags = Self.tags(from: entry.tags)
        if burstMemberIDs.count > 1 { tags.insert(.bursts) }
        return PhotoItem(
            uid: PhotoUID(volumeID: volumeID, nodeID: entry.linkID),
            captureTime: Date(timeIntervalSince1970: entry.captureTime),
            mediaType: isVideo ? "video/quicktime" : "image/jpeg",
            isLivePhoto: entry.isLivePhoto,
            relatedVideoID: entry.isLivePhoto ? entry.relatedVideoLinkID : nil,
            tags: tags,
            burstMemberIDs: burstMemberIDs
        )
    }

    private static func syntheticBurstMember(
        id: String,
        volumeID: String,
        memberIDs: [String],
        anchorTime: Date,
        offset: Int
    ) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: volumeID, nodeID: id),
            captureTime: anchorTime.addingTimeInterval(Double(offset) * 0.001),
            mediaType: "image/jpeg",
            tags: [.bursts],
            burstMemberIDs: memberIDs
        )
    }

    private static func burstMemberLookup(from entries: [PhotosListEntry]) -> [String: [String]] {
        let candidates = entries
            .filter { $0.tags.contains(PhotoTag.bursts.rawValue) }
            .map {
                BurstGroupCandidate(
                    id: $0.linkID,
                    relatedIDs: $0.relatedPhotos.map(\.linkID),
                    captureTime: Date(timeIntervalSince1970: $0.captureTime)
                )
            }
        return BurstGroupResolver.memberLookup(candidates: candidates)
    }
}

// MARK: - PhotoDimensionRecording (learned w/h into the library metadata DB)

extension DriveSDKBridge: PhotoDimensionRecording {
    /// Batched by `PhotoDimensionCoalescer`; the store fills only rows without dimensions
    /// (first-seen-wins), so repeated decodes and future true-dimension writers can coexist.
    func recordDimensions(_ batch: [PhotoUID: PhotoPixelDimensions]) async {
        timelineStore?.updateDimensions(batch)
    }
}

// MARK: - PhotoUploading (UploadFeature seam)

/// Library upload via the SDK's `ProtonPhotosClient`. The SDK resolves the photos root itself, encrypts
/// + streams blocks (through `SDKHttpClient.requestUploadToStorage`), and returns the new node id. The
/// queue/state-machine lives in the pure `UploadManager`; this is just the transport.
extension DriveSDKBridge: PhotoUploading {
    nonisolated var capabilities: UploadBackendCapabilities {
        // The SDK exposes operation-level pause/resume, but we drive uploads through the `uploadPhoto`
        // convenience (no held operation), so in-flight pause isn't wired: queued items pause at the
        // queue level; cancelled/failed items retry from the start (honestly, not byte-resumed).
        .sdkUploader
    }

    func upload(
        _ request: PhotoUploadRequest,
        onProgress: @Sendable @escaping (UploadProgress) -> Void
    ) async throws -> PhotoUID {
        onProgress(UploadProgress(phase: .preparing))
        let isVideo = request.mediaType.hasPrefix("video/")
        let thumbnails = UploadMediaProcessor.thumbnails(for: request.fileURL, isVideo: isVideo)
        onProgress(UploadProgress(phase: .uploading, fraction: 0))
        do {
            let ids = try await photosClient.uploadPhoto(
                name: request.name,
                fileURL: request.fileURL,
                fileSize: request.fileSize,
                modificationDate: request.modificationDate,
                captureTime: request.captureTime,
                mainPhotoUid: nil,
                mediaType: request.mediaType,
                thumbnails: thumbnails,
                tags: [],                       // let the server classify; avoids tag-mapping upload failures
                additionalMetadata: [],
                expectedSHA1: nil,
                cancellationToken: request.cancellationToken,
                progressCallback: { p in
                    onProgress(UploadProgress(phase: .uploading, fraction: p.fractionCompleted))
                },
                onRetriableErrorReceived: { _ in }
            )
            DebugLog.log("[Upload] completed node=\(ids.nodeUid.nodeID.prefix(8))… file=\(request.name)")
            return PhotoUID(volumeID: ids.nodeUid.volumeID, nodeID: ids.nodeUid.nodeID)
        } catch {
            DebugLog.log("[Upload] FAILED file=\(request.name) err=\(error)")
            throw UploadError.backend((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func cancel(token: UUID) async {
        try? await photosClient.cancelUpload(with: token)
    }
}

enum DriveBridgeError: LocalizedError {
    case noPhotosShare
    var errorDescription: String? {
        switch self {
        case .noPhotosShare: String(localized: "error.no_photos_library")
        }
    }
}

/// Thread-safe one-shot data holder for the SDK thumbnail callback.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    func set(_ data: Data) { lock.withLock { _data = data } }
    var value: Data? { lock.withLock { _data } }
}

/// Thread-safe collector for per-item and stream-level failures of one thumbnail batch.
private final class BatchFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var itemErrors: [PhotoUID: String] = [:]
    private var streamError: String?

    func recordItem(_ uid: PhotoUID, reason: String) {
        lock.withLock { itemErrors[uid] = reason }
    }

    func recordStream(_ reason: String) {
        lock.withLock { if streamError == nil { streamError = reason } }
    }

    var result: ThumbnailBatchLoadResult {
        lock.withLock { ThumbnailBatchLoadResult(batchError: streamError, itemErrors: itemErrors) }
    }
}

private struct SharesListResponse: Decodable {
    let shares: [ShareItem]
    enum CodingKeys: String, CodingKey { case shares = "Shares" }

    struct ShareItem: Decodable {
        let shareID: String
        let volumeID: String
        let linkID: String
        let state: Int
        let locked: Bool?
        enum CodingKeys: String, CodingKey {
            case shareID = "ShareID"; case volumeID = "VolumeID"
            case linkID = "LinkID"; case state = "State"; case locked = "Locked"
        }
    }
}
