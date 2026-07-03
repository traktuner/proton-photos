import Foundation
import CryptoKit
import PhotosCore

public enum ProtonAuthError: LocalizedError {
    case apiError(code: Int, message: String)
    case invalidResponse
    case timedOut
    case payloadDecryptionFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        // The API code + server message are kept as interpolated detail inside a localized frame.
        case let .apiError(code, message): L10n.string("error.auth_api \(code) \(message)")
        case .invalidResponse: L10n.string("error.auth_invalid_response")
        case .timedOut: L10n.string("error.auth_timed_out")
        case .payloadDecryptionFailed: L10n.string("error.auth_decryption_failed")
        case .cancelled: L10n.string("error.auth_cancelled")
        }
    }
}

/// Configuration for talking to the Proton API.
public struct ProtonAPIConfig: Sendable {
    public let baseURL: URL
    public let accountURL: URL
    public let appVersion: String
    public let authClientID: String

    public static let externalDriveProtonPhotos = ProtonAPIConfig()

    public init(
        baseURL: URL = URL(string: "https://drive-api.proton.me")!,
        accountURL: URL = URL(string: "https://account.proton.me")!,
        appVersion: String = "external-drive-protonphotos@1.0.0-stable",
        authClientID: String = "external-drive"
    ) {
        self.baseURL = baseURL
        self.accountURL = accountURL
        self.appVersion = appVersion
        self.authClientID = authClientID
    }
}

/// Implements Proton's "sign in on the web" (session fork) flow - the same mechanism the
/// official Drive CLI uses. No password/2FA UI is needed: the user authenticates in their
/// browser and the resulting child session is pushed back to us.
public actor ProtonForkAuthenticator {
    public enum Progress: Sendable, Equatable {
        case requestingLink
        case waitingForBrowser
        case finalizing
    }

    private let config: ProtonAPIConfig
    private let session: URLSession

    private static let pollInterval: Duration = .seconds(3)
    private static let initialDelay: Duration = .seconds(3)
    private static let maxPollTime: Duration = .seconds(600)

    public init(config: ProtonAPIConfig = ProtonAPIConfig()) {
        self.config = config
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = ["Accept": "application/vnd.protonmail.v1+json"]
        self.session = URLSession(configuration: cfg)
    }

    /// Runs the whole flow. `openURL` is called with the sign-in URL to open in a browser;
    /// `onProgress` reports state for the UI.
    public func authenticate(
        openURL: @Sendable (URL) -> Void,
        onProgress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> ProtonSession {
        onProgress(.requestingLink)
        let fork = try await initFork()

        let encryptionKey = SymmetricKey(size: .bits256)
        let url = signInURL(userCode: fork.userCode, encryptionKey: encryptionKey)
        openURL(url)

        onProgress(.waitingForBrowser)
        try await Task.sleep(for: Self.initialDelay)

        let status = try await pollForkUntilReady(selector: fork.selector)

        onProgress(.finalizing)
        let keyPassword = try decryptPayload(status.payload, key: encryptionKey)

        return ProtonSession(
            uid: status.uid,
            accessToken: status.accessToken,
            refreshToken: status.refreshToken,
            keyPassword: keyPassword
        )
    }

    // MARK: - Steps

    struct ForkInit { let selector: String; let userCode: String }
    struct ForkStatus { let uid: String; let accessToken: String; let refreshToken: String; let payload: String }

    func initFork() async throws -> ForkInit {
        let req = request("/auth/v4/sessions/forks", method: "GET")
        let (data, response) = try await session.data(for: req)
        try Self.ensureOK(response, data: data)
        let body = try JSONDecoder().decode(ForkInitResponse.self, from: data)
        guard body.code == 1000, let selector = body.selector, let userCode = body.userCode else {
            throw ProtonAuthError.apiError(code: body.code, message: body.error ?? "fork init failed")
        }
        return ForkInit(selector: selector, userCode: userCode)
    }

    func signInURL(userCode: String, encryptionKey: SymmetricKey) -> URL {
        let base64Key = Data(encryptionKey.withUnsafeBytes { Data($0) }).base64EncodedString()
        let payload = "0:\(userCode):\(base64Key):\(config.authClientID)"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")   // mirror JS encodeURIComponent
        let encoded = payload.addingPercentEncoding(withAllowedCharacters: allowed) ?? payload
        return URL(string: "\(config.accountURL.absoluteString)/desktop/login?app=drive&pv=3#payload=\(encoded)")!
    }

    private func pollForkUntilReady(selector: String) async throws -> ForkStatus {
        let deadline = ContinuousClock.now.advanced(by: Self.maxPollTime)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let req = request("/auth/v4/sessions/forks/\(selector)", method: "GET")
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw ProtonAuthError.invalidResponse }

            if http.statusCode == 422 {            // not approved yet
                try await Task.sleep(for: Self.pollInterval)
                continue
            }
            try Self.ensureOK(response, data: data)
            let body = try JSONDecoder().decode(ForkStatusResponse.self, from: data)
            guard let uid = body.uid, let at = body.accessToken,
                  let rt = body.refreshToken, let payload = body.payload else {
                throw ProtonAuthError.apiError(code: body.code, message: body.error ?? "fork status incomplete")
            }
            return ForkStatus(uid: uid, accessToken: at, refreshToken: rt, payload: payload)
        }
        throw ProtonAuthError.timedOut
    }

    func decryptPayload(_ base64Payload: String, key: SymmetricKey) throws -> String {
        guard let blob = Data(base64Encoded: base64Payload), blob.count > 12 + 16 else {
            throw ProtonAuthError.payloadDecryptionFailed
        }
        let nonce = blob.prefix(12)
        let tag = blob.suffix(16)
        let ciphertext = blob.dropFirst(12).dropLast(16)
        do {
            let box = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            let plaintext = try AES.GCM.open(box, using: key, authenticating: Data("fork".utf8))
            let parsed = try JSONDecoder().decode(ForkPayload.self, from: plaintext)
            guard let keyPassword = parsed.keyPassword else { throw ProtonAuthError.payloadDecryptionFailed }
            return keyPassword
        } catch is ProtonAuthError {
            throw ProtonAuthError.payloadDecryptionFailed
        } catch {
            throw ProtonAuthError.payloadDecryptionFailed
        }
    }

    // MARK: - HTTP helpers

    private func request(_ path: String, method: String) -> URLRequest {
        var req = URLRequest(url: config.baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(config.appVersion, forHTTPHeaderField: "x-pm-appversion")
        return req
    }

    private static func ensureOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ProtonAuthError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if let err = try? JSONDecoder().decode(ProtonErrorBody.self, from: data) {
                throw ProtonAuthError.apiError(code: err.code, message: err.error ?? "HTTP \(http.statusCode)")
            }
            throw ProtonAuthError.apiError(code: http.statusCode, message: "HTTP \(http.statusCode)")
        }
    }
}

// MARK: - Wire models

private struct ProtonErrorBody: Decodable { let code: Int; let error: String?
    enum CodingKeys: String, CodingKey { case code = "Code"; case error = "Error" } }

private struct ForkInitResponse: Decodable {
    let code: Int; let selector: String?; let userCode: String?; let error: String?
    enum CodingKeys: String, CodingKey { case code = "Code"; case selector = "Selector"; case userCode = "UserCode"; case error = "Error" }
}

private struct ForkStatusResponse: Decodable {
    let code: Int; let uid: String?; let accessToken: String?; let refreshToken: String?; let payload: String?; let error: String?
    enum CodingKeys: String, CodingKey {
        case code = "Code"; case uid = "UID"; case accessToken = "AccessToken"
        case refreshToken = "RefreshToken"; case payload = "Payload"; case error = "Error"
    }
}

private struct ForkPayload: Decodable {
    let keyPassword: String?
    enum CodingKeys: String, CodingKey { case keyPassword }
}
