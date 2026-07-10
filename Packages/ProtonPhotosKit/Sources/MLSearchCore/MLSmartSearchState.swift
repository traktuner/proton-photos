import Foundation

/// A user-recoverable Smart Search failure. `isRetryable` gates the UI retry action.
public struct MLSmartSearchFailure: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case download
        case verification
        case installation
        case modelLoad
        case storage
    }

    public let kind: Kind
    public let isRetryable: Bool
    /// Diagnostic detail for logs; UI copy comes from the presentation layer per `kind`.
    public let debugDescription: String

    public init(kind: Kind, isRetryable: Bool, debugDescription: String) {
        self.kind = kind
        self.isRetryable = isRetryable
        self.debugDescription = debugDescription
    }
}

/// The one lifecycle phase machine every platform renders. UI never derives its own lifecycle.
public enum MLSmartSearchPhase: Sendable, Equatable {
    case disabled
    /// Enabled with a selected model whose artifacts are not installed (and, when
    /// `downloadable` is false, cannot be fetched automatically).
    case notInstalled(downloadable: Bool)
    case downloading(MLModelTransferProgress)
    case verifying
    case installing
    /// Model artifacts installed; the runtime session (CoreML compile/load) is being prepared.
    case preparingModel
    case indexing(MLIndexProgress)
    /// Installed and idle: indexing is either complete or waiting for resources/new assets.
    case ready(MLIndexCoverage)
    case switchingModel(to: MLModelID)
    case deleting
    case failed(MLSmartSearchFailure)

    public var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .installing, .preparingModel, .switchingModel, .deleting:
            return true
        case .disabled, .notInstalled, .indexing, .ready, .failed:
            return false
        }
    }
}

/// Full state snapshot emitted to hosts after every transition.
public struct MLSmartSearchSnapshot: Sendable, Equatable {
    public let isEnabled: Bool
    public let selectedModelID: MLModelID?
    public let phase: MLSmartSearchPhase
    /// Installed size of the active model in bytes (0 when nothing is installed).
    public let installedModelBytes: Int64
    /// Selectable catalog entries for this environment.
    public let availableModels: [MLModelCatalogEntry]
    /// `true` once queries are meaningful (enabled, model active, any coverage).
    public let isSearchAvailable: Bool

    public init(
        isEnabled: Bool,
        selectedModelID: MLModelID?,
        phase: MLSmartSearchPhase,
        installedModelBytes: Int64,
        availableModels: [MLModelCatalogEntry],
        isSearchAvailable: Bool
    ) {
        self.isEnabled = isEnabled
        self.selectedModelID = selectedModelID
        self.phase = phase
        self.installedModelBytes = installedModelBytes
        self.availableModels = availableModels
        self.isSearchAvailable = isSearchAvailable
    }

    public static let disabled = MLSmartSearchSnapshot(
        isEnabled: false,
        selectedModelID: nil,
        phase: .disabled,
        installedModelBytes: 0,
        availableModels: [],
        isSearchAvailable: false
    )
}

/// Journal marker for multi-step operations that must complete across a crash.
public enum MLSmartSearchPendingOperation: Sendable, Equatable, Codable {
    /// Purge started: every restart finishes the purge before anything else runs.
    case purge
    /// Model switch committed: the previous epoch's vectors and artifacts must be gone before
    /// the new model activates.
    case switchModel(from: MLModelID?, to: MLModelID)
}

/// Minimal persisted lifecycle state (crash recovery only — everything else is derived).
public struct MLSmartSearchPersistentState: Sendable, Equatable, Codable {
    public var isEnabled: Bool
    public var selectedModelID: MLModelID?
    /// Revision of the activated installation, so relaunches load exactly what was verified.
    public var activatedRevision: String?
    public var pendingOperation: MLSmartSearchPendingOperation?

    public init(
        isEnabled: Bool = false,
        selectedModelID: MLModelID? = nil,
        activatedRevision: String? = nil,
        pendingOperation: MLSmartSearchPendingOperation? = nil
    ) {
        self.isEnabled = isEnabled
        self.selectedModelID = selectedModelID
        self.activatedRevision = activatedRevision
        self.pendingOperation = pendingOperation
    }
}

/// Persistence seam for `MLSmartSearchPersistentState`.
public protocol MLSmartSearchStateStore: Sendable {
    func load() -> MLSmartSearchPersistentState?
    func save(_ state: MLSmartSearchPersistentState)
    /// Remove the persisted state entirely (final purge step).
    func clear()
}

/// Atomic JSON-file state store inside the Smart Search root (so purge provably removes it).
public struct FileMLSmartSearchStateStore: MLSmartSearchStateStore {
    private let fileURL: URL

    public init(layout: MLModelInstallLayout) {
        self.fileURL = layout.stateFileURL
    }

    public func load() -> MLSmartSearchPersistentState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(MLSmartSearchPersistentState.self, from: data)
    }

    public func save(_ state: MLSmartSearchPersistentState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
