import CryptoKit
import Foundation
import MLSearchCore
import Testing
@testable import MLSearchAppleAdapter

@Suite(.serialized) struct SignedRemoteMLModelCatalogProviderTests {
    private final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var responses: [URL: Data] = [:]
        nonisolated(unsafe) static var requests: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
            guard let url = request.url, let data = Self.responses[url] else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": String(data.count)]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @Test func verifiesSignatureResolvesTrustedModelAndFallsBackToVerifiedCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("signed-model-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogURL = URL(string: "https://catalog.test/catalog-v1.json")!
        let signatureURL = URL(string: "https://catalog.test/catalog-v1.sig")!
        let artifactBaseURL = URL(string: "https://catalog.test/models/")!
        let artifactURL = artifactBaseURL.appendingPathComponent("tiny/rev/TinyCLIP.mlmodelc/weights.bin")
        let document = MLRemoteModelCatalogDocument(models: [
            .init(id: MLModelCatalogEntry.tinyCLIPVit40M.id, revision: "rev", artifacts: [
                .init(
                    path: "TinyCLIP.mlmodelc/weights.bin",
                    url: artifactURL,
                    sha256: String(repeating: "a", count: 64),
                    bytes: 123
                ),
            ]),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let documentData = try encoder.encode(document)
        let key = Curve25519.Signing.PrivateKey()
        StubProtocol.responses = [
            catalogURL: documentData,
            signatureURL: try key.signature(for: documentData),
        ]
        StubProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let provider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: .builtIn,
            cacheDirectory: root,
            session: URLSession(configuration: configuration),
            catalogURL: catalogURL,
            signatureURL: signatureURL,
            artifactBaseURL: artifactBaseURL,
            publicKey: key.publicKey.rawRepresentation
        )

        let remote = try await provider.catalog()
        #expect(remote.entry(for: MLModelCatalogEntry.tinyCLIPVit40M.id)?.downloadPlan?.totalByteCount == 123)
        #expect(StubProtocol.requests.count == 2)
        #expect(StubProtocol.requests.allSatisfy {
            $0.value(forHTTPHeaderField: MLModelRequestIdentity.headerName) == MLModelRequestIdentity.appIdentifier
        })

        // A later bad network response cannot replace the last verified catalog.
        StubProtocol.responses[signatureURL] = Data(repeating: 0, count: 64)
        let cached = try await provider.catalog()
        #expect(cached.entry(for: MLModelCatalogEntry.tinyCLIPVit40M.id)?.downloadPlan?.totalByteCount == 123)
    }
}
