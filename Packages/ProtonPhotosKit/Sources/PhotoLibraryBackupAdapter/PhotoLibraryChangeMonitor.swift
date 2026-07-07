import Foundation
import Photos

/// Incremental change tracking across launches (persistent change history) plus a live in-session
/// observer. The persistent token is PhotoKit-specific state, so it lives here in the adapter,
/// persisted as a secure-coded archive next to the account's backup stores.
public final class PhotoLibraryChangeMonitor: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {

    public struct ChangeSet: Sendable {
        /// Assets to (re)scan - inserted or updated.
        public var changedIdentifiers: [String]
        /// Assets deleted locally (backup never mirrors deletions; rows become source-missing
        /// lazily when work touches them).
        public var deletedIdentifiers: [String]
        /// The stored token no longer resolves (expired history / first run) - callers fall back
        /// to a full cheap rescan, which preflight keeps mostly read-only.
        public var requiresFullRescan: Bool
    }

    public struct PreparedChangeSet: @unchecked Sendable {
        public let changes: ChangeSet
        fileprivate let commitToken: PHPersistentChangeToken
    }

    private let tokenURL: URL
    private let lock = NSLock()
    private var onLibraryChange: (@Sendable () -> Void)?
    private var isObserving = false

    public init(tokenURL: URL) {
        self.tokenURL = tokenURL
        super.init()
    }

    deinit {
        if isObserving { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    /// Starts the in-session observer. `handler` fires (debounced by the caller) whenever the
    /// library changes while the app runs.
    public func startObserving(_ handler: @Sendable @escaping () -> Void) {
        lock.withLock {
            onLibraryChange = handler
            guard !isObserving else { return }
            isObserving = true
            PHPhotoLibrary.shared().register(self)
        }
    }

    public func stopObserving() {
        let shouldUnregister = lock.withLock {
            onLibraryChange = nil
            guard isObserving else { return false }
            isObserving = false
            return true
        }
        if shouldUnregister {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        lock.withLock { onLibraryChange }?()
    }

    /// Changes since the stored token. This deliberately does NOT advance the stored token. Callers
    /// must commit the returned value only after their durable scan/enqueue work succeeds.
    public func prepareChanges() -> PreparedChangeSet {
        let library = PHPhotoLibrary.shared()
        let currentToken = library.currentChangeToken

        guard let previous = loadToken() else {
            return PreparedChangeSet(
                changes: ChangeSet(changedIdentifiers: [], deletedIdentifiers: [], requiresFullRescan: true),
                commitToken: currentToken
            )
        }
        do {
            var changed: Set<String> = []
            var deleted: Set<String> = []
            for change in try library.fetchPersistentChanges(since: previous) {
                guard let details = try? change.changeDetails(for: .asset) else { continue }
                changed.formUnion(details.insertedLocalIdentifiers)
                changed.formUnion(details.updatedLocalIdentifiers)
                deleted.formUnion(details.deletedLocalIdentifiers)
            }
            changed.subtract(deleted)
            return PreparedChangeSet(
                changes: ChangeSet(
                    changedIdentifiers: Array(changed),
                    deletedIdentifiers: Array(deleted),
                    requiresFullRescan: false
                ),
                commitToken: currentToken
            )
        } catch {
            // Token expired or history unavailable - full cheap rescan is the documented fallback.
            return PreparedChangeSet(
                changes: ChangeSet(changedIdentifiers: [], deletedIdentifiers: [], requiresFullRescan: true),
                commitToken: currentToken
            )
        }
    }

    /// Advances the persistent token after the caller has durably handled the prepared changes.
    public func commit(_ prepared: PreparedChangeSet) {
        store(token: prepared.commitToken)
    }

    private func loadToken() -> PHPersistentChangeToken? {
        guard let data = try? Data(contentsOf: tokenURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }

    private func store(token: PHPersistentChangeToken) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { return }
        try? data.write(to: tokenURL, options: .atomic)
    }
}
