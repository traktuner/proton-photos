import Foundation
import Observation
import PhotosCore

/// Main-actor, observable façade the UI binds to. Mirrors the `UploadManager` actor's snapshots onto
/// the main thread and exposes the user-facing actions (choose destination, pause/resume/cancel/retry).
@MainActor
@Observable
public final class UploadCoordinator {
    public private(set) var items: [UploadItem] = []
    public private(set) var stats = UploadQueueStats()

    /// Albums offered in the destination picker (supplied by the app, which already loads them).
    public var albums: [PhotoAlbum] = []

    /// UI presentation flags.
    public var isQueueVisible = false
    public var isDestinationSheetPresented = false
    public private(set) var latestCompletedUpload: UploadCompletedEvent?
    public private(set) var completedUploadRevision = 0

    public let uploadCapabilities: UploadBackendCapabilities
    public let canCreateAlbum: Bool
    public let canAddToAlbum: Bool
    public let canSetAlbumCover: Bool

    private let manager: UploadManager
    private var pending: PendingSelection?

    private enum PendingSelection {
        case files([URL])
        case folder(URL)
    }

    public init(
        manager: UploadManager,
        uploadCapabilities: UploadBackendCapabilities,
        canCreateAlbum: Bool,
        canAddToAlbum: Bool,
        canSetAlbumCover: Bool
    ) {
        self.manager = manager
        self.uploadCapabilities = uploadCapabilities
        self.canCreateAlbum = canCreateAlbum
        self.canAddToAlbum = canAddToAlbum
        self.canSetAlbumCover = canSetAlbumCover
    }

    /// Begin streaming snapshots from the manager. Call once after construction.
    public func start() async {
        await manager.setOnChange { [weak self] items, stats in
            Task { @MainActor in
                self?.items = items
                self?.stats = stats
            }
        }
        await manager.setOnCompleted { [weak self] event in
            Task { @MainActor in
                self?.latestCompletedUpload = event
                self?.completedUploadRevision += 1
            }
        }
    }

    // MARK: - Destination flow

    public func chooseDestination(files: [URL]) {
        guard !files.isEmpty else { return }
        pending = .files(files)
        isDestinationSheetPresented = true
    }

    public func chooseDestination(folder: URL) {
        pending = .folder(folder)
        isDestinationSheetPresented = true
    }

    /// Confirm the destination sheet → enqueue the pending selection and reveal the queue.
    public func confirm(destination: UploadDestination) {
        let selection = pending
        pending = nil
        isDestinationSheetPresented = false
        guard let selection else { return }
        isQueueVisible = true
        Task {
            switch selection {
            case let .files(urls): await manager.enqueueFiles(urls, destination: destination)
            case let .folder(url): await manager.enqueueFolder(url, destination: destination)
            }
        }
    }

    public func cancelDestination() {
        pending = nil
        isDestinationSheetPresented = false
    }

    // MARK: - Queue item actions

    public func pause(_ id: UploadQueueItemID) { Task { await manager.pause(id) } }
    public func resume(_ id: UploadQueueItemID) { Task { await manager.resume(id) } }
    public func cancel(_ id: UploadQueueItemID) { Task { await manager.cancel(id) } }
    public func retry(_ id: UploadQueueItemID) { Task { await manager.retry(id) } }
    public func clearFinished() { Task { await manager.clearFinished() } }
}
