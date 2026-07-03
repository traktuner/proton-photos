import Foundation
import PhotosCore
import ProtonAuth

public typealias PhotosBackend = PhotosRepository
    & ThumbnailProvider
    & ThumbnailBatchLoader
    & FullMediaProvider
    & VideoStreamProvider
    & PhotoMetadataProvider
    & BurstGroupProvider
    & PhotoLibraryProvider
    & FavoritesProvider
    & TrashProvider
    & LibraryStatsProvider
    & PhotoDimensionRecording

public struct ProtonDriveBackendPolicy: Sendable, Equatable {
    public let sdkCacheDirectory: URL
    public let libraryDatabaseBaseDirectory: URL
    public let libraryDatabasePolicy: LibraryDatabasePolicy
    public let videoCacheBudgetBytes: Int

    public init(
        sdkCacheDirectory: URL,
        libraryDatabaseBaseDirectory: URL = LibraryDatabaseLocation.defaultBaseDirectory(),
        libraryDatabasePolicy: LibraryDatabasePolicy = .conservative,
        videoCacheBudgetBytes: Int = 512 * 1024 * 1024
    ) {
        self.sdkCacheDirectory = sdkCacheDirectory
        self.libraryDatabaseBaseDirectory = libraryDatabaseBaseDirectory
        self.libraryDatabasePolicy = libraryDatabasePolicy
        self.videoCacheBudgetBytes = videoCacheBudgetBytes
    }

    public static func standard(
        libraryDatabasePolicy: LibraryDatabasePolicy = .conservative,
        videoCacheBudgetBytes: Int = 512 * 1024 * 1024
    ) -> Self {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return Self(
            sdkCacheDirectory: caches.appendingPathComponent("ProtonPhotos/sdk", isDirectory: true),
            libraryDatabasePolicy: libraryDatabasePolicy,
            videoCacheBudgetBytes: videoCacheBudgetBytes
        )
    }

    public static let desktopLibraryDatabasePolicy = LibraryDatabasePolicy(
        mmapBytes: 268_435_456,
        cacheSizeKiB: 8_192,
        busyTimeoutMs: 3_000,
        journalSizeLimitBytes: 16 * 1024 * 1024,
        walCheckpointRowThreshold: 10_000
    )

    public static let mobileLibraryDatabasePolicy = LibraryDatabasePolicy(
        mmapBytes: 0,
        cacheSizeKiB: 2_048,
        busyTimeoutMs: 3_000,
        journalSizeLimitBytes: 8 * 1024 * 1024,
        walCheckpointRowThreshold: 5_000
    )
}

public enum ProtonDriveBackendFactory {
    public static func makeFacade(
        session: ProtonSession,
        store: SessionKeychainStore,
        policy: ProtonDriveBackendPolicy
    ) async throws -> ProtonClientFacade {
        let bridge = try await DriveSDKBridge(session: session, store: store, policy: policy)
        SDKCapabilities.current.log()
        return await MainActor.run {
            ProtonClientFacade.make(bridge: bridge)
        }
    }

    public static func purgeLocalAccountData(uid: String, policy: ProtonDriveBackendPolicy) {
        AccountDataCache.clear(uid: uid, in: policy.sdkCacheDirectory)
        DriveSDKBridge.purgeMetadata(uid: uid, policy: policy)
        VideoByteRangeCache.shared.clearAll()
    }
}
