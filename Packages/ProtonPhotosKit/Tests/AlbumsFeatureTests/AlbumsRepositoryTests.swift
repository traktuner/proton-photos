import XCTest
import PhotosCore
@testable import AlbumsFeature

/// A configurable in-memory backend so the repository's validation + capability gating can be tested
/// without any SDK/HTTP.
final class FakeAlbumBackend: AlbumBackend, @unchecked Sendable {
    var capabilities: AlbumCapabilities
    private(set) var created: [String] = []
    private(set) var added: [(uids: [PhotoUID], album: AlbumID)] = []
    private(set) var covers: [(album: AlbumID, photo: PhotoUID)] = []
    var albums: [AlbumSummary]

    init(capabilities: AlbumCapabilities, albums: [AlbumSummary] = []) {
        self.capabilities = capabilities
        self.albums = albums
    }

    func listAlbums() async throws -> [AlbumSummary] { albums }

    func createAlbum(name: String) async throws -> AlbumID {
        let id = "album-\(created.count)"
        created.append(name)
        return id
    }

    func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws {
        added.append((photoUIDs, albumID))
    }

    func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws {
        covers.append((albumID, photoUID))
    }
}

private func uid(_ n: String) -> PhotoUID { PhotoUID(volumeID: "vol", nodeID: n) }

final class AlbumsRepositoryTests: XCTestCase {

    func testListPassesThroughWhenSupported() async throws {
        let backend = FakeAlbumBackend(capabilities: .init(canList: true, canCreate: false, canAddPhotos: false, canSetCover: false),
                                       albums: [AlbumSummary(id: "a", title: "Trip", photoCount: 3, coverPhotoID: nil)])
        let repo = AlbumsRepository(backend: backend)
        let albums = try await repo.listAlbums()
        XCTAssertEqual(albums.map(\.id), ["a"])
    }

    func testCreateThrowsUnsupportedWhenBackendCannot() async {
        let backend = FakeAlbumBackend(capabilities: .readOnly)
        let repo = AlbumsRepository(backend: backend)
        do {
            _ = try await repo.createAlbum(name: "New")
            XCTFail("expected unsupported")
        } catch let AlbumError.unsupported(operation, _) {
            XCTAssertEqual(operation, "Create album")
        } catch { XCTFail("wrong error: \(error)") }
        XCTAssertTrue(backend.created.isEmpty, "must not have created anything")
    }

    func testCreateRejectsEmptyName() async {
        let backend = FakeAlbumBackend(capabilities: .init(canList: true, canCreate: true, canAddPhotos: true, canSetCover: true))
        let repo = AlbumsRepository(backend: backend)
        do { _ = try await repo.createAlbum(name: "   "); XCTFail("expected error") }
        catch { /* ok */ }
        XCTAssertTrue(backend.created.isEmpty)
    }

    func testCreateSucceedsAndForwardsTrimmedName() async throws {
        let backend = FakeAlbumBackend(capabilities: .init(canList: true, canCreate: true, canAddPhotos: true, canSetCover: true))
        let repo = AlbumsRepository(backend: backend)
        let id = try await repo.createAlbum(name: "  Holiday  ")
        XCTAssertEqual(id, "album-0")
        XCTAssertEqual(backend.created, ["Holiday"])
    }

    func testAddPhotosUnsupportedDoesNotCallBackend() async {
        let backend = FakeAlbumBackend(capabilities: .readOnly)
        let repo = AlbumsRepository(backend: backend)
        do { try await repo.addPhotos([uid("1")], to: "a"); XCTFail("expected unsupported") }
        catch let AlbumError.unsupported(operation, _) { XCTAssertEqual(operation, "Add to album") }
        catch { XCTFail("wrong error: \(error)") }
        XCTAssertTrue(backend.added.isEmpty)
    }

    func testSetCoverForwardsWhenSupported() async throws {
        let backend = FakeAlbumBackend(capabilities: .init(canList: true, canCreate: true, canAddPhotos: true, canSetCover: true))
        let repo = AlbumsRepository(backend: backend)
        try await repo.setAlbumCover(albumID: "a", photoUID: uid("9"))
        XCTAssertEqual(backend.covers.count, 1)
        XCTAssertEqual(backend.covers.first?.album, "a")
    }
}
