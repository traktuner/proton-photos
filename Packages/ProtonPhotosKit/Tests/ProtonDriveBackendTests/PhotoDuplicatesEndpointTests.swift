import Testing
import Foundation
import ProtonAuth
@testable import ProtonDriveBackend

private func makeSession() -> DriveSession {
    DriveSession(
        session: ProtonSession(uid: "test-uid", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
        store: SessionKeychainStore(service: "me.protonphotos.tests.never-used"),
        accountCacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("dedupe-endpoint-tests-\(UUID().uuidString)"),
        urlProtocolClasses: [StubURLProtocol.self]
    )
}

extension DriveSessionStubSuite {
/// Nested under the serialized stub parent: the URLProtocol stub's route table is process-global.
@Suite struct PhotoDuplicatesEndpointTests {

    @Test func postsNameHashesToVolumeDuplicatesEndpoint() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.route("POST /drive/volumes/vol1/photos/duplicates", json: #"""
        {"Code":1000,"DuplicateHashes":[]}
        """#)

        let entries = try await makeSession().findPhotoDuplicates(volumeID: "vol1", nameHashes: ["aa", "bb"])

        #expect(entries.isEmpty)
        let requests = StubURLProtocol.requests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/drive/volumes/vol1/photos/duplicates")
        let body = try #require(request.body)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["NameHashes"] as? [String] == ["aa", "bb"])
    }

    @Test func decodesAllLinkStatesAndOptionalFields() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.route("POST /drive/volumes/vol1/photos/duplicates", json: #"""
        {"Code":1000,"DuplicateHashes":[
            {"Hash":"h1","ContentHash":"c1","LinkState":1,"ClientUID":"client-a","LinkID":"l1"},
            {"Hash":"h2","ContentHash":null,"LinkState":0,"ClientUID":null,"LinkID":"l2"},
            {"Hash":"h3","ContentHash":"c3","LinkState":2,"LinkID":"l3"},
            {"Hash":"h4","ContentHash":"c4","LinkID":null}
        ]}
        """#)

        let entries = try await makeSession().findPhotoDuplicates(volumeID: "vol1", nameHashes: ["h1", "h2", "h3", "h4"])

        #expect(entries.count == 4)
        #expect(entries[0].hash == "h1")
        #expect(entries[0].contentHash == "c1")
        #expect(entries[0].linkState == 1)
        #expect(entries[0].clientUID == "client-a")
        #expect(entries[0].linkID == "l1")
        #expect(entries[1].linkState == 0)
        #expect(entries[1].contentHash == nil)
        #expect(entries[2].linkState == 2)
        #expect(entries[3].linkState == nil, "absent LinkState (deleted) must decode as nil")
        #expect(entries[3].linkID == nil)
    }

    @Test func emptyHashListNeverHitsTheNetwork() async throws {
        StubURLProtocol.reset()
        let entries = try await makeSession().findPhotoDuplicates(volumeID: "vol1", nameHashes: [])
        #expect(entries.isEmpty)
        #expect(StubURLProtocol.requests().isEmpty)
    }

    @Test func missingDuplicateHashesKeyDecodesAsEmpty() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.route("POST /drive/volumes/vol1/photos/duplicates", json: #"{"Code":1000}"#)
        let entries = try await makeSession().findPhotoDuplicates(volumeID: "vol1", nameHashes: ["aa"])
        #expect(entries.isEmpty)
    }
}
}

struct ProtonPhotoHMACTests {

    /// RFC 4231 test case 2 - proves the HMAC-SHA256 construction and the lowercase-hex output
    /// against an external vector (not our own implementation).
    @Test func matchesRFC4231Vector() {
        let hex = ProtonPhotoHMAC.hex(
            message: "what do ya want for nothing?",
            key: Data("Jefe".utf8)
        )
        #expect(hex == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    /// The HMAC key is the UTF-8 bytes of the decrypted hash-key STRING (Proton feeds the base64
    /// text, not decoded bytes) - two different key strings must produce different hashes.
    @Test func keyBytesAreTheKeyStringUTF8() {
        let message = "IMG_0001.HEIC"
        let a = ProtonPhotoHMAC.hex(message: message, key: Data("key-a".utf8))
        let b = ProtonPhotoHMAC.hex(message: message, key: Data("key-b".utf8))
        #expect(a != b)
        #expect(a == ProtonPhotoHMAC.hex(message: message, key: Data("key-a".utf8)))
    }
}
