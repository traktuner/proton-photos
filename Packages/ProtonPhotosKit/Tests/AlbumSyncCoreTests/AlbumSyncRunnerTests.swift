import Testing
import Foundation
import PhotosCore
import UploadCore
@testable import AlbumSyncCore

// MARK: - Fakes

private struct FakeLocalSource: AlbumSyncLocalAlbumSource {
    var albums: [LocalAlbumSummary] = []
    var contents: [String: [String]] = [:]

    func listAlbums() async throws -> [LocalAlbumSummary] { albums }
    func assetIdentifiers(albumID: String) async throws -> [String] { contents[albumID] ?? [] }
}

private final class FakeBackupExecutor: AlbumSyncBackupExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var _runs: [[String]] = []
    var runs: [[String]] { lock.withLock { _runs } }
    var stopped = false

    func ensureBackedUp(
        localIdentifiers: [String],
        onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async throws -> AlbumSyncBackupReport {
        lock.withLock { _runs.append(localIdentifiers) }
        var progress = BackupSyncProgress()
        progress.total = localIdentifiers.count
        progress.uploaded = localIdentifiers.count
        onProgress(progress)
        return AlbumSyncBackupReport(
            total: localIdentifiers.count, backedUp: localIdentifiers.count,
            failed: 0, sourceMissing: 0, skippedRemoteDeletion: 0
        )
    }

    func stop() async { lock.withLock { stopped = true } }
}

private final class FakeRemoteOps: AlbumSyncRemoteAlbumOps, @unchecked Sendable {
    private let lock = NSLock()
    var remoteAlbums: [AlbumSyncRemoteAlbum] = []
    var children: Set<String> = []
    var failAttachOf: Set<String> = []
    var alreadyMemberOf: Set<String> = []
    private var _created: [String] = []
    private var _attached: [[String]] = []
    var createdNames: [String] { lock.withLock { _created } }
    var attachedBatches: [[String]] { lock.withLock { _attached } }
    var nextAlbumID = "remote-album-1"

    func listAlbums() async throws -> [AlbumSyncRemoteAlbum] { remoteAlbums }

    func createAlbum(name: String) async throws -> String {
        lock.withLock { _created.append(name) }
        return nextAlbumID
    }

    func childMainLinkIDs(albumID: String) async throws -> Set<String> { children }

    func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult {
        lock.withLock { _attached.append(photos.map(\.uid.nodeID)) }
        var result = AlbumSyncAttachResult()
        for photo in photos {
            if failAttachOf.contains(photo.uid.nodeID) {
                result.failed += 1
                if result.firstFailureMessage == nil { result.firstFailureMessage = "attach failed" }
            } else if alreadyMemberOf.contains(photo.uid.nodeID) {
                result.alreadyMember += 1
            } else {
                result.attached += 1
            }
        }
        return result
    }
}

private final class FakeLinkLookup: AlbumSyncRemoteLinkLookup, @unchecked Sendable {
    var links: [String: AlbumSyncRemoteLink] = [:]
    func remoteLinks(for localIdentifiers: [String]) async -> [String: AlbumSyncRemoteLink] {
        links.filter { localIdentifiers.contains($0.key) }
    }
}

private func makeStore() -> AlbumSyncMappingStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("album-sync-tests-\(UUID().uuidString).sqlite")
    return AlbumSyncMappingStore(url: url)!
}

private func link(_ id: String, trashed: Bool = false) -> AlbumSyncRemoteLink {
    AlbumSyncRemoteLink(uid: PhotoUID(volumeID: "vol1", nodeID: id), sha1Hex: "aa", isTrashed: trashed)
}

// MARK: - Tests

@Suite struct AlbumSyncRunnerTests {

    private func makeRunner(
        contents: [String: [String]],
        links: [String: AlbumSyncRemoteLink],
        remote: FakeRemoteOps = FakeRemoteOps(),
        backup: FakeBackupExecutor = FakeBackupExecutor(),
        store: AlbumSyncMappingStore = makeStore()
    ) -> (AlbumSyncRunner, FakeRemoteOps, FakeBackupExecutor, AlbumSyncMappingStore) {
        let lookup = FakeLinkLookup()
        lookup.links = links
        let runner = AlbumSyncRunner(
            localSource: FakeLocalSource(albums: [], contents: contents),
            backup: backup,
            remoteOps: remote,
            linkLookup: lookup,
            mappingStore: store,
            attachChunkSize: 2
        )
        return (runner, remote, backup, store)
    }

    private let album = LocalAlbumSummary(id: "local-1", title: "Urlaub", assetCount: 3)

    @Test func firstSyncCreatesAlbumBacksUpAndAttaches() async throws {
        let (runner, remote, backup, store) = makeRunner(
            contents: ["local-1": ["a", "b", "c"]],
            links: ["a": link("l-a"), "b": link("l-b"), "c": link("l-c")]
        )
        let report = try await runner.sync(album: album)

        #expect(remote.createdNames == ["Urlaub"])
        #expect(backup.runs == [["a", "b", "c"]])
        #expect(remote.attachedBatches.flatMap(\.self) == ["l-a", "l-b", "l-c"])
        // Chunked by attachChunkSize = 2.
        #expect(remote.attachedBatches.map(\.count) == [2, 1])
        #expect(report.attached == 3)
        #expect(report.isFullySynced)
        let mapping = try #require(store.mapping(localAlbumID: "local-1"))
        #expect(mapping.remoteAlbumID == "remote-album-1")
        #expect(mapping.lastSyncedAt != nil)
        #expect(mapping.mode == .additive)
    }

    @Test func emptyLocalAlbumStillCreatesRemoteAlbum() async throws {
        let (runner, remote, _, store) = makeRunner(contents: ["local-1": []], links: [:])
        let report = try await runner.sync(album: LocalAlbumSummary(id: "local-1", title: "Leer", assetCount: 0))
        #expect(remote.createdNames == ["Leer"])
        #expect(remote.attachedBatches.isEmpty)
        #expect(report.isFullySynced)
        #expect(store.mapping(localAlbumID: "local-1") != nil)
    }

    @Test func repeatSyncReusesMappingAndDoesNoAttachWork() async throws {
        let store = makeStore()
        let (first, remoteA, _, _) = makeRunner(
            contents: ["local-1": ["a"]], links: ["a": link("l-a")], store: store
        )
        _ = try await first.sync(album: album)
        #expect(remoteA.createdNames == ["Urlaub"])

        // Second run: same store, remote album now contains l-a.
        let remoteB = FakeRemoteOps()
        remoteB.children = ["l-a"]
        let (second, _, backupB, _) = makeRunner(
            contents: ["local-1": ["a"]], links: ["a": link("l-a")], remote: remoteB, store: store
        )
        let report = try await second.sync(album: album)
        #expect(remoteB.createdNames.isEmpty)          // mapping reused, nothing created
        #expect(remoteB.attachedBatches.isEmpty)       // membership converged, no attach calls
        #expect(backupB.runs.count == 1)               // backup re-verifies (cheap preflight)
        #expect(report.alreadyMember == 1)
        #expect(report.isFullySynced)
    }

    @Test func unmappedNameTwinThrowsConflictInsteadOfGuessing() async throws {
        let remote = FakeRemoteOps()
        remote.remoteAlbums = [AlbumSyncRemoteAlbum(id: "existing-9", title: "Urlaub")]
        let (runner, _, _, store) = makeRunner(
            contents: ["local-1": ["a"]], links: ["a": link("l-a")], remote: remote
        )
        await #expect(throws: AlbumSyncError.nameConflict(existing: [AlbumSyncRemoteAlbum(id: "existing-9", title: "Urlaub")])) {
            try await runner.sync(album: album)
        }
        #expect(remote.createdNames.isEmpty)
        #expect(store.mapping(localAlbumID: "local-1") == nil)
    }

    @Test func explicitUseExistingAttachesToChosenAlbumAndPersistsMapping() async throws {
        let remote = FakeRemoteOps()
        remote.remoteAlbums = [AlbumSyncRemoteAlbum(id: "existing-9", title: "Urlaub")]
        let (runner, _, _, store) = makeRunner(
            contents: ["local-1": ["a"]], links: ["a": link("l-a")], remote: remote
        )
        let report = try await runner.sync(album: album, resolution: .attachToExisting(remoteAlbumID: "existing-9"))
        #expect(remote.createdNames.isEmpty)
        #expect(report.remoteAlbumID == "existing-9")
        #expect(store.mapping(localAlbumID: "local-1")?.remoteAlbumID == "existing-9")
    }

    @Test func attachFailuresSurfaceAsNeedsAttentionNotSuccess() async throws {
        let remote = FakeRemoteOps()
        remote.failAttachOf = ["l-b"]
        let (runner, _, _, _) = makeRunner(
            contents: ["local-1": ["a", "b"]],
            links: ["a": link("l-a"), "b": link("l-b")],
            remote: remote
        )
        var statuses: [AlbumSyncPhase] = []
        let box = ProgressBox()
        await runner.setOnProgress { box.append($0) }
        let report = try await runner.sync(album: album)
        statuses = box.snapshot().map(\.phase)
        #expect(report.attached == 1)
        #expect(report.attachFailed == 1)
        #expect(!report.isFullySynced)
        #expect(statuses.last == .needsAttention)
    }

    @Test func assetsWithoutRemoteLinkCountAsUnattachable() async throws {
        let (runner, remote, _, _) = makeRunner(
            contents: ["local-1": ["a", "b"]],
            links: ["a": link("l-a")]   // "b" never made it into the library
        )
        let report = try await runner.sync(album: album)
        #expect(remote.attachedBatches.flatMap(\.self) == ["l-a"])
        #expect(report.unattachable == 1)
        #expect(!report.isFullySynced)
    }

    @Test func trashedRemoteCopyIsRespectedNotAttached() async throws {
        let (runner, remote, _, _) = makeRunner(
            contents: ["local-1": ["a", "b"]],
            links: ["a": link("l-a"), "b": link("l-b", trashed: true)]
        )
        let report = try await runner.sync(album: album)
        #expect(remote.attachedBatches.flatMap(\.self) == ["l-a"])
        #expect(report.trashedSkipped == 1)
        #expect(report.isFullySynced)   // intentional user state, not an error
    }

    @Test func samePhotoInSecondAlbumOnlyAttachesNoNewUpload() async throws {
        let store = makeStore()
        let (first, _, _, _) = makeRunner(
            contents: ["local-1": ["a"], "local-2": ["a"]], links: ["a": link("l-a")], store: store
        )
        _ = try await first.sync(album: album)

        let remoteB = FakeRemoteOps()
        remoteB.nextAlbumID = "remote-album-2"
        let (second, _, backupB, _) = makeRunner(
            contents: ["local-1": ["a"], "local-2": ["a"]], links: ["a": link("l-a")], remote: remoteB, store: store
        )
        let report = try await second.sync(album: LocalAlbumSummary(id: "local-2", title: "Zweites", assetCount: 1))
        #expect(remoteB.createdNames == ["Zweites"])
        #expect(remoteB.attachedBatches == [["l-a"]])
        #expect(backupB.runs == [["a"]])    // backup step re-verifies via preflight, uploads nothing
        #expect(report.attached == 1)
    }

    @Test func secondSyncWhileRunningThrowsAlreadyRunning() async throws {
        let gate = Gate()
        let backup = GatedBackupExecutor(gate: gate)
        let lookup = FakeLinkLookup()
        lookup.links = ["a": link("l-a")]
        let runner = AlbumSyncRunner(
            localSource: FakeLocalSource(albums: [], contents: ["local-1": ["a"]]),
            backup: backup,
            remoteOps: FakeRemoteOps(),
            linkLookup: lookup,
            mappingStore: makeStore()
        )
        let albumToSync = album
        let first = Task { try await runner.sync(album: albumToSync) }
        // Deterministic: wait until the first run is parked inside the backup phase.
        while await runner.currentProgress.phase != .backingUp { await Task.yield() }
        await #expect(throws: AlbumSyncError.alreadyRunning) {
            try await runner.sync(album: albumToSync)
        }
        await gate.open()
        _ = try await first.value
    }
}

/// Suspends backup until the test opens the gate - lets tests pin "while a sync is running" states.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

private struct GatedBackupExecutor: AlbumSyncBackupExecuting {
    let gate: Gate
    func ensureBackedUp(
        localIdentifiers: [String],
        onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async throws -> AlbumSyncBackupReport {
        await gate.wait()
        return AlbumSyncBackupReport(
            total: localIdentifiers.count, backedUp: localIdentifiers.count,
            failed: 0, sourceMissing: 0, skippedRemoteDeletion: 0
        )
    }
    func stop() async {}
}

/// Order-preserving, thread-safe progress recorder for callback assertions.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AlbumSyncProgress] = []
    func append(_ p: AlbumSyncProgress) { lock.withLock { items.append(p) } }
    func snapshot() -> [AlbumSyncProgress] { lock.withLock { items } }
}

@Suite struct AlbumSyncMappingStoreTests {
    @Test func selectionRoundTripKeepsMappingOnDeselect() throws {
        let store = makeStore()
        store.addSelection(AlbumSyncSelection(localAlbumID: "L1", title: "Urlaub", addedAt: Date(timeIntervalSinceReferenceDate: 10)))
        store.addSelection(AlbumSyncSelection(localAlbumID: "L2", title: "Anna", addedAt: Date(timeIntervalSinceReferenceDate: 20)))
        #expect(store.selections().map(\.localAlbumID) == ["L2", "L1"])   // title-ordered

        // Re-adding updates the stored title (album renamed locally).
        store.addSelection(AlbumSyncSelection(localAlbumID: "L1", title: "Urlaub 2026", addedAt: Date(timeIntervalSinceReferenceDate: 30)))
        #expect(store.selections().first(where: { $0.localAlbumID == "L1" })?.title == "Urlaub 2026")

        // Deselecting removes ONLY the selection - the album mapping survives, so re-selecting
        // later reuses the same Proton album without a conflict round.
        store.upsert(AlbumSyncMapping(
            localAlbumID: "L1", remoteAlbumID: "R1", title: "Urlaub 2026",
            createdAt: Date(timeIntervalSinceReferenceDate: 10)
        ))
        store.removeSelection(localAlbumID: "L1")
        #expect(store.selections().map(\.localAlbumID) == ["L2"])
        #expect(store.mapping(localAlbumID: "L1")?.remoteAlbumID == "R1")
    }

    @Test func upsertReadRemoveRoundTrip() throws {
        let store = makeStore()
        let mapping = AlbumSyncMapping(
            localAlbumID: "L1", remoteAlbumID: "R1", title: "Urlaub",
            createdAt: Date(timeIntervalSinceReferenceDate: 1000),
            lastSyncedAt: Date(timeIntervalSinceReferenceDate: 2000),
            lastAttachedCount: 5, lastFailedCount: 1
        )
        store.upsert(mapping)
        let loaded = try #require(store.mapping(localAlbumID: "L1"))
        #expect(loaded == mapping)

        var updated = mapping
        updated.lastAttachedCount = 9
        store.upsert(updated)
        #expect(store.mapping(localAlbumID: "L1")?.lastAttachedCount == 9)
        #expect(store.allMappings().count == 1)

        store.removeMapping(localAlbumID: "L1")
        #expect(store.mapping(localAlbumID: "L1") == nil)
    }
}
