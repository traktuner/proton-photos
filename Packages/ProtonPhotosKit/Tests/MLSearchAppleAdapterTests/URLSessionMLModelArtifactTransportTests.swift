import Foundation
import Testing
@testable import MLSearchAppleAdapter

@Suite(.serialized) struct URLSessionMLModelArtifactTransportTests {
    private final class RangeProtocol: URLProtocol {
        nonisolated(unsafe) static var payload = Data()
        nonisolated(unsafe) static var requests: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            let bounds = range
                .replacingOccurrences(of: "bytes=", with: "")
                .split(separator: "-")
                .compactMap { Int($0) }
            guard bounds.count == 2 else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            let lower = bounds[0]
            let upper = min(bounds[1], Self.payload.count - 1)
            let body = Self.payload.subdata(in: lower..<(upper + 1))
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 206,
                httpVersion: nil,
                headerFields: [
                    "Content-Length": String(body.count),
                    "Content-Range": "bytes \(lower)-\(upper)/\(Self.payload.count)",
                ]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @Test func resumesFromPartialFileAndIdentifiesTheApp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-range-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("weights.partial")
        let payload = Data((0..<251).map(UInt8.init))
        try payload.prefix(37).write(to: destination)
        RangeProtocol.payload = payload
        RangeProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeProtocol.self]
        let transport = URLSessionMLModelArtifactTransport(session: URLSession(configuration: configuration))

        try await transport.download(
            from: URL(string: "https://models.oncloud.at/models/test/weights.bin")!,
            to: destination,
            expectedByteCount: Int64(payload.count),
            progress: { _, _ in }
        )

        #expect(try Data(contentsOf: destination) == payload)
        #expect(RangeProtocol.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=37-250")
        #expect(RangeProtocol.requests.allSatisfy {
            $0.value(forHTTPHeaderField: MLModelRequestIdentity.headerName) == MLModelRequestIdentity.appIdentifier
        })
    }
}
