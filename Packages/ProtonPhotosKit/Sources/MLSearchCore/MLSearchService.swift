import PhotosCore

/// Universal semantic-search entry point shared by every host platform.
///
/// The service binds one model epoch to indexing, coverage and querying so platform UIs cannot
/// accidentally diverge in descriptors, retry behavior or ranking semantics.
public actor MLSearchService {
    public let descriptor: MLModelDescriptor

    private let runner: MLIndexRunner
    private let searchEngine: MLSemanticSearchEngine
    private let releaseInferenceResources: (@Sendable () async -> Void)?

    public init(
        descriptor: MLModelDescriptor,
        store: any MLIndexStore,
        assetEmbedder: any MLAssetEmbedder,
        textEncoder: any MLTextQueryEncoder,
        scorer: any MLVectorScorer,
        runnerConfiguration: MLIndexRunner.Configuration = .init(),
        shouldContinue: @escaping @Sendable () -> Bool = { true },
        onProgress: (@Sendable (MLIndexProgress) -> Void)? = nil,
        releaseInferenceResources: (@Sendable () async -> Void)? = nil
    ) {
        self.descriptor = descriptor
        self.runner = MLIndexRunner(
            store: store,
            embedder: assetEmbedder,
            configuration: runnerConfiguration,
            shouldContinue: shouldContinue,
            onProgress: onProgress
        )
        self.searchEngine = MLSemanticSearchEngine(
            store: store,
            encoder: textEncoder,
            scorer: scorer
        )
        self.releaseInferenceResources = releaseInferenceResources
    }

    public func index(_ assets: [PhotoUID]) async -> MLIndexPassOutcome {
        let outcome = await runner.runPass(allAssets: assets, descriptor: descriptor)
        await releaseInferenceResources?()
        return outcome
    }

    public func search(_ text: String, limit: Int = 50) async throws -> MLSearchResults {
        try await searchEngine.search(
            MLSearchQuery(descriptor: descriptor, queryText: text, limit: limit)
        )
    }

    public func coverage(for assets: [PhotoUID]) async -> MLIndexCoverage {
        await searchEngine.coverage(for: descriptor, allAssets: assets)
    }

    public func releaseMemory() async {
        await searchEngine.purgeCachedBlocks()
        await releaseInferenceResources?()
    }
}
