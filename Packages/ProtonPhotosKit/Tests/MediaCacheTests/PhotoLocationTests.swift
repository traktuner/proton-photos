import Testing
import Foundation
import CryptoKit
@testable import MediaCache
import PhotosCore

private func uid(_ n: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: n) }
private func coord(_ n: String, _ lat: Double, _ lon: Double) -> PhotoCoordinate {
    PhotoCoordinate(uid: uid(n), latitude: lat, longitude: lon, date: Date(timeIntervalSince1970: 0))
}
private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("loctest-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Suite struct PhotoLocationStoreTests {
    @Test func roundTripsEncryptedCoordinates() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let store = PhotoLocationStore(directory: dir)
        store.configure(accountUID: "acct", key: key)
        let coords = [coord("a", 47.8, 13.0), coord("b", 47.4, 12.5)]
        store.save(coords)

        let reopened = PhotoLocationStore(directory: dir)
        reopened.configure(accountUID: "acct", key: key)
        #expect(reopened.load() == coords)
    }

    @Test func onDiskBlobIsNeverPlaintext() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = PhotoLocationStore(directory: dir)
        store.configure(accountUID: "acct", key: SymmetricKey(size: .bits256))
        store.save([coord("secret", 47.812345, 13.044444)])

        let file = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        let bytes = try Data(contentsOf: file)
        #expect(!bytes.isEmpty)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("47.812345"))   // coordinate not in cleartext
    }

    @Test func wrongKeyOrAccountReadsEmpty() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = PhotoLocationStore(directory: dir)
        store.configure(accountUID: "acct", key: SymmetricKey(size: .bits256))
        store.save([coord("a", 47.8, 13.0)])

        let wrongKey = PhotoLocationStore(directory: dir)
        wrongKey.configure(accountUID: "acct", key: SymmetricKey(size: .bits256))
        #expect(wrongKey.load().isEmpty)

        let wrongAccount = PhotoLocationStore(directory: dir)
        wrongAccount.configure(accountUID: "other", key: SymmetricKey(size: .bits256))
        #expect(wrongAccount.load().isEmpty)
    }

    @Test func clearErasesTheBlob() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let store = PhotoLocationStore(directory: dir)
        store.configure(accountUID: "acct", key: key)
        store.save([coord("a", 47.8, 13.0)])
        store.clear()

        let reopened = PhotoLocationStore(directory: dir)
        reopened.configure(accountUID: "acct", key: key)
        #expect(reopened.load().isEmpty)
    }
}

@Suite @MainActor struct PhotoLocationIndexTests {
    @Test func mergeDedupsByUIDAndBumpsRevisionOnlyWhenChanged() {
        let index = PhotoLocationIndex()
        index.merge([coord("a", 1, 1), coord("b", 2, 2)])
        #expect(index.coordinates.count == 2)

        let r = index.revision
        index.merge([coord("a", 1, 1)])                 // pure duplicate
        #expect(index.coordinates.count == 2)
        #expect(index.revision == r)                    // no change ⇒ no view churn

        index.merge([coord("c", 3, 3)])
        #expect(index.coordinates.count == 3)
        #expect(index.revision == r + 1)
    }

    @Test func boundingBoxFiltersToVisibleRegion() {
        let index = PhotoLocationIndex()
        index.merge([coord("inside", 47.8, 13.0), coord("outside", 10.0, 10.0)])
        let box = GeoBoundingBox(minLatitude: 47, maxLatitude: 48, minLongitude: 12, maxLongitude: 14)
        let hits = index.coordinates(in: box)
        #expect(hits.map(\.uid) == [uid("inside")])
    }
}
