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
        let url = Self.driveURL(relativePath, makeURL: driveSession.makeURL)
        var req = URLRequest(url: url)
        req.httpMethod = method
        applyAuthAndHeaders(&req, headers: headers)
        if !content.isEmpty { req.httpBody = content }

        let result = await perform(req, retryOn401: true)
        switch result {
        case let .success(resp) where resp.statusCode >= 400:
            DebugLog.log("driveApi \(method) \(url.absoluteString) -> \(resp.statusCode)")
        case let .failure(err):
            DebugLog.log("driveApi \(method) \(url.absoluteString) -> ERR \(err.code)")
        default:
            break
        }
        return result
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

    /// The SDK hands us a Drive-API `relativePath` of the form `"<servicePrefix>/<absolute URL>"`,
    /// e.g. `"drive/https://drive-api.proton.me/v2/shares/photos"`. The real endpoint inserts the
    /// service prefix into the host path: `https://drive-api.proton.me/drive/v2/shares/photos`.
    /// We reconstruct that; clean relative paths fall back to `makeURL`.
    static func driveURL(_ relativePath: String, makeURL: (String) -> URL) -> URL {
        guard let schemeRange = relativePath.range(of: "https://") ?? relativePath.range(of: "http://"),
              let embedded = URL(string: String(relativePath[schemeRange.lowerBound...])),
              let scheme = embedded.scheme, let host = embedded.host
        else {
            return makeURL(relativePath)
        }
        let prefix = relativePath[relativePath.startIndex..<schemeRange.lowerBound]
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var combined = "\(scheme)://\(host)"
        if !prefix.isEmpty { combined += "/\(prefix)" }
        combined += embedded.path.hasPrefix("/") ? embedded.path : "/\(embedded.path)"
        if let query = embedded.query, !query.isEmpty { combined += "?\(query)" }
        return URL(string: combined) ?? makeURL(relativePath)
    }

    private static func headerPairs(_ http: HTTPURLResponse) -> [(String, [String])] {
        http.allHeaderFields.compactMap { key, value in
            guard let k = key as? String else { return nil }
            return (k, ["\(value)"])
        }
    }
}
