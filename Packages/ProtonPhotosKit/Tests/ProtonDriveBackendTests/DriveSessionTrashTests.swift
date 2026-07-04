import Testing
import Foundation
import ProtonAuth
@testable import ProtonDriveBackend

/// URLProtocol stub for `DriveSession`'s test seam: serves canned JSON per (method, path) and records
/// every request (method, path+query, body) for assertions. State is static because URLSession
/// instantiates the protocol itself - each test resets it via `reset()`.
final class StubURLProtocol: URLProtocol {
    struct Recorded: Sendable {
        let method: String
        let path: String        // path + query
        let body: Data?
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) private static var recorded: [Recorded] = []

    static func reset() {
        lock.withLock { routes = [:]; recorded = [] }
    }

    /// Register a canned response for "METHOD /path" (path WITHOUT query - matching ignores the query).
    static func route(_ methodAndPath: String, status: Int = 200, json: String) {
        lock.withLock { routes[methodAndPath] = (status, json) }
    }

    static func requests() -> [Recorded] {
        lock.withLock { recorded }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let url = request.url!
        let pathAndQuery = url.path + (url.query.map { "?\($0)" } ?? "")
        let body = Self.drainBody(of: request)
        Self.lock.withLock {
            Self.recorded.append(Recorded(method: method, path: pathAndQuery, body: body))
        }
        let match = Self.lock.withLock { Self.routes["\(method) \(url.path)"] }
        let (status, payload) = match ?? (404, #"{"Code":404,"Error":"no stub route"}"#)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession exposes POST bodies to URLProtocol as a stream, not `httpBody`.
    private static func drainBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private func makeSession() -> DriveSession {
    DriveSession(
        session: ProtonSession(uid: "test-uid", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
        store: SessionKeychainStore(service: "me.protonphotos.tests.never-used"),
        accountCacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("drive-session-tests-\(UUID().uuidString)"),
        urlProtocolClasses: [StubURLProtocol.self]
    )
}

private func linkIDs(inBodyOf request: StubURLProtocol.Recorded) throws -> [String] {
    let body = try #require(request.body)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    return try #require(json["LinkIDs"] as? [String])
}

/// These tests are serialized because the URLProtocol stub's route table is process-global.
@Suite(.serialized) struct DriveSessionTrashTests {
    @Test func trashPostsLinkIDsToV2VolumeTrashMultiple() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.route("POST /drive/v2/volumes/vol1/trash_multiple", json: #"""
        {"Code":1001,"Responses":[
            {"LinkID":"l1","Response":{"Code":1000}},
            {"LinkID":"l2","Response":{"Code":1000}}
        ]}
        """#)

        try await makeSession().trash(volumeID: "vol1", linkIDs: ["l1", "l2"])

        let requests = StubURLProtocol.requests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/drive/v2/volumes/vol1/trash_multiple")
        #expect(try linkIDs(inBodyOf: request) == ["l1", "l2"])
    }

    @Test func trashThrowsWhenAnyItemFailsInTheMultistatusBody() async throws {
        // The API answers HTTP 200 even when items fail - the failure is ONLY in the body. Swallowing it
        // is the "photo disappears but never reaches Recently Deleted" bug.
        StubURLProtocol.reset()
        StubURLProtocol.route("POST /drive/v2/volumes/vol1/trash_multiple", json: #"""
        {"Code":1001,"Responses":[
            {"LinkID":"ok","Response":{"Code":1000}},
            {"LinkID":"bad","Response":{"Code":2501,"Error":"Insufficient permissions"}}
        ]}
        """#)

        await #expect(throws: DriveBatchActionError.self) {
            try await makeSession().trash(volumeID: "vol1", linkIDs: ["ok", "bad"])
        }
    }

    @Test func restorePutsLinkIDsToRestoreMultiple() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.route("PUT /drive/v2/volumes/vol1/trash/restore_multiple", json: #"""
        {"Code":1001,"Responses":[{"LinkID":"l1","Response":{"Code":1000}}]}
        """#)

        try await makeSession().restore(volumeID: "vol1", linkIDs: ["l1"])

        let request = try #require(StubURLProtocol.requests().first)
        #expect(request.method == "PUT")
        #expect(request.path == "/drive/v2/volumes/vol1/trash/restore_multiple")
        #expect(try linkIDs(inBodyOf: request) == ["l1"])
    }

    @Test func listTrashResolvesIdGroupsViaFetchMetadata() async throws {
        // The volume trash listing returns ONLY {ShareID, LinkIDs} groups. Decoding `Links` from it
        // (the old DTO) yields nil → an always-empty Recently Deleted. The real link bodies come from
        // the per-share fetch_metadata batch.
        StubURLProtocol.reset()
        StubURLProtocol.route("GET /drive/volumes/vol1/trash", json: #"""
        {"Code":1000,"Trash":[
            {"ShareID":"share1","LinkIDs":["photo1","video-of-live","album1"],"ParentIDs":["root"]}
        ]}
        """#)
        // Realistic LinkMeta bodies: a still photo (capture time on the revision), a Live Photo's paired
        // video (MainPhotoLinkID set), and a trashed album (Type 3).
        StubURLProtocol.route("POST /drive/shares/share1/links/fetch_metadata", json: #"""
        {"Code":1000,"Links":[
            {"LinkID":"photo1","ParentLinkID":"root","Type":2,"Name":"x","MIMEType":"image/heic",
             "CreateTime":1700000000,"Size":123,
             "FileProperties":{"ContentKeyPacket":"ckp","ActiveRevision":{"ID":"rev1",
                "Photo":{"LinkID":"photo1","CaptureTime":1600000000,"MainPhotoLinkID":null,
                         "RelatedPhotosLinkIDs":["video-of-live"],"Exif":null}}},
             "PhotoProperties":{"Albums":[],"Tags":[3]}},
            {"LinkID":"video-of-live","ParentLinkID":"root","Type":2,"MIMEType":"video/quicktime",
             "CreateTime":1700000001,
             "FileProperties":{"ContentKeyPacket":"ckp","ActiveRevision":{"ID":"rev2",
                "Photo":{"LinkID":"video-of-live","CaptureTime":1600000000,"MainPhotoLinkID":"photo1"}}}},
            {"LinkID":"album1","Type":3,"Name":"y"}
        ]}
        """#)

        let links = try await makeSession().listTrash(volumeID: "vol1")

        #expect(links.count == 3)
        let photo = try #require(links.first { $0.linkID == "photo1" })
        #expect(photo.type == 2)
        #expect(photo.mimeType == "image/heic")
        #expect(photo.captureTime == 1_600_000_000)          // revision Photo.CaptureTime, not CreateTime
        #expect(photo.mainPhotoLinkID == nil)
        let liveVideo = try #require(links.first { $0.linkID == "video-of-live" })
        #expect(liveVideo.mainPhotoLinkID == "photo1")       // lets the bridge hide it, like the timeline
        let album = try #require(links.first { $0.linkID == "album1" })
        #expect(album.type == 3)
        #expect(album.captureTime == 0)                      // tolerant: no CreateTime, no crash

        let paths = StubURLProtocol.requests().map(\.path)
        #expect(paths.first?.hasPrefix("/drive/volumes/vol1/trash?Page=0") == true)
        #expect(paths.contains("/drive/shares/share1/links/fetch_metadata"))
    }

    @Test func listTrashEmptyVolumeYieldsNoLinksAndNoMetadataCall() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.route("GET /drive/volumes/vol1/trash", json: #"{"Code":1000,"Trash":[]}"#)

        let links = try await makeSession().listTrash(volumeID: "vol1")

        #expect(links.isEmpty)
        #expect(StubURLProtocol.requests().count == 1, "no fetch_metadata call for an empty trash")
    }

    @Test func trashLinkDecodeToleratesSparseEntries() throws {
        // Per-item sparseness must never fail the whole listing (the old "Recently Deleted couldn't
        // load" failure mode).
        let json = #"{"Links":[{"LinkID":"only-id"},{"Type":2},{}]}"#
        struct Wrapper: Decodable {
            let links: [TrashLink]
            enum CodingKeys: String, CodingKey { case links = "Links" }
        }
        let decoded = try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8))
        #expect(decoded.links.count == 3)
        #expect(decoded.links[0].linkID == "only-id")
        #expect(decoded.links[1].type == 2)
        #expect(decoded.links[2].captureTime == 0)
    }
}
