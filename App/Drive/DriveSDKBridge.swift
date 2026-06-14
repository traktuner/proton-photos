import Foundation
import PhotosCore
import ProtonAuth
import ProtonDriveSDK

/// Bridges the feature modules to the Proton Drive SDK. Owns the `ProtonPhotosClient`, wires in
/// our HTTP + account clients, resolves the photos root, and adapts SDK types to `PhotosCore`.
///
/// Everything SDK-specific is isolated here so feature modules stay SDK-agnostic and new SDK
/// capabilities (albums, sharing, upload) can be added without touching the UI layer.
actor DriveSDKBridge: PhotosRepository, ThumbnailProvider, ThumbnailBatchLoader, FullMediaProvider {
    private let photosClient: ProtonPhotosClient
    private let driveSession: DriveSession
    private let rateLimit = RateLimitGate()
    private var photosRoot: SDKNodeUid?

    init(session: ProtonSession, store: SessionKeychainStore) async throws {
        let driveSession = DriveSession(session: session, store: store)
        self.driveSession = driveSession

        DebugLog.log("bridge: fetching account data…")
        // Build the account client (fetch + decrypt the user's keys) up front.
        let account = try await driveSession.fetchAccountData()
        DebugLog.log("bridge: account ok — \(account.addresses.count) addresses, \(account.userKeys.count) user keys")
        let accountClient = try SDKAccountClientBuilder.build(account: account, keyPassword: session.keyPassword)
        DebugLog.log("bridge: account client built (\(accountClient.unlockedByKeyID.count) unlocked keys)")

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProtonPhotos/sdk", isDirectory: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)

        let config = ProtonDriveClientConfiguration(
            baseURL: "https://drive-api.proton.me/",   // trailing slash required by the C# core
            clientUID: session.uid,
            entityCachePath: caches.appendingPathComponent("entities.sqlite").path,
            secretCachePath: caches.appendingPathComponent("secrets.sqlite").path
        )

        self.photosClient = try await ProtonPhotosClient(
            configuration: config,
            httpClient: SDKHttpClient(driveSession: driveSession, rateLimit: rateLimit),
            accountClient: accountClient,
            logCallback: { _ in },
            featureFlagProviderCallback: { _, completion in completion(false) },
            recordMetricEventCallback: { _ in }
        )
        DebugLog.log("bridge: ProtonPhotosClient created ✓")
    }

    // MARK: - PhotosRepository

    func loadTimeline() async throws -> [TimelineSection] {
        do {
            let root = try await resolvePhotosRoot()
            DebugLog.log("timeline: photos root \(root.volumeID.prefix(8))…/\(root.nodeID.prefix(8))… — enumerating")
            let items = try await photosClient.enumerateTimeline(in: root)
            DebugLog.log("timeline: enumerated \(items.count) items ✓")
            return Self.group(items)
        } catch {
            DebugLog.log("timeline: FAILED — \(error)")
            throw error
        }
    }

    // MARK: - ThumbnailProvider

    func thumbnail(for uid: PhotoUID) async throws -> Data {
        try await singleThumbnail(uid, type: .thumbnail)
    }

    // MARK: - ThumbnailBatchLoader

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async {
        let sdkUids = uids.map { SDKNodeUid(volumeID: $0.volumeID, nodeID: $0.nodeID) }
        try? await photosClient.downloadThumbnails(
            photoUids: sdkUids,
            type: .thumbnail,
            cancellationToken: UUID(),
            onThumbnailDownloaded: { result in
                if case let .success(item?) = result, case let .success(data) = item.result {
                    onLoaded(PhotoUID(volumeID: item.fileUid.volumeID, nodeID: item.fileUid.nodeID), data)
                }
            }
        )
    }

    // MARK: - FullMediaProvider

    func preview(for uid: PhotoUID) async throws -> Data {
        try await singleThumbnail(uid, type: .preview)
    }

    func downloadOriginal(for uid: PhotoUID) async throws -> URL {
        let sdkUid = SDKNodeUid(volumeID: uid.volumeID, nodeID: uid.nodeID)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ProtonPhotos/originals", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(uid.nodeID.replacingOccurrences(of: "/", with: "_"))")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        _ = try await photosClient.download(
            photoUid: sdkUid,
            destinationUrl: dest,
            cancellationToken: UUID(),
            progressCallback: { _ in },
            onRetriableErrorReceived: { _ in }
        )
        return dest
    }

    private func singleThumbnail(_ uid: PhotoUID, type: ThumbnailData.ThumbnailType) async throws -> Data {
        let sdkUid = SDKNodeUid(volumeID: uid.volumeID, nodeID: uid.nodeID)
        let box = DataBox()
        try await photosClient.downloadThumbnails(
            photoUids: [sdkUid],
            type: type,
            cancellationToken: UUID(),
            onThumbnailDownloaded: { result in
                if case let .success(item?) = result, case let .success(data) = item.result {
                    box.set(data)
                }
            }
        )
        guard let data = box.value else { throw CocoaError(.fileReadUnknown) }
        return data
    }

    // MARK: - Photos root resolution

    private func resolvePhotosRoot() async throws -> SDKNodeUid {
        if let photosRoot { return photosRoot }
        let response = try await driveSession.getJSON("/drive/shares?ShareType=4", as: SharesListResponse.self)
        guard let share = response.shares.first(where: { $0.state == 1 && $0.locked != true }) else {
            throw DriveBridgeError.noPhotosShare
        }
        let root = SDKNodeUid(volumeID: share.volumeID, nodeID: share.linkID)
        photosRoot = root
        return root
    }

    // MARK: - Mapping

    private static func group(_ items: [PhotoTimelineItem]) -> [TimelineSection] {
        let calendar = Calendar.current
        let photos = items
            .map { PhotoItem(uid: PhotoUID(volumeID: $0.nodeUid.volumeID, nodeID: $0.nodeUid.nodeID),
                             captureTime: Date(timeIntervalSince1970: $0.captureTime),
                             mediaType: "image/jpeg") }
            .sorted { $0.captureTime > $1.captureTime }

        let keyFormatter = DateFormatter(); keyFormatter.dateFormat = "yyyy-MM-dd"
        let titleFormatter = DateFormatter(); titleFormatter.dateStyle = .full; titleFormatter.timeStyle = .none

        var order: [String] = []
        var buckets: [String: [PhotoItem]] = [:]
        for photo in photos {
            let day = calendar.startOfDay(for: photo.captureTime)
            let key = keyFormatter.string(from: day)
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]?.append(photo)
        }
        return order.map { key in
            let date = buckets[key]!.first!.captureTime
            return TimelineSection(id: key, date: date, title: titleFormatter.string(from: date), items: buckets[key]!)
        }
    }
}

enum DriveBridgeError: LocalizedError {
    case noPhotosShare
    var errorDescription: String? {
        switch self {
        case .noPhotosShare: "No Photos library was found on this account yet."
        }
    }
}

/// Thread-safe one-shot data holder for the SDK thumbnail callback.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    func set(_ data: Data) { lock.withLock { _data = data } }
    var value: Data? { lock.withLock { _data } }
}

private struct SharesListResponse: Decodable {
    let shares: [ShareItem]
    enum CodingKeys: String, CodingKey { case shares = "Shares" }

    struct ShareItem: Decodable {
        let shareID: String
        let volumeID: String
        let linkID: String
        let state: Int
        let locked: Bool?
        enum CodingKeys: String, CodingKey {
            case shareID = "ShareID"; case volumeID = "VolumeID"
            case linkID = "LinkID"; case state = "State"; case locked = "Locked"
        }
    }
}
