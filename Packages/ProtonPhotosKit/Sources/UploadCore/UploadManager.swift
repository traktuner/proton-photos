import Foundation
import PhotosCore

/// App-facing upload queue. UI binds to this; it never touches the SDK/HTTP layer directly.
public protocol UploadManaging: Sendable {
    @discardableResult
    func enqueueFiles(_ urls: [URL], destination: UploadDestination) async -> [UploadQueueItemID]
    @discardableResult
    func enqueueFolder(_ url: URL, destination: UploadDestination) async -> [UploadQueueItemID]
    func pause(_ id: UploadQueueItemID) async
    func resume(_ id: UploadQueueItemID) async
    func cancel(_ id: UploadQueueItemID) async
    func retry(_ id: UploadQueueItemID) async
    func snapshot() async -> [UploadItem]
}

/// Bounded-concurrency upload queue with a strict per-item state machine, album orchestration, and
/// partial-success handling. Pure of any SDK/HTTP concern - all transport goes through the injected
/// `PhotoUploading` (and optional `AlbumAttaching`) seams, which keeps the whole thing unit-testable.
public actor UploadManager: UploadManaging {

    // MARK: Injected backends + config

    private let uploader: any PhotoUploading
    private let albums: (any AlbumAttaching)?
    /// The universal dedupe pipeline. Optional so the queue also works for backends without a
    /// duplicate service (and for focused queue tests); when nil, every item uploads as before.
    private let identityResolver: (any UploadIdentityResolving)?
    private let maxConcurrent: Int
    private let now: @Sendable () -> Date

    // MARK: State

    private struct Job {
        var item: UploadItem
        let destination: UploadDestination
        let cancellationToken: UUID
        var resolvedAlbumID: String?
        var task: Task<Void, Never>?
    }

    private var jobs: [UploadQueueItemID: Job] = [:]
    private var order: [UploadQueueItemID] = []      // enqueue order - the stable display order
    private var activeIDs: Set<UploadQueueItemID> = []
    private var globalPaused = false
    private var nextOrdinal = 0

    /// Observability hook for the UI/coordinator (invoked on every state change with a fresh snapshot).
    private var onChange: (@Sendable ([UploadItem], UploadQueueStats) -> Void)?
    /// Completion hook for refresh integration. Fired once per successful library-node creation.
    private var onCompleted: (@Sendable (UploadCompletedEvent) -> Void)?

    public init(
        uploader: any PhotoUploading,
        albums: (any AlbumAttaching)? = nil,
        identityResolver: (any UploadIdentityResolving)? = nil,
        maxConcurrent: Int = 3,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.uploader = uploader
        self.albums = albums
        self.identityResolver = identityResolver
        self.maxConcurrent = max(1, maxConcurrent)
        self.now = now
    }

    public func setOnChange(_ handler: @Sendable @escaping ([UploadItem], UploadQueueStats) -> Void) {
        onChange = handler
        notify()
    }

    public func setOnCompleted(_ handler: @Sendable @escaping (UploadCompletedEvent) -> Void) {
        onCompleted = handler
    }

    public nonisolated var capabilities: UploadBackendCapabilities { uploader.capabilities }

    // MARK: - Enqueue

    @discardableResult
    public func enqueueFiles(_ urls: [URL], destination: UploadDestination) async -> [UploadQueueItemID] {
        let resolvedAlbumID: String?
        do {
            resolvedAlbumID = try await resolveAlbumIfNeeded(destination)
        } catch {
            // Destination can't be honoured (e.g. album creation unsupported). Surface every chosen
            // file as failed so nothing uploads to the library behind the user's back.
            let ids = urls.map { addItem(url: $0, destination: destination, cancellationToken: UUID(),
                                          resolvedAlbumID: nil, failure: message(error)) }
            notify()
            return ids
        }

        var ids: [UploadQueueItemID] = []
        for url in urls {
            if SupportedMedia.isSupported(url) {
                ids.append(addItem(url: url, destination: destination, cancellationToken: UUID(),
                                   resolvedAlbumID: resolvedAlbumID, failure: nil))
            } else {
                ids.append(addItem(url: url, destination: destination, cancellationToken: UUID(),
                                   resolvedAlbumID: nil,
                                   failure: UploadError.unsupportedFile(url.lastPathComponent).errorDescription!))
            }
        }
        notify()    // broadcast the freshly-queued items before the scheduler advances them
        pump()
        primeDedupe(for: ids)
        return ids
    }

    /// Kick the pipeline's batched duplicate prefetch for a fresh enqueue (Proton-sized chunks of
    /// name hashes), so per-item resolution becomes a cache hit. Fire-and-forget: failures simply
    /// mean per-item lookups later.
    private func primeDedupe(for ids: [UploadQueueItemID]) {
        guard let identityResolver else { return }
        let urls = ids.compactMap { jobs[$0] }
            .filter { !$0.item.state.isTerminal }
            .map(\.item.fileURL)
        guard !urls.isEmpty else { return }
        let fallbackDate = now()
        Task.detached(priority: .utility) {
            let descriptors = urls.map { Self.descriptor(forFile: $0, fallbackDate: fallbackDate) }
            await identityResolver.prime(descriptors)
        }
    }

    private static func descriptor(forFile url: URL, fallbackDate: Date) -> UploadResourceDescriptor {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return UploadResourceDescriptor(
            source: .file(url),
            fileURL: url,
            filename: url.lastPathComponent,
            fileSize: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
            modificationDate: (attrs?[.modificationDate] as? Date) ?? fallbackDate
        )
    }

    @discardableResult
    public func enqueueFolder(_ url: URL, destination: UploadDestination) async -> [UploadQueueItemID] {
        let result = FolderEnumerator.enumerate(url)
        return await enqueueFiles(result.mediaFiles, destination: destination)
    }

    private func resolveAlbumIfNeeded(_ destination: UploadDestination) async throws -> String? {
        guard destination.usesAlbum else { return nil }
        guard let albums else {
            throw UploadError.albumStep("no album backend is wired")
        }
        return try await albums.resolveAlbum(for: destination.target)
    }

    private func addItem(
        url: URL,
        destination: UploadDestination,
        cancellationToken: UUID,
        resolvedAlbumID: String?,
        failure: String?
    ) -> UploadQueueItemID {
        let id = UUID()
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let item = UploadItem(
            id: id,
            ordinal: nextOrdinal,
            fileURL: url,
            displayName: url.lastPathComponent,
            mediaType: SupportedMedia.mimeType(for: url) ?? "application/octet-stream",
            byteCount: size,
            state: failure.map { .failed(message: $0) } ?? .queued
        )
        nextOrdinal += 1
        jobs[id] = Job(item: item, destination: destination, cancellationToken: cancellationToken,
                       resolvedAlbumID: resolvedAlbumID, task: nil)
        order.append(id)
        return id
    }

    // MARK: - Scheduler

    private func pump() {
        guard !globalPaused else { notify(); return }
        while activeIDs.count < maxConcurrent, let id = nextQueuedID() {
            start(id)
        }
        notify()
    }

    private func nextQueuedID() -> UploadQueueItemID? {
        order.first { jobs[$0]?.item.state == .queued && !activeIDs.contains($0) }
    }

    private func start(_ id: UploadQueueItemID) {
        guard var job = jobs[id] else { return }
        activeIDs.insert(id)
        job.item.state = .preparing
        let request = makeRequest(for: job)
        job.task = Task { [weak self] in await self?.run(id, request: request) }
        jobs[id] = job
    }

    private func makeRequest(for job: Job) -> PhotoUploadRequest {
        let url = job.item.fileURL
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attrs?[.modificationDate] as? Date) ?? now()
        let created = (attrs?[.creationDate] as? Date) ?? modified
        return PhotoUploadRequest(
            queueItemID: job.item.id,
            cancellationToken: job.cancellationToken,
            fileURL: url,
            name: job.item.displayName,
            mediaType: job.item.mediaType,
            fileSize: job.item.byteCount,
            captureTime: created,
            modificationDate: modified,
            tags: []
        )
    }

    // MARK: - Per-item run

    private func run(_ id: UploadQueueItemID, request: PhotoUploadRequest) async {
        do {
            var effectiveRequest = request
            var preflight: UploadPreflightResult?
            // The descriptor mirrors the request snapshot (same name/size/mtime), so manifest rows
            // written here validate against the exact attributes that were uploaded.
            let descriptor = UploadResourceDescriptor(
                source: .file(request.fileURL),
                fileURL: request.fileURL,
                filename: request.name,
                fileSize: request.fileSize,
                modificationDate: request.modificationDate
            )

            // Universal dedupe: hash + duplicate check BEFORE any bytes are uploaded. `.hashing`
            // covers both (the duplicate lookup rides the same phase). Cancellation lands here
            // via the task's cancellation - the streaming hash checks between chunks.
            if let identityResolver {
                transition(id, to: .hashing)
                let result = try await identityResolver.resolve(descriptor)
                if currentState(id) == .cancelled { finish(id); return }
                switch result.decision {
                case .upload:
                    preflight = result
                    effectiveRequest = request.applying(identity: result.identity)
                case .uploadMissingSecondaries:
                    // Manual uploads are single-resource compounds. If the policy reports missing
                    // secondaries, the primary is already represented remotely and there is no
                    // primary upload work for this queue item.
                    transition(id, to: .skipped(.primaryAlreadyPresent))
                    finish(id)
                    return
                case let .skip(reason, _):
                    guard let skipReason = UploadSkipReason(duplicateReason: reason) else {
                        throw UploadError.backend(reason.blockingMessage)
                    }
                    transition(id, to: .skipped(skipReason))
                    finish(id)
                    return
                }
            }

            let uid = try await uploader.upload(effectiveRequest) { [weak self] progress in
                Task { await self?.applyProgress(id, progress) }
            }
            // Library upload finished. If cancelled meanwhile, honour the cancel.
            if currentState(id) == .cancelled { finish(id); return }
            if let identityResolver, let preflight {
                // Remember the upload so future runs skip this exact file without a remote query.
                await identityResolver.recordUploaded(
                    descriptor, identity: preflight.identity,
                    remoteVolumeID: uid.volumeID, remoteLinkID: uid.nodeID
                )
            }
            setUploadedUID(id, uid)
            emitCompletedUpload(id)

            if let albumID = jobs[id]?.resolvedAlbumID {
                transition(id, to: .finalizing)
                do {
                    try await attachToAlbum(uid, albumID: albumID, cover: jobs[id]?.destination.cover)
                } catch {
                    // Uploaded successfully but album step failed → PARTIAL success, photo is safe.
                    markPartialFailure(id, message: message(error))
                    finish(id)
                    return
                }
            }
            transition(id, to: .completed)
        } catch is CancellationError {
            transition(id, to: .cancelled)
        } catch {
            if currentState(id) == .cancelled || currentState(id) == .paused {
                // already handled by cancel()/pause()
            } else {
                transition(id, to: .failed(message: message(error)))
            }
        }
        finish(id)
    }

    private func attachToAlbum(_ uid: PhotoUID, albumID: String, cover: UploadDestination.Cover?) async throws {
        guard let albums else { throw UploadError.albumStep("no album backend") }
        try await albums.addPhoto(uid, to: albumID)
        switch cover {
        case .firstUploaded:
            // Set cover to the first item (lowest ordinal) that has uploaded in this album.
            if isFirstUploadedInAlbum(uid, albumID: albumID) {
                try? await albums.setCover(albumID: albumID, photo: uid)
            }
        case let .specific(coverUID) where coverUID == uid:
            try? await albums.setCover(albumID: albumID, photo: uid)
        default:
            break
        }
    }

    private func isFirstUploadedInAlbum(_ uid: PhotoUID, albumID: String) -> Bool {
        let earlier = order.compactMap { jobs[$0] }
            .filter { $0.resolvedAlbumID == albumID && $0.item.uploadedUID != nil && $0.item.uploadedUID != uid }
        return earlier.isEmpty
    }

    private func finish(_ id: UploadQueueItemID) {
        activeIDs.remove(id)
        jobs[id]?.task = nil
        pump()
    }

    // MARK: - State transitions

    private func currentState(_ id: UploadQueueItemID) -> UploadItemState? { jobs[id]?.item.state }

    private func transition(_ id: UploadQueueItemID, to state: UploadItemState) {
        guard jobs[id] != nil else { return }
        jobs[id]?.item.state = state
        notify()
    }

    private func applyProgress(_ id: UploadQueueItemID, _ progress: UploadProgress) {
        guard let state = jobs[id]?.item.state, state.isActive, state != .finalizing else { return }
        switch progress.phase {
        case .preparing: jobs[id]?.item.state = .preparing
        case .hashing: jobs[id]?.item.state = .hashing
        case .uploading: jobs[id]?.item.state = .uploading(progress: progress.fraction)
        }
        notify()
    }

    private func setUploadedUID(_ id: UploadQueueItemID, _ uid: PhotoUID) {
        jobs[id]?.item.uploadedUID = uid
    }

    private func emitCompletedUpload(_ id: UploadQueueItemID) {
        guard let job = jobs[id], let uid = job.item.uploadedUID else { return }
        onCompleted?(UploadCompletedEvent(
            id: id,
            uploadedUID: uid,
            displayName: job.item.displayName,
            destination: job.destination,
            resolvedAlbumID: job.resolvedAlbumID,
            completedAt: now()
        ))
    }

    private func markPartialFailure(_ id: UploadQueueItemID, message: String) {
        jobs[id]?.item.partialSuccess = true
        jobs[id]?.item.state = .failed(message: UploadError.albumStep(message).errorDescription!)
        notify()
    }

    // MARK: - Controls

    public func pause(_ id: UploadQueueItemID) async {
        guard let state = jobs[id]?.item.state else { return }
        switch state {
        case .queued:
            jobs[id]?.item.state = .paused
            notify()
        case .uploading, .preparing, .hashing:
            jobs[id]?.item.state = .paused
            try? await uploader.pause(token: jobs[id]!.cancellationToken)
            notify()
        default:
            break
        }
    }

    public func resume(_ id: UploadQueueItemID) async {
        guard jobs[id]?.item.state == .paused else { return }
        if activeIDs.contains(id) {
            // Mid-flight pause: ask the backend to continue the same transfer.
            jobs[id]?.item.state = .uploading(progress: 0)
            try? await uploader.resume(token: jobs[id]!.cancellationToken)
            notify()
        } else {
            jobs[id]?.item.state = .queued
            pump()
        }
    }

    public func cancel(_ id: UploadQueueItemID) async {
        guard let state = jobs[id]?.item.state, !state.isTerminal else { return }
        let wasActive = activeIDs.contains(id)
        jobs[id]?.item.state = .cancelled
        if wasActive {
            await uploader.cancel(token: jobs[id]!.cancellationToken)
            jobs[id]?.task?.cancel()
        }
        notify()
    }

    public func retry(_ id: UploadQueueItemID) async {
        guard let job = jobs[id], job.item.state.isTerminal || job.item.state == .paused else { return }
        if job.item.partialSuccess, let uid = job.item.uploadedUID, let albumID = job.resolvedAlbumID {
            // The file is already uploaded; only the album step failed. Retry just that step.
            jobs[id]?.item.state = .finalizing
            jobs[id]?.item.partialSuccess = false
            notify()
            do {
                try await attachToAlbum(uid, albumID: albumID, cover: job.destination.cover)
                transition(id, to: .completed)
            } catch {
                markPartialFailure(id, message: message(error))
            }
            return
        }
        // Unsupported files can't be retried into success.
        if case .failed = job.item.state, !SupportedMedia.isSupported(job.item.fileURL) { return }
        // The failed attempt may have committed server-side (lost response). Re-resolve against
        // fresh remote state so the retry skips as a duplicate instead of uploading twice.
        await identityResolver?.invalidateCachedRemoteState()
        jobs[id]?.item.state = .queued
        jobs[id]?.item.uploadedUID = nil
        pump()
    }

    /// Global gate - stop dispatching new uploads (in-flight items finish).
    public func pauseAll() {
        globalPaused = true
        notify()
    }

    public func resumeAll() {
        globalPaused = false
        pump()
    }

    public func clearFinished() {
        let keep = order.filter { !(jobs[$0]?.item.state.isTerminal ?? true) || activeIDs.contains($0) }
        for id in order where !keep.contains(id) { jobs[id] = nil }
        order = keep
        notify()
    }

    // MARK: - Introspection

    public func snapshot() -> [UploadItem] {
        order.compactMap { jobs[$0]?.item }
    }

    private func computeStats() -> UploadQueueStats {
        var s = UploadQueueStats()
        s.concurrency = maxConcurrent
        for id in order {
            switch jobs[id]?.item.state {
            case .queued: s.queued += 1
            case .preparing, .hashing, .uploading, .finalizing: s.active += 1
            case .completed: s.completed += 1
            case let .skipped(reason):
                if reason.countsAsBackedUp {
                    s.skippedDuplicates += 1
                } else {
                    s.skippedRemoteDeletions += 1
                }
            case .failed: s.failed += 1
            case .cancelled: s.cancelled += 1
            case .paused: s.paused += 1
            case .none: break
            }
        }
        return s
    }

    private func notify() {
        onChange?(snapshot(), computeStats())
    }

    private func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

private extension UploadSkipReason {
    init?(duplicateReason: UploadDuplicateDecision.SkipReason) {
        switch duplicateReason {
        case .activeDuplicate:
            self = .activeDuplicate
        case .knownFromManifest:
            self = .knownFromManifest
        case .trashedDuplicate:
            self = .trashedDuplicate
        case .deletedRemotely:
            self = .deletedRemotely
        case .draftExists, .inconsistentRemoteState:
            return nil
        }
    }
}

private extension UploadDuplicateDecision.SkipReason {
    var blockingMessage: String {
        switch self {
        case .draftExists:
            return L10n.string("upload.error_remote_draft")
        case .inconsistentRemoteState:
            return L10n.string("upload.error_remote_inconsistent")
        case .activeDuplicate, .knownFromManifest, .trashedDuplicate, .deletedRemotely:
            return L10n.string("upload.error_duplicate_check_blocked")
        }
    }
}
