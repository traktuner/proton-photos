import Foundation
import PhotosCore

public enum MLSmartSearchQueryError: Error, Equatable {
    /// Smart Search is disabled, has no active model, or has no indexed coverage yet.
    case unavailable
    /// The model epoch changed while the query was in flight; the result was discarded.
    case staleEpoch
}

/// The single universal Smart Search lifecycle: one state machine, one implementation of
/// enable/disable, model selection, download, verification, activation, indexing, switching
/// and purge for every Apple platform. Platform code renders snapshots and calls intents —
/// it never makes lifecycle decisions.
///
/// Durability model:
/// - Installations are transactional (see `MLModelInstaller`).
/// - Multi-step operations (switch, purge) journal a `pendingOperation` before mutating
///   shared state and complete it on the next `start()` after a crash.
/// - Vectors are keyed by `MLModelDescriptor`, so even an interrupted cleanup can never make
///   an old epoch queryable: queries always use the active descriptor.
public actor MLSmartSearchLifecycle {
    public struct Configuration: Sendable {
        /// Delay before re-attempting indexing after a pass ends with transient failures or a
        /// closed gate (a kick from the host shortcuts the wait).
        public var indexRetryDelay: Duration
        /// Minimum download-fraction change worth emitting to observers.
        public var downloadProgressStep: Double

        public init(indexRetryDelay: Duration = .seconds(120), downloadProgressStep: Double = 0.01) {
            self.indexRetryDelay = indexRetryDelay
            self.downloadProgressStep = downloadProgressStep
        }
    }

    public struct Dependencies: Sendable {
        public var catalog: MLModelCatalog
        public var layout: MLModelInstallLayout
        public var stateStore: any MLSmartSearchStateStore
        public var installer: MLModelInstaller
        public var storeProvider: any MLIndexStoreProvider
        public var runtimeProvider: any MLSmartSearchRuntimeProvider
        /// Every asset UID the host currently knows (the timeline's complete set).
        public var assetsProvider: @Sendable () async -> [PhotoUID]
        public var governor: any MLIndexingGovernor
        /// `false` in Release builds: developer-only catalog entries cannot be listed,
        /// selected, or activated.
        public var allowsDeveloperModels: Bool

        public init(
            catalog: MLModelCatalog,
            layout: MLModelInstallLayout,
            stateStore: any MLSmartSearchStateStore,
            installer: MLModelInstaller,
            storeProvider: any MLIndexStoreProvider,
            runtimeProvider: any MLSmartSearchRuntimeProvider,
            assetsProvider: @escaping @Sendable () async -> [PhotoUID],
            governor: any MLIndexingGovernor,
            allowsDeveloperModels: Bool
        ) {
            self.catalog = catalog
            self.layout = layout
            self.stateStore = stateStore
            self.installer = installer
            self.storeProvider = storeProvider
            self.runtimeProvider = runtimeProvider
            self.assetsProvider = assetsProvider
            self.governor = governor
            self.allowsDeveloperModels = allowsDeveloperModels
        }
    }

    private let deps: Dependencies
    private let configuration: Configuration

    private var persistent = MLSmartSearchPersistentState()
    private var phase: MLSmartSearchPhase = .disabled
    private var session: (any MLSmartSearchSession)?
    private var activeModel: MLInstalledModel?
    /// Bumped on every activation/deactivation; in-flight queries from an older generation
    /// discard their results.
    private var sessionGeneration: UInt64 = 0
    private var lastCoverage = MLIndexCoverage(total: 0, indexed: 0, permanentlyUnindexable: 0)
    private var lastEmittedDownloadFraction: Double = -1

    /// `true` while a model switch is mid-flight: the still-running old-epoch index loop must
    /// not overwrite switch/download phases.
    private var switchInProgress = false
    private var indexTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<MLSmartSearchSnapshot>.Continuation] = [:]
    private var kickWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var started = false

    public init(dependencies: Dependencies, configuration: Configuration = Configuration()) {
        self.deps = dependencies
        self.configuration = configuration
    }

    // MARK: - Observation

    public func currentSnapshot() -> MLSmartSearchSnapshot { makeSnapshot() }

    /// Snapshot stream; yields the current state immediately, then every transition.
    public func snapshots() -> AsyncStream<MLSmartSearchSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            observers[id] = continuation
            continuation.yield(makeSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func emit() {
        let snapshot = makeSnapshot()
        for continuation in observers.values {
            continuation.yield(snapshot)
        }
    }

    private func makeSnapshot() -> MLSmartSearchSnapshot {
        MLSmartSearchSnapshot(
            isEnabled: persistent.isEnabled,
            selectedModelID: persistent.selectedModelID,
            phase: phase,
            installedModelBytes: activeModel?.record.installedByteCount ?? 0,
            availableModels: deps.catalog.selectableEntries(allowsDeveloperModels: deps.allowsDeveloperModels),
            isSearchAvailable: persistent.isEnabled && session != nil && lastCoverage.indexed > 0
        )
    }

    // MARK: - Startup / recovery

    /// Restore persisted state, finish any journaled operation, and resume work. Idempotent.
    public func start() async {
        guard !started else { return }
        started = true
        persistent = deps.stateStore.load() ?? MLSmartSearchPersistentState()

        switch persistent.pendingOperation {
        case .purge:
            // A purge that began before a crash completes before anything else may run.
            await performPurge()
            return
        case .switchModel(let from, let to):
            completeSwitchCleanup(from: from, to: to)
        case nil:
            break
        }

        guard persistent.isEnabled, persistent.selectedModelID != nil else {
            phase = .disabled
            emit()
            return
        }
        await activateSelectedModel()
    }

    /// Cancel background work before process exit. Chunk-durable indexing and the journaled
    /// install/switch/purge steps make sudden termination safe; this just stops new work.
    public func prepareForTermination() {
        indexTask?.cancel()
    }

    // MARK: - Intents

    public func setEnabled(_ enabled: Bool) async {
        guard enabled != persistent.isEnabled else { return }
        if enabled {
            persistent.isEnabled = true
            if persistent.selectedModelID == nil {
                persistent.selectedModelID = deps.catalog
                    .selectableEntries(allowsDeveloperModels: deps.allowsDeveloperModels)
                    .first(where: { $0.releaseTrack == .production })?.id
            }
            save()
            await activateSelectedModel()
        } else {
            await performPurge()
        }
    }

    /// Explicit full disable + purge (same as `setEnabled(false)`, exposed for the destructive
    /// confirmation flow).
    public func disableAndPurge() async {
        await performPurge()
    }

    /// Select a model. Same selection is a no-op; a different model runs the transactional
    /// switch (download new → journal → retire old epoch → activate → clean reindex).
    public func select(_ id: MLModelID) async {
        guard persistent.isEnabled else { return }
        guard id != persistent.selectedModelID else { return }
        guard let target = deps.catalog.entry(for: id),
              deps.allowsDeveloperModels || target.releaseTrack == .production else { return }

        let previousID = persistent.selectedModelID
        let previousEntry = previousID.flatMap { deps.catalog.entry(for: $0) }
        switchInProgress = true
        defer { switchInProgress = false }

        // 1. Make the target installable without disturbing the current installation.
        if deps.installer.anyInstalledRecord(for: target) == nil {
            guard target.isDownloadable else {
                // Nothing to switch to yet: keep the current model active and report why.
                phase = .switchingModel(to: id)
                emit()
                phase = .failed(MLSmartSearchFailure(
                    kind: .download,
                    isRetryable: false,
                    debugDescription: "no hosted artifact for \(id.rawValue)"
                ))
                emit()
                await activateSelectedModel()
                return
            }
            guard await downloadAndInstall(target) != nil else { return }
        }

        // 2. Journal the switch, then retire the old epoch. From this point the old model
        //    never serves again, even across a crash.
        persistent.pendingOperation = .switchModel(from: previousID, to: id)
        persistent.selectedModelID = id
        persistent.activatedRevision = nil
        save()
        phase = .switchingModel(to: id)
        emit()

        await stopIndexing()
        await teardownSession()
        if let previousEntry {
            deps.storeProvider.openStore()?.removeAll(for: previousEntry.descriptor)
            await deps.installer.uninstall(previousEntry)
        }
        persistent.pendingOperation = nil
        save()

        // 3. Activate the new epoch and reindex from a clean slate.
        await activateSelectedModel()
    }

    /// Retry after a retryable failure (download, model load, storage).
    public func retry() async {
        guard persistent.isEnabled, case .failed(let failure) = phase, failure.isRetryable else { return }
        await activateSelectedModel()
    }

    /// Install a developer-provided local model artifact for `id` (developer environments
    /// only). The artifact is hashed, staged and installed with the same guarantees as a
    /// download.
    public func installDeveloperModel(from artifactDirectory: URL, for id: MLModelID) async {
        guard deps.allowsDeveloperModels,
              persistent.isEnabled,
              let entry = deps.catalog.entry(for: id) else { return }
        phase = .installing
        emit()
        do {
            _ = try await deps.installer.installFromLocalArtifact(entry, artifactDirectory: artifactDirectory)
        } catch {
            phase = .failed(MLSmartSearchFailure(
                kind: .installation,
                isRetryable: true,
                debugDescription: String(describing: error)
            ))
            emit()
            return
        }
        if persistent.selectedModelID == id {
            await activateSelectedModel()
        } else {
            await select(id)
        }
    }

    /// The host's library changed (new or deleted assets): schedule an indexing catch-up.
    public func noteLibraryChanged() {
        kick()
    }

    /// Scheduling conditions changed (thermal recovered, power connected, app foregrounded).
    public func noteConditionsChanged() {
        kick()
    }

    /// Drop cached vector blocks and release model residency under memory pressure.
    public func releaseMemory() async {
        await session?.releaseMemory()
    }

    // MARK: - Search

    /// Epoch-guarded semantic query against the active model. Results from a superseded model
    /// generation are discarded, never returned.
    public func search(_ text: String, limit: Int = 50) async throws -> MLSearchResults {
        guard persistent.isEnabled, let session, lastCoverage.indexed > 0 else {
            throw MLSmartSearchQueryError.unavailable
        }
        let generation = sessionGeneration
        let results = try await session.search(text, limit: limit)
        guard generation == sessionGeneration else {
            throw MLSmartSearchQueryError.staleEpoch
        }
        return results
    }

    // MARK: - Activation

    private func activateSelectedModel() async {
        guard persistent.isEnabled,
              let selectedID = persistent.selectedModelID,
              let entry = deps.catalog.entry(for: selectedID),
              deps.allowsDeveloperModels || entry.releaseTrack == .production else {
            phase = .disabled
            emit()
            return
        }

        let record: MLModelInstallRecord?
        if let revision = persistent.activatedRevision {
            record = deps.installer.installedRecord(for: entry, revision: revision)
                ?? deps.installer.anyInstalledRecord(for: entry)
        } else {
            record = deps.installer.anyInstalledRecord(for: entry)
        }

        guard let record else {
            if entry.isDownloadable {
                if await downloadAndInstall(entry) != nil {
                    await activateSelectedModel()
                } // else phase already reports the failure
            } else {
                phase = .notInstalled(downloadable: false)
                emit()
            }
            return
        }

        phase = .preparingModel
        emit()

        guard let store = deps.storeProvider.openStore() else {
            phase = .failed(MLSmartSearchFailure(kind: .storage, isRetryable: true, debugDescription: "index store unavailable"))
            emit()
            return
        }

        let installed = MLInstalledModel(
            entry: entry,
            record: record,
            installDirectory: deps.layout.installDirectory(for: entry.id, revision: record.revision)
        )
        let governor = deps.governor
        do {
            let newSession = try await deps.runtimeProvider.makeSession(
                model: installed,
                store: store,
                shouldContinueIndexing: { governor.permitsIndexing() },
                onIndexProgress: { [weak self] progress in
                    guard let self else { return }
                    Task { await self.noteIndexProgress(progress) }
                }
            )
            session = newSession
            activeModel = installed
            sessionGeneration &+= 1
            persistent.activatedRevision = record.revision
            save()
            startIndexingLoop()
        } catch {
            phase = .failed(MLSmartSearchFailure(
                kind: .modelLoad,
                isRetryable: true,
                debugDescription: String(describing: error)
            ))
            emit()
        }
    }

    /// Download + verify + install `entry`. Returns the record, or `nil` after reporting a
    /// failure phase.
    private func downloadAndInstall(_ entry: MLModelCatalogEntry) async -> MLModelInstallRecord? {
        phase = .downloading(MLModelTransferProgress(bytesReceived: 0, totalBytes: entry.downloadPlan?.totalByteCount))
        lastEmittedDownloadFraction = -1
        emit()
        do {
            let record = try await deps.installer.install(entry) { [weak self] progress in
                guard let self else { return }
                Task { await self.noteDownloadProgress(progress) }
            }
            phase = .installing
            emit()
            return record
        } catch is CancellationError {
            phase = persistent.isEnabled ? .notInstalled(downloadable: entry.isDownloadable) : .disabled
            emit()
            return nil
        } catch let error as MLModelInstallError {
            if error == .cancelled {
                phase = persistent.isEnabled ? .notInstalled(downloadable: entry.isDownloadable) : .disabled
                emit()
                return nil
            }
            let kind: MLSmartSearchFailure.Kind
            switch error {
            case .checksumMismatch, .sizeMismatch, .unsafeArtifactPath:
                kind = .verification
            case .artifactMissing, .installRecordUnreadable, .notDownloadable:
                kind = .installation
            case .cancelled:
                kind = .download
            }
            phase = .failed(MLSmartSearchFailure(kind: kind, isRetryable: true, debugDescription: String(describing: error)))
            emit()
            return nil
        } catch {
            phase = .failed(MLSmartSearchFailure(kind: .download, isRetryable: true, debugDescription: String(describing: error)))
            emit()
            return nil
        }
    }

    private func noteDownloadProgress(_ progress: MLModelTransferProgress) {
        guard case .downloading = phase else { return }
        let fraction = progress.fraction ?? 0
        if fraction >= 1 {
            phase = .verifying
            emit()
            return
        }
        // Coalesce: only whole steps reach observers, so UI never storms.
        guard fraction - lastEmittedDownloadFraction >= configuration.downloadProgressStep else { return }
        lastEmittedDownloadFraction = fraction
        phase = .downloading(progress)
        emit()
    }

    private func noteIndexProgress(_ progress: MLIndexProgress) {
        guard !switchInProgress else { return }
        guard let activeModel, progress.descriptor == activeModel.entry.descriptor else { return }
        guard case .indexing = phase else { return }
        phase = .indexing(progress)
        emit()
    }

    // MARK: - Indexing loop

    private func startIndexingLoop() {
        indexTask?.cancel()
        let generation = sessionGeneration
        indexTask = Task { await runIndexingLoop(generation: generation) }
    }

    private func runIndexingLoop(generation: UInt64) async {
        while !Task.isCancelled, generation == sessionGeneration, persistent.isEnabled, let session, let activeModel {
            guard deps.governor.permitsIndexing() else {
                refreshCoverage(descriptor: activeModel.entry.descriptor, assets: nil)
                setPhaseFromIndexLoop(.ready(lastCoverage))
                await waitForKick(timeout: configuration.indexRetryDelay)
                continue
            }

            let assets = await deps.assetsProvider()
            guard generation == sessionGeneration else { return }

            setPhaseFromIndexLoop(.indexing(MLIndexProgress(
                phase: .indexing,
                descriptor: activeModel.entry.descriptor,
                totalAssets: assets.count
            )))

            let outcome = await session.index(assets)
            guard generation == sessionGeneration, !Task.isCancelled else { return }

            removeDeletedAssets(current: assets, descriptor: activeModel.entry.descriptor)
            refreshCoverage(descriptor: activeModel.entry.descriptor, assets: assets)

            setPhaseFromIndexLoop(.ready(lastCoverage))

            if outcome.ranToCompletion && lastCoverage.isComplete {
                // Fully caught up: sleep until the library or conditions change.
                await waitForKick(timeout: nil)
            } else {
                // Gate closed mid-pass or transient failures remain: retry later, or sooner
                // when kicked.
                await waitForKick(timeout: configuration.indexRetryDelay)
            }
        }
    }

    /// Phase writes from the index loop are suppressed while a switch or purge is staging
    /// its own phases.
    private func setPhaseFromIndexLoop(_ newPhase: MLSmartSearchPhase) {
        guard !switchInProgress, !phase.isBusy || phase == .preparingModel else { return }
        phase = newPhase
        emit()
    }

    /// Drop vectors for assets that no longer exist in the library.
    private func removeDeletedAssets(current: [PhotoUID], descriptor: MLModelDescriptor) {
        guard let store = deps.storeProvider.openStore() else { return }
        let currentSet = Set(current)
        for uid in store.allIndexedUIDs(for: descriptor) where !currentSet.contains(uid) {
            store.remove(uid: uid, descriptor: descriptor)
        }
    }

    private func refreshCoverage(descriptor: MLModelDescriptor, assets: [PhotoUID]?) {
        guard let store = deps.storeProvider.openStore() else { return }
        if let assets {
            lastCoverage = store.coverage(for: descriptor, allAssets: assets)
        } else {
            let indexed = store.count(for: descriptor)
            lastCoverage = MLIndexCoverage(
                total: max(lastCoverage.total, indexed),
                indexed: indexed,
                permanentlyUnindexable: lastCoverage.permanentlyUnindexable
            )
        }
    }

    // MARK: - Kick / wait

    private func kick() {
        let waiters = kickWaiters
        kickWaiters = [:]
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    private func waitForKick(timeout: Duration?) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                kickWaiters[id] = continuation
                if let timeout {
                    Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        await self?.resumeKickWaiter(id)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.resumeKickWaiter(id) }
        }
    }

    private func resumeKickWaiter(_ id: UUID) {
        guard let waiter = kickWaiters.removeValue(forKey: id) else { return }
        waiter.resume()
    }

    // MARK: - Teardown / purge

    private func stopIndexing() async {
        indexTask?.cancel()
        // Resume any parked loop so cancellation lands at the next boundary.
        kick()
        _ = await indexTask?.value
        indexTask = nil
    }

    private func teardownSession() async {
        sessionGeneration &+= 1
        if let session {
            await session.shutdown()
        }
        session = nil
        activeModel = nil
        lastCoverage = MLIndexCoverage(total: 0, indexed: 0, permanentlyUnindexable: 0)
    }

    /// Journal cleanup for a switch interrupted by a crash: the old epoch's vectors and
    /// artifacts must be gone before the new model may activate. Idempotent.
    private func completeSwitchCleanup(from: MLModelID?, to: MLModelID) {
        if let from, let previousEntry = deps.catalog.entry(for: from) {
            deps.storeProvider.openStore()?.removeAll(for: previousEntry.descriptor)
            Task { await deps.installer.uninstall(previousEntry) }
        }
        persistent.selectedModelID = to
        persistent.activatedRevision = nil
        persistent.pendingOperation = nil
        save()
    }

    /// Full disable: stop everything, close every handle, delete every Smart Search artifact,
    /// return to the clean disabled state. Idempotent and journaled (a crash mid-purge
    /// completes on next start).
    private func performPurge() async {
        // Journal first: any crash from here on re-runs the purge.
        persistent.pendingOperation = .purge
        persistent.isEnabled = false
        save()

        phase = .deleting
        emit()

        if let selectedID = persistent.selectedModelID {
            await deps.installer.cancelInstall(of: selectedID)
        }
        await stopIndexing()
        await teardownSession()
        deps.storeProvider.closeStore()

        // Everything Smart Search owns lives under the layout root — one recursive delete is
        // the provably complete purge (index DB + WAL/SHM, models, temp files, state).
        try? FileManager.default.removeItem(at: deps.layout.rootDirectory)

        // No persisted state left: a relaunch loads the default disabled state.
        persistent = MLSmartSearchPersistentState()
        phase = .disabled
        emit()
    }

    private func save() {
        deps.stateStore.save(persistent)
    }
}
