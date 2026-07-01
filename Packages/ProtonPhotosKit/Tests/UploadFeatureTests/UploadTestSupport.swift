import Foundation
import XCTest
import PhotosCore
@testable import UploadCore

func testUID(_ name: String) -> PhotoUID { PhotoUID(volumeID: "vol", nodeID: "node-\(name)") }

/// In-memory `PhotoUploading` for exercising the queue/state-machine without any SDK. Tracks
/// concurrency, start order, and control-plane calls; can fail named files and deliver phase progress.
final class MockUploader: PhotoUploading, @unchecked Sendable {
    let capabilities: UploadBackendCapabilities

    private let lock = NSLock()
    private var concurrent = 0
    private var _peakConcurrent = 0
    private var _startedOrder: [String] = []
    private var _cancelledTokens: [UUID] = []
    private var _pausedTokens: [UUID] = []
    private var _resumedTokens: [UUID] = []
    private var transientFailures: [String: Int]   // name → number of initial attempts to fail

    private let workDuration: Duration
    private let deliverProgress: Bool
    private let failNames: Set<String>

    init(
        capabilities: UploadBackendCapabilities = .init(canUpload: true, supportsCancel: true,
                                                        supportsPauseResume: true, supportsResumeAcrossRelaunch: false),
        workDuration: Duration = .milliseconds(20),
        deliverProgress: Bool = true,
        failNames: Set<String> = [],
        transientFailures: [String: Int] = [:]
    ) {
        self.capabilities = capabilities
        self.workDuration = workDuration
        self.deliverProgress = deliverProgress
        self.failNames = failNames
        self.transientFailures = transientFailures
    }

    var peakConcurrent: Int { lock.withLock { _peakConcurrent } }
    var startedOrder: [String] { lock.withLock { _startedOrder } }
    var cancelledTokens: [UUID] { lock.withLock { _cancelledTokens } }

    func upload(_ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void) async throws -> PhotoUID {
        lock.withLock {
            concurrent += 1
            _peakConcurrent = max(_peakConcurrent, concurrent)
            _startedOrder.append(request.name)
        }
        defer { lock.withLock { concurrent -= 1 } }

        if deliverProgress {
            onProgress(UploadProgress(phase: .preparing))
            try await Task.sleep(for: .milliseconds(6))
            onProgress(UploadProgress(phase: .hashing))
            try await Task.sleep(for: .milliseconds(6))
            onProgress(UploadProgress(phase: .uploading, fraction: 0.5))
            try await Task.sleep(for: .milliseconds(6))
            onProgress(UploadProgress(phase: .uploading, fraction: 1.0))
            try await Task.sleep(for: .milliseconds(20))
        } else {
            try await Task.sleep(for: workDuration)
        }

        let transient: Int = lock.withLock {
            let t = transientFailures[request.name] ?? 0
            if t > 0 { transientFailures[request.name] = t - 1 }
            return t
        }
        if transient > 0 { throw UploadError.backend("transient failure for \(request.name)") }
        if failNames.contains(request.name) { throw UploadError.backend("mock failure for \(request.name)") }
        return testUID(request.name)
    }

    func cancel(token: UUID) async { lock.withLock { _cancelledTokens.append(token) } }
    func pause(token: UUID) async throws { lock.withLock { _pausedTokens.append(token) } }
    func resume(token: UUID) async throws { lock.withLock { _resumedTokens.append(token) } }
}

/// In-memory `AlbumAttaching`. Resolves/creates albums and records adds/covers; can fail the add step
/// to exercise partial-success handling.
final class MockAlbumAttaching: AlbumAttaching, @unchecked Sendable {
    private let lock = NSLock()
    let canCreate: Bool
    let canAdd: Bool
    let failAdd: Bool
    private var _createdNames: [String] = []
    private var _added: [(PhotoUID, String)] = []
    private var _covers: [(String, PhotoUID)] = []

    init(canCreate: Bool = true, canAdd: Bool = true, failAdd: Bool = false) {
        self.canCreate = canCreate
        self.canAdd = canAdd
        self.failAdd = failAdd
    }

    func resolveAlbum(for target: UploadDestination.Target) async throws -> String? {
        switch target {
        case .library:
            return nil
        case let .existingAlbum(id, _):
            guard canAdd else { throw UploadError.albumStep("add unsupported") }
            return id
        case let .newAlbum(name):
            guard canCreate else { throw UploadError.albumStep("create unsupported") }
            let n = lock.withLock { _createdNames.append(name); return _createdNames.count }
            return "new-album-\(n)"
        }
    }

    func addPhoto(_ uid: PhotoUID, to albumID: String) async throws {
        if failAdd { throw UploadError.backend("album add failed") }
        lock.withLock { _added.append((uid, albumID)) }
    }

    func setCover(albumID: String, photo: PhotoUID) async throws {
        lock.withLock { _covers.append((albumID, photo)) }
    }

    var createdNames: [String] { lock.withLock { _createdNames } }
    var addedSnapshot: [(PhotoUID, String)] { lock.withLock { _added } }
    var coversSnapshot: [(String, PhotoUID)] { lock.withLock { _covers } }
}

/// Records every state each item passes through (deduping consecutive repeats) for state-machine assertions.
final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sequences: [UploadQueueItemID: [UploadItemState]] = [:]

    func record(_ items: [UploadItem]) {
        lock.withLock {
            for item in items {
                var seq = sequences[item.id] ?? []
                if seq.last != item.state { seq.append(item.state) }
                sequences[item.id] = seq
            }
        }
    }

    func sequence(_ id: UploadQueueItemID) -> [UploadItemState] {
        lock.withLock { sequences[id] ?? [] }
    }
}

final class UploadCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [UploadCompletedEvent] = []

    func record(_ event: UploadCompletedEvent) {
        lock.withLock { _events.append(event) }
    }

    var events: [UploadCompletedEvent] {
        lock.withLock { _events }
    }
}

// MARK: - Polling helpers

extension XCTestCase {
    /// Polls `manager.snapshot()` until `predicate` holds or the timeout elapses.
    @discardableResult
    func waitUntil(
        _ manager: UploadManager,
        timeout: Duration = .seconds(5),
        _ predicate: @escaping @Sendable ([UploadItem]) -> Bool
    ) async -> [UploadItem] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let snap = await manager.snapshot()
            if predicate(snap) { return snap }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await manager.snapshot()
    }

    @discardableResult
    func waitForAllTerminal(_ manager: UploadManager, timeout: Duration = .seconds(5)) async -> [UploadItem] {
        await waitUntil(manager, timeout: timeout) { items in
            !items.isEmpty && items.allSatisfy { $0.state.isTerminal }
        }
    }
}

/// Creates `count` tiny real files with the given names in a fresh temp dir; returns their URLs.
func makeTempFiles(_ names: [String], in dir: URL) throws -> [URL] {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try names.map { name in
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }
}
