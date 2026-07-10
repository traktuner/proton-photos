import Foundation
import PhotosCore

/// One live inference+index session bound to exactly one installed model epoch.
///
/// `MLSearchService` is the canonical implementation; tests inject fakes. A session owns its
/// model residency: `shutdown()` must release every model and cached vector block so a switch
/// or purge can never leak the previous epoch's memory.
public protocol MLSmartSearchSession: Sendable {
    var descriptor: MLModelDescriptor { get }
    func index(_ assets: [PhotoUID]) async -> MLIndexPassOutcome
    func search(_ text: String, limit: Int) async throws -> MLSearchResults
    func coverage(for assets: [PhotoUID]) async -> MLIndexCoverage
    func releaseMemory() async
    func shutdown() async
}

/// Builds a runtime session for a verified installation. The Apple adapter compiles/loads the
/// CoreML package here (ANE-first compute policy); Core never sees CoreML.
public protocol MLSmartSearchRuntimeProvider: Sendable {
    /// May perform expensive one-time preparation (model compilation). Must throw rather than
    /// return a session whose encoder does not match `model.entry.descriptor`.
    ///
    /// - Parameters:
    ///   - shouldContinueIndexing: consulted at asset boundaries; indexing passes stop promptly
    ///     (after the current durable chunk) when it returns `false`.
    ///   - onIndexProgress: chunk-granular progress callback (already coalesced by chunk size).
    func makeSession(
        model: MLInstalledModel,
        store: any MLIndexStore,
        shouldContinueIndexing: @escaping @Sendable () -> Bool,
        onIndexProgress: @escaping @Sendable (MLIndexProgress) -> Void
    ) async throws -> any MLSmartSearchSession
}

/// Owns the persistent index store handle so the lifecycle can close it before purging files.
public protocol MLIndexStoreProvider: Sendable {
    /// Open (or return the already-open) store. Idempotent.
    func openStore() -> (any MLIndexStore)?
    /// Close the underlying handle so database files can be deleted safely.
    func closeStore()
}

/// Host-injected scheduling gate for background indexing. Capability-based: the platform maps
/// thermal state, low power, visible thumbnail demand and lifecycle phase into one answer.
public protocol MLIndexingGovernor: Sendable {
    func permitsIndexing() -> Bool
}

/// Trivially permissive governor for tests and previews.
public struct MLAlwaysPermitsIndexing: MLIndexingGovernor {
    public init() {}
    public func permitsIndexing() -> Bool { true }
}

/// Closure-backed governor so hosts can compose existing workload signals (thermal, low
/// power, visible thumbnail demand, app lifecycle) without a new type per platform.
public struct MLClosureIndexingGovernor: MLIndexingGovernor {
    private let permits: @Sendable () -> Bool

    public init(_ permits: @escaping @Sendable () -> Bool) {
        self.permits = permits
    }

    public func permitsIndexing() -> Bool { permits() }
}

// `search(_:limit:)`, `index(_:)` and `coverage(for:)` are satisfied by MLSearchService's
// existing API; only shutdown is new.
extension MLSearchService: MLSmartSearchSession {
    public func shutdown() async {
        await releaseMemory()
    }
}

/// Lazily opened, closable handle around the persistent SQLite index store.
public final class SQLiteMLIndexStoreProvider: MLIndexStoreProvider, @unchecked Sendable {
    private let url: URL
    private let policy: LibraryDatabasePolicy
    private let cipher: any MLVectorCipher
    private let lock = NSLock()
    private var store: SQLiteMLIndexStore?

    public init(url: URL, policy: LibraryDatabasePolicy = .conservative, cipher: any MLVectorCipher) {
        self.url = url
        self.policy = policy
        self.cipher = cipher
    }

    public func openStore() -> (any MLIndexStore)? {
        lock.withLock {
            if let store { return store }
            let opened = SQLiteMLIndexStore(url: url, policy: policy, cipher: cipher)
            store = opened
            return opened
        }
    }

    public func closeStore() {
        lock.withLock {
            store?.close()
            store = nil
        }
    }
}
