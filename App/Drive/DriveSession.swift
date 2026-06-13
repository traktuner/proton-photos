import Foundation
import ProtonAuth
import ProtonCoreDataModel

/// Holds the live Proton session and performs authenticated requests against the Drive API,
/// transparently refreshing the access token on 401. Shared by the SDK HTTP client and the
/// account-data fetch. Thread-safe (token state guarded by a lock).
final class DriveSession: @unchecked Sendable {
    let config: ProtonAPIConfig
    private let store: SessionKeychainStore
    private let urlSession: URLSession
    private let lock = NSLock()
    private var session: ProtonSession
    private var refreshing: Task<Bool, Never>?

    init(session: ProtonSession, store: SessionKeychainStore, config: ProtonAPIConfig = ProtonAPIConfig()) {
        self.session = session
        self.store = store
        self.config = config
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpAdditionalHeaders = ["Accept": "application/vnd.protonmail.v1+json"]
        self.urlSession = URLSession(configuration: cfg)
    }

    var current: ProtonSession { lock.withLock { session } }
    var keyPassword: String { lock.withLock { session.keyPassword } }

    /// Auth headers for an arbitrary request (used by the SDK HTTP client too).
    func authHeaders() -> [String: String] {
        let s = current
        return [
            "x-pm-uid": s.uid,
            "Authorization": "Bearer \(s.accessToken)",
            "x-pm-appversion": config.appVersion,
        ]
    }

    // MARK: - Authenticated JSON

    func getJSON<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let data = try await authedData(path: path, method: "GET")
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func authedData(path: String, method: String, retryOn401: Bool = true) async throws -> Data {
        var req = URLRequest(url: config.baseURL.appendingPathComponent(path))
        req.httpMethod = method
        for (k, v) in authHeaders() { req.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProtonAuthError.invalidResponse }

        if http.statusCode == 401, retryOn401 {
            if await refreshToken() {
                return try await authedData(path: path, method: method, retryOn401: false)
            }
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProtonAuthError.apiError(code: http.statusCode, message: "HTTP \(http.statusCode) for \(path)")
        }
        return data
    }

    // MARK: - Token refresh

    func refreshToken() async -> Bool {
        let task: Task<Bool, Never> = lock.withLock {
            if let existing = refreshing { return existing }
            let t = Task<Bool, Never> { await self.performRefresh() }
            refreshing = t
            return t
        }
        let result = await task.value
        lock.withLock { refreshing = nil }
        return result
    }

    private func performRefresh() async -> Bool {
        let s = current
        var req = URLRequest(url: config.baseURL.appendingPathComponent("/auth/v4/refresh"))
        req.httpMethod = "POST"
        req.setValue(config.appVersion, forHTTPHeaderField: "x-pm-appversion")
        req.setValue(s.uid, forHTTPHeaderField: "x-pm-uid")
        req.setValue("Bearer \(s.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "ResponseType": "token", "GrantType": "refresh_token", "RefreshToken": s.refreshToken,
        ])
        guard let (data, response) = try? await urlSession.data(for: req),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let body = try? JSONDecoder().decode(RefreshResponse.self, from: data),
              let at = body.accessToken else {
            return false
        }
        lock.withLock {
            session.accessToken = at
            if let rt = body.refreshToken { session.refreshToken = rt }
            store.save(session)
        }
        return true
    }
}

private struct RefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    enum CodingKeys: String, CodingKey { case accessToken = "AccessToken"; case refreshToken = "RefreshToken" }
}

// MARK: - Account data (users / addresses)

struct AccountData {
    let userKeys: [Key]
    let addresses: [Address]
}

extension DriveSession {
    /// Fetches the user's keys and addresses needed to build the SDK `AccountClient`.
    func fetchAccountData() async throws -> AccountData {
        async let users: UsersResponse = getJSON("/core/v4/users", as: UsersResponse.self)
        async let addresses: AddressesResponse = getJSON("/core/v4/addresses", as: AddressesResponse.self)
        let (u, a) = try await (users, addresses)
        return AccountData(userKeys: u.user.keys, addresses: a.addresses)
    }
}

private struct UsersResponse: Decodable {
    let user: UserBody
    enum CodingKeys: String, CodingKey { case user = "User" }
    struct UserBody: Decodable {
        let keys: [Key]
        enum CodingKeys: String, CodingKey { case keys = "Keys" }
    }
}

private struct AddressesResponse: Decodable {
    let addresses: [Address]
    enum CodingKeys: String, CodingKey { case addresses = "Addresses" }
}
