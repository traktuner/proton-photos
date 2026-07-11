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
        public var catalogProvider: any MLModelCatalogProvider
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
        /// Core-level gate. Hosts may omit UI, but lifecycle work is independently blocked here so
        /// a platform cannot accidentally activate an unsupported or unlicensed feature.
        public var featureAvailability: AppFeatureAvailability

        public init(
            catalog: MLModelCatalog,
            catalogProvider: (any MLModelCatalogProvider)? = nil,
            layout: MLModelInstallLayout,
            stateStore: any MLSmartSearchStateStore,
            installer: MLModelInstaller,
            storeProvider: any MLIndexStoreProvider,
            runtimeProvider: any MLSmartSearchRuntimeProvider,
            assetsProvider: @escaping @Sendable () async -> [PhotoUID],
            governor: any MLIndexingGovernor,
            allowsDeveloperModels: Bool,
            featureAvailability: AppFeatureAvailability = .available
        ) {
            self.catalog = catalog
            self.catalogProvider = catalogProvider ?? StaticMLModelCatalogProvider(catalog)
            self.layout = layout
            self.stateStore = stateStore
            self.installer = installer
            self.storeProvider = storeProvider
            self.runtimeProvider = runtimeProvider
            self.assetsProvider = assetsProvider
            self.governor = governor
            self.allowsDeveloperModels = allowsDeveloperModels
            self.featureAvailability = featureAvailability
        }
    }

    private let deps: Dependencies
    private let configuration: Configuration
    private var catalog: MLModelCatalog

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
    private var stateLoadFailed = false
    /// Terminal: set by `shutdown()`. Every intent becomes a no-op, so a host tearing the
    /// session down can never race new lifecycle work against its account purge.
    private var isShutDown = false

    public init(dependencies: Dependencies, configuration: Configuration = Configuration()) {
        self.deps = dependencies
        self.configuration = configuration
        self.catalog = dependencies.catalog
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
            availableModels: catalog.selectableEntries(allowsDeveloperModels: deps.allowsDeveloperModels),
            isSearchAvailable: persistent.isEnabled && session != nil && lastCoverage.indexed > 0
        )
    }

    // MARK: - Startup / recovery

    /// Restore persisted state, finish any journaled operation, and resume work. Idempotent.
    public func start() async {
        guard !started, !isShutDown else { return }
        started = true
        guard deps.featureAvailability == .available else {
            phase = .disabled
            emit()
            return
        }
        guard restorePersistentState() else { return }
        if persistent.isEnabled, !(await refreshCatalog()) { return }
        await resumePersistentState()
    }

    private func restorePersistentState() -> Bool {
        do {
            persistent = try deps.stateStore.load() ?? MLSmartSearchPersistentState()
            stateLoadFailed = false
            return true
        } catch {
            stateLoadFailed = true
            phase = .failed(MLSmartSearchFailure(
                kind: .storage,
                isRetryable: true,
                debugDescription: "state read failed: \(String(describing: error))"
            ))
            emit()
            return false
        }
    }

    private func resumePersistentState() async {
        switch persistent.pendingOperation {
        case .purge:
            // A purge that began before a crash completes before anything else may run.
            await performPurge()
            return
        case .switchModel(let from, let to):
            guard await completeSwitchCleanup(from: from, to: to) else { return }
        case nil:
            break
        }

        guard persistent.isEnabled else {
            phase = .disabled
            emit()
            return
        }
        guard persistent.selectedModelID != nil else {
            phase = .selectingModel
            emit()
            return
        }
        await activateSelectedModel()
    }

    /// Ordered, awaitable session teardown — the ONE shutdown path both platforms call before
    /// account purge or sign-out. When this returns, no Smart Search work is running and no
    /// file handle into the Smart Search root remains open:
    /// 1. new work is refused (every intent no-ops),
    /// 2. in-flight installs are cancelled AND awaited,
    /// 3. the indexing task is cancelled AND awaited,
    /// 4. the inference session is shut down (model residency released),
    /// 5. the SQLite index store (and its WAL) is closed.
    /// Chunk-durable indexing and the journaled install/switch/purge steps additionally make
    /// SUDDEN termination safe; this method is for deliberate teardown, where the caller is
    /// about to delete the files underneath us.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        await deps.installer.cancelAllInstalls()
        await stopIndexing()
        await teardownSession()
        deps.storeProvider.closeStore()
        for continuation in observers.values {
            continuation.finish()
        }
        observers = [:]
    }

    // MARK: - Intents

    public func setEnabled(_ enabled: Bool) async {
        guard !isShutDown, deps.featureAvailability == .available,
              enabled != persistent.isEnabled else { return }
        if enabled {
            persistent.isEnabled = true
            guard persistState() else { return }
            guard await refreshCatalog() else { return }
            let selectable = catalog.selectableEntries(allowsDeveloperModels: deps.allowsDeveloperModels)
            guard !selectable.isEmpty else {
                persistent.isEnabled = false
                guard persistState() else { return }
                phase = .notInstalled(downloadable: false)
                emit()
                return
            }
            guard let selectedID = persistent.selectedModelID,
                  selectable.contains(where: { $0.id == selectedID }) else {
                persistent.selectedModelID = selectable.count == 1 ? selectable[0].id : nil
                guard persistState() else { return }
                if persistent.selectedModelID == nil {
                    phase = .selectingModel
                    emit()
                    return
                }
                await activateSelectedModel()
                return
            }
            // A failed enable-write stops here with an honest, retryable failure phase — the
            // in-memory intent stays, so `retry()` re-persists and activates.
            guard persistState() else { return }
            await activateSelectedModel()
        } else {
            await performPurge()
        }
    }

    /// Explicit full disable + purge (same as `setEnabled(false)`, exposed for the destructive
    /// confirmation flow).
    public func disableAndPurge() async {
        guard !isShutDown else { return }
        await performPurge()
    }

    /// Select a model. Same selection is a no-op; a different model runs the transactional
    /// switch (download new → journal → retire old epoch → activate → clean reindex).
    public func select(_ id: MLModelID) async {
        guard !isShutDown, persistent.isEnabled else { return }
        guard id != persistent.selectedModelID else { return }
        guard let target = catalog.entry(for: id), isSelectable(target) else { return }

        let previousID = persistent.selectedModelID
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

        // 2. Journal the switch BEFORE touching shared state. If the journal write fails, the
        //    switch never happened: revert in memory and keep the current model serving.
        persistent.pendingOperation = .switchModel(from: previousID, to: id)
        persistent.selectedModelID = id
        persistent.activatedRevision = nil
        guard persistState() else {
            persistent.pendingOperation = nil
            persistent.selectedModelID = previousID
            return
        }
        phase = .switchingModel(to: id)
        emit()

        // 3. Retire the old epoch, commit the journal, then activate the new epoch from a
        //    clean slate. One ordered, idempotent path — identical to crash recovery.
        await stopIndexing()
        await teardownSession()
        guard await completeSwitchCleanup(from: previousID, to: id) else { return }
        await activateSelectedModel()
    }

    /// Retry after a retryable failure (download, model load, storage). A storage failure may
    /// have interrupted a journaled operation — recovery re-runs that operation (idempotent)
    /// instead of blindly re-activating over it.
    public func retry() async {
        guard !isShutDown else { return }
        if stateLoadFailed {
            guard restorePersistentState() else { return }
            await resumePersistentState()
            return
        }
        guard !isShutDown, persistent.isEnabled || persistent.pendingOperation == .purge,
              case .failed(let failure) = phase, failure.isRetryable else { return }
        if failure.kind == .catalog {
            guard await refreshCatalog() else { return }
            await activateSelectedModel()
            return
        }
        if failure.kind == .storage, persistent.isEnabled, persistent.selectedModelID == nil {
            guard persistState() else { return }
            let selectable = catalog.selectableEntries(allowsDeveloperModels: deps.allowsDeveloperModels)
            if selectable.count == 1 {
                persistent.selectedModelID = selectable[0].id
                guard persistState() else { return }
                await activateSelectedModel()
            } else {
                phase = .selectingModel
                emit()
            }
            return
        }
        switch persistent.pendingOperation {
        case .purge:
            await performPurge()
        case .switchModel(let from, let to):
            guard await completeSwitchCleanup(from: from, to: to) else { return }
            await activateSelectedModel()
        case nil:
            await activateSelectedModel()
        }
    }

    /// Install a developer-provided local model artifact for `id` (developer environments
    /// only). The artifact is hashed, staged and installed with the same guarantees as a
    /// download.
    public func installDeveloperModel(from artifactDirectory: URL, for id: MLModelID) async {
        guard !isShutDown,
              deps.allowsDeveloperModels,
              persistent.isEnabled,
              let entry = catalog.entry(for: id) else { return }
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
        guard !isShutDown, persistent.isEnabled, let session, lastCoverage.indexed > 0 else {
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

    /// A model may be selected/activated in this environment: developer environments see every
    /// entry; release environments require the production track AND a product-usable license.
    private func isSelectable(_ entry: MLModelCatalogEntry) -> Bool {
        deps.allowsDeveloperModels
            || entry.isReleaseReady
    }

    private func activateSelectedModel() async {
        guard !isShutDown, persistent.isEnabled else {
            phase = .disabled
            emit()
            return
        }
        guard let selectedID = persistent.selectedModelID else {
            phase = .selectingModel
            emit()
            return
        }
        guard
              let entry = catalog.entry(for: selectedID),
              isSelectable(entry) else {
            phase = .selectingModel
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
            let previousRevision = persistent.activatedRevision
            persistent.activatedRevision = record.revision
            guard persistState() else {
                persistent.activatedRevision = previousRevision
                await newSession.shutdown()
                return
            }
            session = newSession
            activeModel = installed
            sessionGeneration &+= 1
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
            var isRetryable = true
            switch error {
            case .checksumMismatch, .sizeMismatch, .unsafeArtifactPath:
                kind = .verification
            case .artifactMissing, .ambiguousModelArtifact, .installRecordUnreadable, .notDownloadable:
                kind = .installation
            case .licenseProhibitsDistribution:
                // Retrying cannot change the license — this stays blocked until the catalog
                // ships an entry whose weights are legally distributable.
                kind = .installation
                isRetryable = false
            case .cancelled:
                kind = .download
            }
            phase = .failed(MLSmartSearchFailure(kind: kind, isRetryable: isRetryable, debugDescription: String(describing: error)))
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
        lastCoverage = MLIndexCoverage(
            total: progress.totalAssets,
            indexed: progress.indexed + progress.alreadyIndexed,
            permanentlyUnindexable: progress.permanentFailure
        )
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
                refreshCoverageFromStoreCount(descriptor: activeModel.entry.descriptor)
                setPhaseFromIndexLoop(.waiting(lastCoverage))
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

            lastCoverage = outcome.coverage
            if outcome.ranToCompletion {
                removeDeletedAssets(current: assets, descriptor: activeModel.entry.descriptor)
            }

            if outcome.ranToCompletion && lastCoverage.isComplete {
                setPhaseFromIndexLoop(.ready(lastCoverage))
                // Fully caught up: sleep until the library or conditions change.
                await waitForKick(timeout: nil)
            } else {
                setPhaseFromIndexLoop(.waiting(lastCoverage))
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
        let deleted = store.allTrackedUIDs(for: descriptor).filter { !currentSet.contains($0) }
        store.remove(uids: deleted, descriptor: descriptor)
    }

    private func refreshCoverageFromStoreCount(descriptor: MLModelDescriptor) {
        guard let store = deps.storeProvider.openStore() else { return }
        let indexed = store.count(for: descriptor)
        lastCoverage = MLIndexCoverage(
            total: max(lastCoverage.total, indexed),
            indexed: indexed,
            permanentlyUnindexable: lastCoverage.permanentlyUnindexable
        )
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

    /// Journaled switch cleanup, shared verbatim by the live switch path and crash recovery:
    /// retire the old epoch's vectors, remove the old artifacts (awaited, never fire-and-
    /// forget), THEN commit the journal. Idempotent — re-running after any interruption
    /// converges to the same state. Returns `false` when the journal commit could not be
    /// persisted; the pending operation stays journaled (and in memory) so `retry()` or the
    /// next `start()` finishes it.
    @discardableResult
    private func completeSwitchCleanup(from: MLModelID?, to: MLModelID) async -> Bool {
        if let from, let previousEntry = catalog.entry(for: from) {
            deps.storeProvider.openStore()?.removeAll(for: previousEntry.descriptor)
            await deps.installer.uninstall(previousEntry)
        }
        persistent.selectedModelID = to
        persistent.activatedRevision = nil
        persistent.pendingOperation = nil
        guard persistState() else {
            // Keep the journal in memory too: retry/start re-run this exact cleanup.
            persistent.pendingOperation = .switchModel(from: from, to: to)
            return false
        }
        return true
    }

    /// Full disable: stop everything, close every handle, delete every Smart Search artifact,
    /// return to the clean disabled state. Idempotent and journaled (a crash mid-purge
    /// completes on next start).
    private func performPurge() async {
        // Journal first: any crash from here on re-runs the purge. If the journal itself
        // cannot be written, the purge does NOT start silently — the failure phase is honest
        // and `retry()` re-attempts the whole purge.
        persistent.pendingOperation = .purge
        persistent.isEnabled = false
        guard persistState() else { return }

        phase = .deleting
        emit()

        await deps.installer.cancelAllInstalls()
        await stopIndexing()
        await teardownSession()
        deps.storeProvider.closeStore()

        // Everything Smart Search owns lives under the layout root — one recursive delete is
        // the provably complete purge (index DB + WAL/SHM, models, temp files, state).
        do {
            try FileManager.default.removeItem(at: deps.layout.rootDirectory)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            // Already gone — purge is idempotent.
        } catch {
            // Files may remain: stay journaled (state file might survive inside the root) and
            // report a retryable storage failure instead of pretending the purge completed.
            phase = .failed(MLSmartSearchFailure(
                kind: .storage,
                isRetryable: true,
                debugDescription: "purge failed: \(String(describing: error))"
            ))
            emit()
            return
        }

        // No persisted state left: a relaunch loads the default disabled state.
        persistent = MLSmartSearchPersistentState()
        phase = .disabled
        emit()
    }

    /// Persist the current state. On failure: emit an honest, retryable `.failed(.storage)`
    /// phase and return `false`; callers must not continue without an atomic state commit.
    private func persistState() -> Bool {
        do {
            try deps.stateStore.save(persistent)
            stateLoadFailed = false
            return true
        } catch {
            phase = .failed(MLSmartSearchFailure(
                kind: .storage,
                isRetryable: true,
                debugDescription: "state write failed: \(String(describing: error))"
            ))
            emit()
            return false
        }
    }

    /// Refreshes only the signed distribution data. Runtime contracts, dimensions and
    /// licensing remain compiled into the app and are validated by the provider.
    private func refreshCatalog() async -> Bool {
        phase = .loadingCatalog
        emit()
        do {
            catalog = try await deps.catalogProvider.catalog()
            return true
        } catch {
            phase = .failed(MLSmartSearchFailure(
                kind: .catalog,
                isRetryable: true,
                debugDescription: String(describing: error)
            ))
            emit()
            return false
        }
    }
}
