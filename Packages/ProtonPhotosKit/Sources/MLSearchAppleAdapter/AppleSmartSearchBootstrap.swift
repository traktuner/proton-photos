import Foundation
import CoreML
import MediaFeedCore
import MLSearchCore
import PhotosCore

/// Single composition point for the Smart Search stack on Apple platforms.
///
/// macOS and iOS/iPadOS call this with their session/feed and get the one universal lifecycle
/// actor back; every policy (catalog, layout, verification, encryption, scheduling gate) is
/// assembled here exactly once.
public enum AppleSmartSearchBootstrap {
    /// Directory name of the Smart Search root inside an account's data directory. Everything
    /// Smart Search persists lives under it; purge deletes it recursively.
    public static let rootDirectoryName = "SmartSearch"

    /// One native capability probe for every Apple host. Core owns the policy; this adapter only
    /// translates public Core ML device discovery and physical memory into Core values.
    public static func featureAvailability(
        tier: AppProductTier = .free,
        policy: AppFeaturePolicy = .production
    ) -> AppFeatureAvailability {
        let hasNeuralEngine = MLModel.availableComputeDevices.contains { device in
            if case .neuralEngine = device { return true }
            return false
        }
        let capabilities = AppDeviceCapabilities(
            available: hasNeuralEngine ? [.neuralEngine] : [],
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
        return policy.availability(of: .smartSearch, device: capabilities, tier: tier)
    }

    public static func makeLifecycle(
        accountDirectory: URL,
        accountUID: String,
        keyPassword: String,
        feed: ThumbnailFeedCore,
        assetsProvider: @escaping @Sendable () async -> [PhotoUID],
        allowsDeveloperModels: Bool,
        hostPermitsIndexing: @escaping @Sendable () -> Bool = { true },
        databasePolicy: LibraryDatabasePolicy = .conservative,
        catalog: MLModelCatalog = .builtIn,
        runnerConfiguration: MLIndexRunner.Configuration = .init()
    ) -> MLSmartSearchLifecycle {
        let layout = MLModelInstallLayout(
            rootDirectory: accountDirectory.appendingPathComponent(rootDirectoryName, isDirectory: true)
        )
        let workGate = AppleSmartSearchWorkGate(feed: feed, hostPermitsIndexing: hostPermitsIndexing)
        let cipher = CryptoKitMLVectorCipher(
            key: MLSearchKeyDerivation.localIndexKey(accountUID: accountUID, keyPassword: keyPassword),
            accountUID: accountUID
        )
        let catalogProvider = SignedRemoteMLModelCatalogProvider(
            trustedCatalog: catalog,
            cacheDirectory: layout.rootDirectory
        )
        return MLSmartSearchLifecycle(dependencies: .init(
            catalog: catalog,
            catalogProvider: catalogProvider,
            layout: layout,
            stateStore: FileMLSmartSearchStateStore(layout: layout),
            installer: MLModelInstaller(layout: layout, transport: URLSessionMLModelArtifactTransport()),
            storeProvider: SQLiteMLIndexStoreProvider(url: layout.indexDatabaseURL, policy: databasePolicy, cipher: cipher),
            runtimeProvider: AppleSmartSearchRuntimeProvider(feed: feed, runnerConfiguration: runnerConfiguration),
            assetsProvider: assetsProvider,
            governor: MLClosureIndexingGovernor({ workGate.permitsIndexing() }),
            allowsDeveloperModels: allowsDeveloperModels,
            featureAvailability: featureAvailability()
        ))
    }
}
