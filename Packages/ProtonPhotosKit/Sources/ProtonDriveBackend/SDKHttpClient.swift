import Foundation
import ProtonDriveSDK

/// `HttpClientProtocol` implementation backed by `URLSession`. The SDK builds Drive API and
/// storage requests; we add the session auth headers and perform the I/O, refreshing on 401.
final class SDKHttpClient: HttpClientProtocol, @unchecked Sendable {
    private let driveSession: DriveSession
    private let urlSession: URLSession
    private let rateLimit: RateLimitGate

    init(driveSession: DriveSession, rateLimit: RateLimitGate) {
        self.driveSession = driveSession
        self.rateLimit = rateLimit
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
        guard Self.isTrustedDriveAPIURL(url, baseURL: driveSession.config.baseURL) else {
            return .failure(Self.invalidURL("Refusing Drive API request outside trusted Proton API host"))
        }
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

    // MARK: Storage upload (absolute url, streamed)

    /// Streams an encrypted block to block storage. The SDK hands us a bound stream pair via
    /// `StreamForUpload`: it writes encrypted bytes into the pair's output (pumped on the main run
    /// loop by `openOutputStream()`), and `URLSession` reads them from the pair's input as the request
    /// body. Storage URLs carry their own `pm-storage-token` in `headers`, so we add NO session auth.
    func requestUploadToStorage(
        method: String,
        url: String,
        content: StreamForUpload,
        headers: [(String, [String])]
    ) async -> Result<HttpClientResponse, NSError> {
        guard let requestURL = Self.httpsURL(url) else {
            return .failure(Self.invalidURL("Invalid storage upload URL"))
        }
        var req = URLRequest(url: requestURL)
        req.httpMethod = method
        applyHeaders(&req, headers: headers)        // storage URLs are token-authed; no session headers
        req.httpBodyStream = content.input

        let streamError = ErrorBox()
        content.onStreamError = { streamError.set($0) }
        // Begin the SDK → output-stream pump (schedules on the main run loop).
        await MainActor.run { content.openOutputStream() }

        await rateLimit.waitIfNeeded()
        do {
            let (data, response) = try await urlSession.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure(NSError(domain: "ProtonPhotos.SDKHttpClient", code: -6))
            }
            if http.statusCode == 429 { rateLimit.penalize(seconds: Self.retryAfter(http)) }
            if http.statusCode >= 400 {
                DebugLog.log("uploadStorage \(method) -> \(http.statusCode)")
            }
            return .success(HttpClientResponse(
                data: data, headers: Self.headerPairs(http), statusCode: http.statusCode
            ))
        } catch {
            // Prefer a stream-side error (encryption/producer) over the generic transport error.
            return .failure((streamError.value ?? error) as NSError)
        }
    }

    // MARK: Storage download (absolute url, streamed)

    func requestDownloadFromStorage(
        method: String,
        url: String,
        content: Data,
        headers: [(String, [String])],
        downloadStreamCreator: @Sendable @escaping (URLSession.AsyncBytes) -> AnyAsyncSequence<UInt8>
    ) async -> Result<HttpClientStream, NSError> {
        guard let requestURL = Self.httpsURL(url) else {
            return .failure(Self.invalidURL("Invalid storage URL"))
        }
        var req = URLRequest(url: requestURL)
        req.httpMethod = method
        applyHeaders(&req, headers: headers)   // storage URLs are pre-signed; no auth headers
        if !content.isEmpty { req.httpBody = content }

        await rateLimit.waitIfNeeded()
        do {
            let (bytes, response) = try await urlSession.bytes(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure(NSError(domain: "ProtonPhotos.SDKHttpClient", code: -4))
            }
            if http.statusCode == 429 { rateLimit.penalize(seconds: Self.retryAfter(http)) }
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

    private func perform(_ request: URLRequest, retryOn401: Bool, retryOn429: Bool = true) async -> Result<HttpClientResponse, NSError> {
        await rateLimit.waitIfNeeded()
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(NSError(domain: "ProtonPhotos.SDKHttpClient", code: -1))
            }
            if http.statusCode == 429 {
                rateLimit.penalize(seconds: Self.retryAfter(http))
                if retryOn429 {
                    await rateLimit.waitIfNeeded()
                    return await perform(request, retryOn401: retryOn401, retryOn429: false)
                }
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

    private static func retryAfter(_ http: HTTPURLResponse) -> Double {
        if let value = http.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(value) {
            return seconds
        }
        return 10
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

    private static func isTrustedDriveAPIURL(_ url: URL, baseURL: URL) -> Bool {
        guard url.scheme == "https",
              let host = url.host?.lowercased(),
              let expected = baseURL.host?.lowercased()
        else { return false }
        return host == expected
    }

    private static func httpsURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    private static func invalidURL(_ reason: String) -> NSError {
        NSError(
            domain: "ProtonPhotos.SDKHttpClient",
            code: -7,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }

    private static func headerPairs(_ http: HTTPURLResponse) -> [(String, [String])] {
        http.allHeaderFields.compactMap { key, value in
            guard let k = key as? String else { return nil }
            return (k, ["\(value)"])
        }
    }
}

/// Thread-safe one-shot holder for a stream-side upload error.
private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Error?
    func set(_ error: Error) { lock.withLock { if _value == nil { _value = error } } }
    var value: Error? { lock.withLock { _value } }
}
