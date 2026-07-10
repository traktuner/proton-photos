import Foundation
import PhotosCore
import Testing
@testable import MLSearchCore

/// Shared controller behavior that platform views rely on: the developer-artifact import owns
/// the security-scope lifetime (views own no filesystem lifecycle), and the atomic state store
/// surfaces write failures instead of swallowing them.
@Suite struct MLSmartSearchControllerTests {
    private final class ScopeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var beginCount = 0
        private(set) var endCount = 0
        /// Set when `end` fired: whether the install had already completed at that moment.
        private(set) var installCompleteWhenEnded: Bool?

        func recordBegin() { lock.withLock { beginCount += 1 } }
        func recordEnd(installComplete: Bool) {
            lock.withLock {
                endCount += 1
                installCompleteWhenEnded = installComplete
            }
        }
        var state: (begins: Int, ends: Int, installCompleteWhenEnded: Bool?) {
            lock.withLock { (beginCount, endCount, installCompleteWhenEnded) }
        }
    }

    private struct UnusedTransport: MLModelArtifactTransport {
        func download(
            from url: URL,
            to destination: URL,
            expectedByteCount: Int64,
            progress: @escaping @Sendable (Int64, Int64?) -> Void
        ) async throws {
            throw URLError(.fileDoesNotExist)
        }
    }

    private final class NoopRuntimeProvider: MLSmartSearchRuntimeProvider {
        struct NoRuntime: Error {}
        func makeSession(
            model: MLInstalledModel,
            store: any MLIndexStore,
            shouldContinueIndexing: @escaping @Sendable () -> Bool,
            onIndexProgress: @escaping @Sendable (MLIndexProgress) -> Void
        ) async throws -> any MLSmartSearchSession {
            throw NoRuntime()
        }
    }

    private final class InMemoryStoreProvider: MLIndexStoreProvider, @unchecked Sendable {
        let store = InMemoryMLIndexStore()
        func openStore() -> (any MLIndexStore)? { store }
        func closeStore() {}
    }

    @discardableResult
    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }

    @Test @MainActor func developerImportHoldsTheSecurityScopeUntilInstallCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-controller-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)

        let entry = MLModelCatalogEntry(
            id: MLModelID("dev-model"),
            displayName: "dev-model",
            family: "Test",
            descriptor: MLModelDescriptor(identifier: "dev-model", version: 1, embeddingDimension: 4),
            tokenizerID: "t",
            preprocessingID: "p",
            license: .mit,
            releaseTrack: .developerOnly,
            estimatedInstalledBytes: 1,
            downloadPlan: nil
        )
        let installer = MLModelInstaller(layout: layout, transport: UnusedTransport())
        let lifecycle = MLSmartSearchLifecycle(dependencies: .init(
            catalog: MLModelCatalog(entries: [entry]),
            layout: layout,
            stateStore: FileMLSmartSearchStateStore(layout: layout),
            installer: installer,
            storeProvider: InMemoryStoreProvider(),
            runtimeProvider: NoopRuntimeProvider(),
            assetsProvider: { [] },
            governor: MLAlwaysPermitsIndexing(),
            allowsDeveloperModels: true
        ))

        // The developer artifact the user "picked".
        let artifact = root.appendingPathComponent("picked-artifact", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: artifact.appendingPathComponent("weights.bin"))

        let recorder = ScopeRecorder()
        let access = MLScopedArtifactAccess(
            begin: { _ in
                recorder.recordBegin()
                return true
            },
            end: { _ in
                // The moment the scope closes, the install must ALREADY be durable: copying
                // and hashing a scoped URL after the scope ended is the bug this guards.
                recorder.recordEnd(installComplete: installer.anyInstalledRecord(for: entry) != nil)
            }
        )
        await lifecycle.start()
        let controller = MLSmartSearchController(lifecycle: lifecycle, artifactAccess: access)
        await lifecycle.setEnabled(true)

        controller.installDeveloperModel(from: artifact, for: entry.id)

        #expect(await waitUntil { recorder.state.ends == 1 })
        let state = recorder.state
        #expect(state.begins == 1)
        #expect(state.ends == 1)
        #expect(state.installCompleteWhenEnded == true)
        #expect(installer.anyInstalledRecord(for: entry) != nil)
    }
}

/// The atomic file store must surface write failures (journal writes may never be lost
/// silently) and keep the previous state readable when a write cannot happen.
@Suite struct FileMLSmartSearchStateStoreTests {
    @Test func saveThrowsWhenTheStateFileCannotBeWritten() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-statestore-\(UUID().uuidString)")
        // Occupy the ROOT path with a plain file: directory creation and the atomic write
        // below it must fail loudly, not silently.
        try Data("blocker".utf8).write(to: base)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = FileMLSmartSearchStateStore(layout: MLModelInstallLayout(rootDirectory: base))
        #expect(throws: (any Error).self) {
            try store.save(MLSmartSearchPersistentState(isEnabled: true))
        }
        #expect(try store.load() == nil)
    }

    @Test func saveIsAtomicAndRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-statestore-ok-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileMLSmartSearchStateStore(layout: MLModelInstallLayout(rootDirectory: root))

        let state = MLSmartSearchPersistentState(
            isEnabled: true,
            selectedModelID: MLModelID("model-a"),
            activatedRevision: "rev1",
            pendingOperation: .switchModel(from: MLModelID("model-a"), to: MLModelID("model-b"))
        )
        try store.save(state)
        #expect(try store.load() == state)

        store.clear()
        #expect(try store.load() == nil)
    }

    @Test func corruptStateIsNotSilentlyTreatedAsDisabled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-statestore-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: layout.stateFileURL)

        let store = FileMLSmartSearchStateStore(layout: layout)
        #expect(throws: (any Error).self) {
            _ = try store.load()
        }
    }
}
