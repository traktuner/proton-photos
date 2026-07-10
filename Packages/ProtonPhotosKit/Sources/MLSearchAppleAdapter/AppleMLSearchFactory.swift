import Foundation
import MediaFeedCore
import MLSearchCore
import PhotosCore

public enum AppleMLSearchFactoryError: Error {
    case indexStoreUnavailable
}

/// Single composition point for the Apple ML stack used by macOS, iOS and iPadOS.
public enum AppleMLSearchFactory {
    public static func makeTinyCLIPService(
        modelURL: URL,
        descriptor: MLModelDescriptor,
        indexURL: URL,
        accountUID: String,
        keyPassword: String,
        feed: ThumbnailFeedCore,
        databasePolicy: LibraryDatabasePolicy = .conservative,
        runnerConfiguration: MLIndexRunner.Configuration = .init(),
        shouldContinue: @escaping @Sendable () -> Bool = { true },
        onProgress: (@Sendable (MLIndexProgress) -> Void)? = nil
    ) async throws -> MLSearchService {
        let cipher = CryptoKitMLVectorCipher(
            key: MLSearchKeyDerivation.localIndexKey(accountUID: accountUID, keyPassword: keyPassword),
            accountUID: accountUID
        )
        guard let store = SQLiteMLIndexStore(url: indexURL, policy: databasePolicy, cipher: cipher) else {
            throw AppleMLSearchFactoryError.indexStoreUnavailable
        }
        let encoder = try await CoreMLDualEncoder(
            modelURL: modelURL,
            descriptor: descriptor,
            imageSource: CachedThumbnailMLImageSource(feed: feed),
            tokenizer: CLIPBPETokenizer.bundledTinyCLIP()
        )
        return MLSearchService(
            descriptor: descriptor,
            store: store,
            assetEmbedder: encoder,
            textEncoder: encoder,
            scorer: AccelerateVectorScorer(),
            runnerConfiguration: runnerConfiguration,
            shouldContinue: shouldContinue,
            onProgress: onProgress,
            releaseInferenceResources: { await encoder.releaseModel() }
        )
    }
}
