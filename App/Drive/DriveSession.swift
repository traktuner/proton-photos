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

    /// Builds an absolute API URL. Uses string concatenation rather than
    /// `URL.appendingPathComponent`, which would percent-encode `?`/`&` in the query string.
    func makeURL(_ path: String) -> URL {
        let p = path.hasPrefix("/") ? path : "/" + path
        return URL(string: config.baseURL.absoluteString + p) ?? config.baseURL
    }

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

    /// Authenticated write request (POST/PUT/DELETE) with an optional JSON body.
    @discardableResult
    func send(_ path: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        try await authedData(path: path, method: method, body: body)
    }

    private func authedData(path: String, method: String, body: [String: Any]? = nil, retryOn401: Bool = true) async throws -> Data {
        var req = URLRequest(url: makeURL(path))
        req.httpMethod = method
        for (k, v) in authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProtonAuthError.invalidResponse }

        if http.statusCode == 401, retryOn401 {
            if await refreshToken() {
                return try await authedData(path: path, method: method, body: body, retryOn401: false)
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
        var req = URLRequest(url: makeURL("/auth/v4/refresh"))
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

// MARK: - Photos listing (Live Photo / video metadata)

/// One photo as returned by the direct `/drive/volumes/{volumeID}/photos` endpoint - carries the
/// `Tags` + `RelatedPhotos` that the SDK's `enumerateTimeline` wrapper drops.
struct PhotosListEntry: Decodable {
    let linkID: String
    let captureTime: Double
    let tags: [Int]
    let relatedPhotos: [Related]

    struct Related: Decodable {
        let linkID: String
        enum CodingKeys: String, CodingKey { case linkID = "LinkID" }
    }
    enum CodingKeys: String, CodingKey {
        case linkID = "LinkID"; case captureTime = "CaptureTime"
        case tags = "Tags"; case relatedPhotos = "RelatedPhotos"
    }

    /// Server-side PhotoTag: livePhotos = 3.
    var isLivePhoto: Bool { tags.contains(3) }
    /// The paired video file for a Live Photo (first related node).
    var relatedVideoLinkID: String? { relatedPhotos.first?.linkID }
}

private struct PhotosListResponse: Decodable {
    let photos: [PhotosListEntry]
    enum CodingKeys: String, CodingKey { case photos = "Photos" }
}

extension DriveSession {
    /// Fetches raw encrypted block bytes from storage for video streaming. Two patterns:
    ///  • `token != nil` → hit `url` (a BareURL) with the `pm-storage-token` header and NO session
    ///    auth (the web client pattern).
    ///  • `token == nil` → `url` is a full URL. Session auth is sent only to the trusted Drive API host;
    ///    pre-signed storage URLs are fetched as-is so bearer tokens cannot leak cross-host.
    /// A fresh `URLSession.shared` request is used so the JSON `Accept` header isn't sent to the CDN.
    func fetchBlock(url: String, token: String?) async throws -> Data {
        guard let u = URL(string: url), u.scheme == "https", u.host != nil else {
            throw ProtonAuthError.invalidResponse
        }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        if let token {
            req.setValue(token, forHTTPHeaderField: "pm-storage-token")
        } else if isTrustedAPIURL(u) {
            for (k, v) in authHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ProtonAuthError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw ProtonAuthError.apiError(code: http.statusCode, message: "block fetch HTTP \(http.statusCode)")
        }
        return data
    }

    private func isTrustedAPIURL(_ url: URL) -> Bool {
        guard url.scheme == "https",
              let host = url.host?.lowercased(),
              let expected = config.baseURL.host?.lowercased()
        else { return false }
        return host == expected
    }

    /// Enumerates the photos listing for a volume via the direct REST endpoint (cursor pagination),
    /// returning the per-photo `Tags` + `RelatedPhotos` the SDK wrapper omits. Pass `tag` for a
    /// server-side smart filter (Favorites/Videos/Selfies/…) - the API filters by a single tag.
    func fetchPhotosList(volumeID: String, tag: Int? = nil, pageSize: Int = 500) async throws -> [PhotosListEntry] {
        var all: [PhotosListEntry] = []
        var cursor: String?
        while true {
            var path = "/drive/volumes/\(volumeID)/photos?PageSize=\(pageSize)"
            if let tag { path += "&Tag=\(tag)" }
            if let cursor { path += "&PreviousPageLastLinkID=\(cursor)" }
            let page = try await getJSON(path, as: PhotosListResponse.self)
            all.append(contentsOf: page.photos)
            guard page.photos.count == pageSize, let last = page.photos.last?.linkID else { break }
            cursor = last
        }
        return all
    }

    /// Favorite (POST) or un-favorite (DELETE the favorites tag 0) a photo. Volume-keyed.
    func setFavorite(volumeID: String, linkID: String, _ favorite: Bool) async throws {
        if favorite {
            try await send("/drive/photos/volumes/\(volumeID)/links/\(linkID)/favorite", method: "POST")
        } else {
            try await send("/drive/photos/volumes/\(volumeID)/links/\(linkID)/tags", method: "DELETE", body: ["Tags": [0]])
        }
    }

    /// Sets an album's cover to an already-uploaded photo. A cleartext LinkID reference (no crypto) - matches the
    /// Proton web client: PUT the album link with the chosen photo's link id.
    func setAlbumCover(volumeID: String, albumLinkID: String, coverLinkID: String) async throws {
        try await send("/drive/photos/volumes/\(volumeID)/albums/\(albumLinkID)", method: "PUT", body: ["CoverLinkID": coverLinkID])
    }

    /// Moves photos to trash (batch). Volume-keyed, on the `v2` path.
    func trash(volumeID: String, linkIDs: [String]) async throws {
        try await send("/drive/v2/volumes/\(volumeID)/trash_multiple", method: "POST", body: ["LinkIDs": linkIDs])
    }

    /// Restores photos from trash (batch).
    func restore(volumeID: String, linkIDs: [String]) async throws {
        try await send("/drive/v2/volumes/\(volumeID)/trash/restore_multiple", method: "PUT", body: ["LinkIDs": linkIDs])
    }

    /// Lists trashed links (offset pagination). Callers filter to photo files.
    func listTrash(volumeID: String, pageSize: Int = 150) async throws -> [TrashLink] {
        var all: [TrashLink] = []
        var page = 0
        while true {
            let r = try await getJSON("/drive/volumes/\(volumeID)/trash?Page=\(page)&PageSize=\(pageSize)", as: TrashResponse.self)
            let links = r.links ?? []
            all.append(contentsOf: links)
            if links.count < pageSize { break }
            page += 1
        }
        return all
    }

    /// Lists the user's owned photo albums (AnchorID cursor pagination). Names are NOT included here
    /// - they're decrypted separately from each album's link metadata.
    func fetchAlbums(volumeID: String) async throws -> [AlbumListEntry] {
        var all: [AlbumListEntry] = []
        var anchor: String?
        repeat {
            var path = "/drive/photos/volumes/\(volumeID)/albums"
            if let anchor { path += "?AnchorID=\(anchor)" }
            let page = try await getJSON(path, as: AlbumsListResponse.self)
            all.append(contentsOf: page.albums ?? [])
            anchor = page.more == true ? page.anchorID : nil
        } while anchor != nil
        return all
    }

    /// Lists the photos contained in an album (same per-photo shape as the timeline).
    func fetchAlbumPhotos(volumeID: String, albumLinkID: String) async throws -> [PhotosListEntry] {
        var all: [PhotosListEntry] = []
        var anchor: String?
        repeat {
            var path = "/drive/photos/volumes/\(volumeID)/albums/\(albumLinkID)/children?Desc=1"
            if let anchor { path += "&AnchorID=\(anchor)" }
            let page = try await getJSON(path, as: AlbumPhotosResponse.self)
            all.append(contentsOf: page.photos)
            anchor = page.more == true ? page.anchorID : nil
        } while anchor != nil
        return all
    }
}

struct TrashLink: Decodable {
    // Tolerant: the trash listing sometimes omits fields per item; a single missing required field used to fail
    // the WHOLE decode (the "Recently Deleted couldn't load" error). Optional + filtered in the bridge instead.
    let linkID: String?
    let type: Int?
    let createTime: Double?
    let mimeType: String?
    let photoProperties: PhotoProps?
    struct PhotoProps: Decodable {
        let captureTime: Double?
        enum CodingKeys: String, CodingKey { case captureTime = "CaptureTime" }
    }
    enum CodingKeys: String, CodingKey {
        case linkID = "LinkID", type = "Type", createTime = "CreateTime",
             mimeType = "MIMEType", photoProperties = "PhotoProperties"
    }
    var captureTime: Double { photoProperties?.captureTime ?? createTime ?? 0 }
}

private struct TrashResponse: Decodable {
    let links: [TrashLink]?
    enum CodingKeys: String, CodingKey { case links = "Links" }
}

struct AlbumListEntry: Decodable {
    let linkID: String
    let photoCount: Int?
    let coverLinkID: String?
    enum CodingKeys: String, CodingKey {
        case linkID = "LinkID", photoCount = "PhotoCount", coverLinkID = "CoverLinkID"
    }
}

private struct AlbumsListResponse: Decodable {
    let albums: [AlbumListEntry]?
    let anchorID: String?
    let more: Bool?
    enum CodingKeys: String, CodingKey { case albums = "Albums", anchorID = "AnchorID", more = "More" }
}

private struct AlbumPhotosResponse: Decodable {
    let photos: [PhotosListEntry]
    let anchorID: String?
    let more: Bool?
    enum CodingKeys: String, CodingKey { case photos = "Photos", anchorID = "AnchorID", more = "More" }
}

// MARK: - Account data (users / addresses)

struct AccountData {
    let userKeys: [Key]
    let addresses: [Address]
}

extension DriveSession {
    /// Fetches the user's keys and addresses needed to build the SDK `AccountClient`.
    /// We decode minimal DTOs (ProtonCore's own `Codable` is stricter than the live API) and
    /// construct `ProtonCoreDataModel.Key`/`Address` via their public initialisers.
    func fetchAccountData() async throws -> AccountData {
        async let usersData = authedData(path: "/core/v4/users", method: "GET")
        async let addressesData = authedData(path: "/core/v4/addresses", method: "GET")
        let (uData, aData) = try await (usersData, addressesData)
        // Persist (encrypted) so a later OFFLINE cold start can rebuild the crypto without the network.
        AccountDataCache.save(users: uData, addresses: aData, uid: current.uid, keyPassword: current.keyPassword)
        return try Self.decodeAccountData(users: uData, addresses: aData)
    }

    /// The encrypted-on-disk account data from a previous online launch, or nil if absent/undecryptable. Lets
    /// `DriveSDKBridge.init` rebuild the (pure) Drive crypto + SDK account client when the network is unavailable.
    func cachedAccountData() -> AccountData? {
        guard let blob = AccountDataCache.load(uid: current.uid, keyPassword: current.keyPassword) else { return nil }
        return try? Self.decodeAccountData(users: blob.users, addresses: blob.addresses)
    }

    private static func decodeAccountData(users: Data, addresses: Data) throws -> AccountData {
        let u = try JSONDecoder().decode(UsersResponse.self, from: users)
        let a = try JSONDecoder().decode(AddressesResponse.self, from: addresses)
        // Surface the storage quota for Settings (works offline too - both the live and cached paths decode here).
        if let used = u.user.usedSpace, let max = u.user.maxSpace, max > 0 {
            Task { @MainActor in AccountInfo.shared.update(usedBytes: used, maxBytes: max) }
        }
        return AccountData(userKeys: u.user.keys.map(makeKey), addresses: a.addresses.map(makeAddress))
    }

    private static func makeKey(_ d: CoreKeyDTO) -> Key {
        Key(keyID: d.id, privateKey: d.privateKey, keyFlags: d.flags ?? 0,
            token: d.token, signature: d.signature, activation: nil,
            active: d.active ?? 1, version: d.version ?? 0, primary: d.primary ?? 0)
    }

    private static func makeAddress(_ d: CoreAddressDTO) -> Address {
        Address(
            addressID: d.id, domainID: d.domainID, email: d.email,
            send: Address.AddressSendReceive(rawValue: d.send ?? 1) ?? .active,
            receive: Address.AddressSendReceive(rawValue: d.receive ?? 1) ?? .active,
            status: Address.AddressStatus(rawValue: d.status ?? 1) ?? .enabled,
            type: Address.AddressType(rawValue: d.type ?? 1) ?? .protonDomain,
            order: d.order ?? 0, displayName: d.displayName ?? "", signature: d.signature ?? "",
            hasKeys: d.hasKeys ?? (d.keys.isEmpty ? 0 : 1), keys: d.keys.map(makeKey)
        )
    }
}

private struct UsersResponse: Decodable {
    let user: UserBody
    enum CodingKeys: String, CodingKey { case user = "User" }
    struct UserBody: Decodable {
        let keys: [CoreKeyDTO]
        let usedSpace: Int64?
        let maxSpace: Int64?
        enum CodingKeys: String, CodingKey { case keys = "Keys", usedSpace = "UsedSpace", maxSpace = "MaxSpace" }
    }
}

private struct AddressesResponse: Decodable {
    let addresses: [CoreAddressDTO]
    enum CodingKeys: String, CodingKey { case addresses = "Addresses" }
}

private struct CoreKeyDTO: Decodable {
    let id: String
    let privateKey: String
    let token: String?
    let signature: String?
    let primary: Int?
    let active: Int?
    let flags: Int?
    let version: Int?
    enum CodingKeys: String, CodingKey {
        case id = "ID", privateKey = "PrivateKey", token = "Token", signature = "Signature"
        case primary = "Primary", active = "Active", flags = "Flags", version = "Version"
    }
}

private struct CoreAddressDTO: Decodable {
    let id: String
    let domainID: String?
    let email: String
    let send: Int?
    let receive: Int?
    let status: Int?
    let type: Int?
    let order: Int?
    let displayName: String?
    let signature: String?
    let hasKeys: Int?
    let keys: [CoreKeyDTO]
    enum CodingKeys: String, CodingKey {
        case id = "ID", domainID = "DomainID", email = "Email", send = "Send", receive = "Receive"
        case status = "Status", type = "Type", order = "Order", displayName = "DisplayName"
        case signature = "Signature", hasKeys = "HasKeys", keys = "Keys"
    }
}
