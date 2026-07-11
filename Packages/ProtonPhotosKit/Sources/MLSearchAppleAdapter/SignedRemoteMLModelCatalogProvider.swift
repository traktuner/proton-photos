import CryptoKit
import Foundation
import MLSearchCore

public enum MLRemoteCatalogTransportError: Error, Equatable {
    case notHTTPS
    case invalidHost
    case httpStatus(Int)
    case responseTooLarge
    case invalidSignature
    case invalidPublicKey
}

/// Fetches the signed distribution catalog and falls back to the last verified copy.
public actor SignedRemoteMLModelCatalogProvider: MLModelCatalogProvider {
    public static let catalogURL = URL(string: "https://models.oncloud.at/catalog-v1.json")!
    public static let artifactBaseURL = URL(string: "https://models.oncloud.at/models/")!

    private static let defaultSignatureURL = URL(string: "https://models.oncloud.at/catalog-v1.sig")!
    private static let publicKeyBase64 = "qXMyoYhp7TbPPXPAyEKDoy+kkl8He7I5RNXWgjNc5Kk="
    private static let maximumCatalogBytes = 1 << 20

    private let trustedCatalog: MLModelCatalog
    private let cacheURL: URL
    private let signatureCacheURL: URL
    private let session: URLSession
    private let remoteCatalogURL: URL
    private let remoteSignatureURL: URL
    private let remoteArtifactBaseURL: URL
    private let publicKey: Data

    public init(
        trustedCatalog: MLModelCatalog,
        cacheDirectory: URL,
        session: URLSession = .shared
    ) {
        self.init(
            trustedCatalog: trustedCatalog,
            cacheDirectory: cacheDirectory,
            session: session,
            catalogURL: Self.catalogURL,
            signatureURL: Self.defaultSignatureURL,
            artifactBaseURL: Self.artifactBaseURL,
            publicKey: Data(base64Encoded: Self.publicKeyBase64) ?? Data()
        )
    }

    init(
        trustedCatalog: MLModelCatalog,
        cacheDirectory: URL,
        session: URLSession,
        catalogURL: URL,
        signatureURL: URL,
        artifactBaseURL: URL,
        publicKey: Data
    ) {
        self.trustedCatalog = trustedCatalog
        self.cacheURL = cacheDirectory.appendingPathComponent("catalog-v1.json")
        self.signatureCacheURL = cacheDirectory.appendingPathComponent("catalog-v1.sig")
        self.session = session
        self.remoteCatalogURL = catalogURL
        self.remoteSignatureURL = signatureURL
        self.remoteArtifactBaseURL = artifactBaseURL
        self.publicKey = publicKey
    }

    public func catalog() async throws -> MLModelCatalog {
        do {
            async let documentData = fetch(remoteCatalogURL, maximumBytes: Self.maximumCatalogBytes)
            async let signatureData = fetch(remoteSignatureURL, maximumBytes: 128)
            let (document, signature) = try await (documentData, signatureData)
            let resolved = try verifyAndResolve(document: document, signature: signature)
            try cache(document: document, signature: signature)
            return resolved
        } catch {
            guard let document = try? Data(contentsOf: cacheURL),
                  let signature = try? Data(contentsOf: signatureCacheURL) else { throw error }
            return try verifyAndResolve(document: document, signature: signature)
        }
    }

    private func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw MLRemoteCatalogTransportError.notHTTPS }
        guard url.host?.lowercased() == remoteCatalogURL.host?.lowercased() else {
            throw MLRemoteCatalogTransportError.invalidHost
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        MLModelRequestIdentity.apply(to: &request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { throw MLRemoteCatalogTransportError.httpStatus(http.statusCode) }
        guard data.count <= maximumBytes else { throw MLRemoteCatalogTransportError.responseTooLarge }
        return data
    }

    private func verifyAndResolve(document: Data, signature: Data) throws -> MLModelCatalog {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            throw MLRemoteCatalogTransportError.invalidPublicKey
        }
        guard key.isValidSignature(signature, for: document) else {
            throw MLRemoteCatalogTransportError.invalidSignature
        }
        let decoded = try JSONDecoder().decode(MLRemoteModelCatalogDocument.self, from: document)
        return try MLRemoteModelCatalogResolver(
            trustedCatalog: trustedCatalog,
            allowedBaseURL: remoteArtifactBaseURL
        ).resolve(decoded)
    }

    private func cache(document: Data, signature: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.write(to: cacheURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try signature.write(to: signatureCacheURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
