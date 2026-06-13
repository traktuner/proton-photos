import Foundation
import ProtonDriveSDK

/// `HttpClientProtocol` implementation backed by `URLSession`. The SDK builds Drive API and
/// storage requests; we add the session auth headers and perform the I/O, refreshing on 401.
final class SDKHttpClient: HttpClientProtocol, @unchecked Sendable {
    private let driveSession: DriveSession
    private let urlSession: URLSession

    init(driveSession: DriveSession) {
        self.driveSession = driveSession
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.urlSession = URLSession(configuration: cfg)
    }

    // MARK: Drive API (relative path)

    func requestDriveApi(
        method: String,
        relativePath: String,
        content: Data,
        headers: [(String, [String])]
    ) async -> Result<HttpClientResponse, NSError> {
        let url = driveSession.config.baseURL.appendingPathComponent(relativePath)
        var req = URLRequest(url: url)
        req.httpMethod = method
        applyAuthAndHeaders(&req, headers: headers)
        if !content.isEmpty { req.httpBody = content }

        return await perform(req, retryOn401: true)
    }

    // MARK: Storage upload (absolute url)

    func requestUploadToStorage(
        method: String,
        url: String,
        content: StreamForUpload,
        headers: [(String, [String])]
    ) async -> Result<HttpClientResponse, NSError> {
        // TODO(Phase 2): streaming block upload. Not needed for timeline/thumbnail viewing.
        .failure(NSError(domain: "ProtonPhotos.SDKHttpClient", code: -2,
                         userInfo: [NSLocalizedDescriptionKey: "Upload not implemented yet"]))
    }

    // MARK: Storage download (absolute url, streamed)

    func requestDownloadFromStorage(
        method: String,
        url: String,
        content: Data,
        headers: [(String, [String])],
        downloadStreamCreator: @Sendable @escaping (URLSession.AsyncBytes) -> AnyAsyncSequence<UInt8>
    ) async -> Result<HttpClientStream, NSError> {
        guard let requestURL = URL(string: url) else {
            return .failure(NSError(domain: "ProtonPhotos.SDKHttpClient", code: -3,
                                    userInfo: [NSLocalizedDescriptionKey: "Invalid storage URL"]))
        }
        var req = URLRequest(url: requestURL)
        req.httpMethod = method
        applyHeaders(&req, headers: headers)   // storage URLs are pre-signed; no auth headers
        if !content.isEmpty { req.httpBody = content }

        do {
            let (bytes, response) = try await urlSession.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure(NSError(domain: "ProtonPhotos.SDKHttpClient", code: -4))
            }
            return .success(HttpClientStream(
                stream: downloadStreamCreator(bytes),
                headers: Self.headerPairs(http),
                statusCode: http.statusCode
            ))
        } catch {
            return .failure(error as NSError)
        }
    }

    // MARK: - Helpers

    private func perform(_ request: URLRequest, retryOn401: Bool) async -> Result<HttpClientResponse, NSError> {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(NSError(domain: "ProtonPhotos.SDKHttpClient", code: -1))
            }
            if http.statusCode == 401, retryOn401, await driveSession.refreshToken() {
                var retry = request
                for (k, v) in driveSession.authHeaders() { retry.setValue(v, forHTTPHeaderField: k) }
                return await perform(retry, retryOn401: false)
            }
            return .success(HttpClientResponse(
                data: data, headers: Self.headerPairs(http), statusCode: http.statusCode
            ))
        } catch {
            return .failure(error as NSError)
        }
    }

    private func applyAuthAndHeaders(_ req: inout URLRequest, headers: [(String, [String])]) {
        for (k, v) in driveSession.authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        applyHeaders(&req, headers: headers)
    }

    private func applyHeaders(_ req: inout URLRequest, headers: [(String, [String])]) {
        for (name, values) in headers {
            req.setValue(values.joined(separator: ", "), forHTTPHeaderField: name)
        }
    }

    private static func headerPairs(_ http: HTTPURLResponse) -> [(String, [String])] {
        http.allHeaderFields.compactMap { key, value in
            guard let k = key as? String else { return nil }
            return (k, ["\(value)"])
        }
    }
}
