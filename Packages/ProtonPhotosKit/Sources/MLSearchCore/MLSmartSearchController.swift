import Foundation
import Observation
import PhotosCore

/// Owns the filesystem-access lifetime of a user-picked artifact URL. The default begins/ends
/// the URL's security scope; tests inject counters to prove the scope outlives the install.
public struct MLScopedArtifactAccess: Sendable {
    public let begin: @Sendable (URL) -> Bool
    public let end: @Sendable (URL) -> Void

    public init(begin: @escaping @Sendable (URL) -> Bool, end: @escaping @Sendable (URL) -> Void) {
        self.begin = begin
        self.end = end
    }

    public static let securityScoped = MLScopedArtifactAccess(
        begin: { $0.startAccessingSecurityScopedResource() },
        end: { $0.stopAccessingSecurityScopedResource() }
    )
}

/// Main-actor observation surface over `MLSmartSearchLifecycle` — the ONE settings view model
/// both platforms bind to. Views read published state and call intents; every decision stays
/// in the lifecycle actor, and no lifecycle work runs on the main actor (intents hop straight
/// into the actor).
@MainActor
@Observable
public final class MLSmartSearchController {
    public private(set) var snapshot: MLSmartSearchSnapshot = .disabled
    public private(set) var presentation = MLSmartSearchPresentation(snapshot: .disabled)

    @ObservationIgnored private let lifecycle: MLSmartSearchLifecycle
    @ObservationIgnored private let artifactAccess: MLScopedArtifactAccess
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    public init(lifecycle: MLSmartSearchLifecycle, artifactAccess: MLScopedArtifactAccess = .securityScoped) {
        self.lifecycle = lifecycle
        self.artifactAccess = artifactAccess
        observationTask = Task { [weak self, lifecycle] in
            await lifecycle.start()
            for await snapshot in await lifecycle.snapshots() {
                guard let self else { break }
                self.apply(snapshot)
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    private func apply(_ snapshot: MLSmartSearchSnapshot) {
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        self.presentation = MLSmartSearchPresentation(snapshot: snapshot)
    }

    // MARK: - Intents (fire-and-forget into the lifecycle actor)

    public func setEnabled(_ enabled: Bool) {
        Task { await lifecycle.setEnabled(enabled) }
    }

    public func select(_ id: MLModelID) {
        Task { await lifecycle.select(id) }
    }

    public func retry() {
        Task { await lifecycle.retry() }
    }

    public func disableAndPurge() {
        Task { await lifecycle.disableAndPurge() }
    }

    /// Install a developer-provided artifact from a user-picked URL. The controller — not any
    /// view — owns the filesystem-access lifetime: the security scope stays open until copy,
    /// validation and installation have fully completed inside the lifecycle actor.
    public func installDeveloperModel(from url: URL, for id: MLModelID) {
        let access = artifactAccess
        Task { [lifecycle] in
            let accessing = access.begin(url)
            defer { if accessing { access.end(url) } }
            await lifecycle.installDeveloperModel(from: url, for: id)
        }
    }

    public func noteLibraryChanged() {
        Task { await lifecycle.noteLibraryChanged() }
    }

    public func noteConditionsChanged() {
        Task { await lifecycle.noteConditionsChanged() }
    }

    /// The underlying lifecycle, for query coordination and host memory-pressure wiring.
    public nonisolated var lifecycleActor: MLSmartSearchLifecycle { lifecycle }
}

/// Debounced, epoch-safe semantic query pipeline for the timeline search field.
///
/// Feed it the raw search text; it publishes ranked UIDs (or `nil` when semantic search should
/// not filter — disabled, unavailable, empty query, or a failed query). Out-of-order and
/// stale-epoch responses are discarded, so a model switch can never surface old-epoch results.
@MainActor
@Observable
public final class MLSmartSearchQueryCoordinator {
    /// Ranked semantic result UIDs for the current query, best first. `nil` = no semantic
    /// filtering active.
    public private(set) var rankedUIDs: [PhotoUID]?
    public private(set) var isSearching = false

    @ObservationIgnored private let lifecycle: MLSmartSearchLifecycle
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let limit: Int
    @ObservationIgnored private var querySequence: UInt64 = 0
    @ObservationIgnored private var pendingTask: Task<Void, Never>?

    public init(lifecycle: MLSmartSearchLifecycle, debounce: Duration = .milliseconds(300), limit: Int = 400) {
        self.lifecycle = lifecycle
        self.debounce = debounce
        self.limit = limit
    }

    public func update(query: String) {
        pendingTask?.cancel()
        querySequence &+= 1
        let sequence = querySequence
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            rankedUIDs = nil
            isSearching = false
            return
        }

        isSearching = true
        pendingTask = Task { [lifecycle, debounce, limit] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let results = try? await lifecycle.search(trimmed, limit: limit)
            guard !Task.isCancelled, sequence == self.querySequence else { return }
            self.rankedUIDs = results.map { $0.results.map(\.uid) }
            self.isSearching = false
        }
    }

    public func clear() {
        pendingTask?.cancel()
        querySequence &+= 1
        rankedUIDs = nil
        isSearching = false
    }
}
