@preconcurrency import CoreML
import Foundation
import MediaFeedCore
import MLSearchCore
import PhotosCore

public enum AppleSmartSearchRuntimeError: Error, Equatable {
    case noModelArtifact
    case unsupportedTokenizer(String)
    /// The catalog-declared runtime contract and the resolved tokenizer disagree — the
    /// session must not start with mismatched text inputs.
    case tokenizerContractMismatch(expected: Int, actual: Int)
}

/// Builds CoreML-backed Smart Search sessions for verified installations.
///
/// Owns the CoreML specifics Core must never see: locating the model artifact inside the
/// install directory, one-time compilation of `.mlpackage` artifacts, tokenizer resolution by
/// catalog identity, and the ANE-first compute policy (via `CoreMLDualEncoder`).
public struct AppleSmartSearchRuntimeProvider: MLSmartSearchRuntimeProvider {
    private let feed: ThumbnailFeedCore
    private let runnerConfiguration: MLIndexRunner.Configuration

    public init(feed: ThumbnailFeedCore, runnerConfiguration: MLIndexRunner.Configuration = .init()) {
        self.feed = feed
        self.runnerConfiguration = runnerConfiguration
    }

    public func makeSession(
        model: MLInstalledModel,
        store: any MLIndexStore,
        shouldContinueIndexing: @escaping @Sendable () -> Bool,
        onIndexProgress: @escaping @Sendable (MLIndexProgress) -> Void
    ) async throws -> any MLSmartSearchSession {
        let modelURL = try await Self.loadableModelURL(in: model.installDirectory)
        let tokenizer = try Self.tokenizer(for: model.entry.tokenizerID)
        // The catalog entry's runtime contract is validated END TO END before activation:
        // tokenizer identity here, function/input/output names, context length, image size
        // and embedding dimension inside the encoder against the loaded artifact.
        let contract = model.entry.runtimeContract
        guard tokenizer.contextLength == contract.textContextLength else {
            throw AppleSmartSearchRuntimeError.tokenizerContractMismatch(
                expected: contract.textContextLength,
                actual: tokenizer.contextLength
            )
        }
        let encoder = try await CoreMLDualEncoder(
            modelURL: modelURL,
            descriptor: model.entry.descriptor,
            imageSource: CachedThumbnailMLImageSource(feed: feed),
            tokenizer: tokenizer,
            schema: CoreMLDualEncoderSchema(contract: contract)
        )
        return MLSearchService(
            descriptor: model.entry.descriptor,
            store: store,
            assetEmbedder: encoder,
            textEncoder: encoder,
            scorer: AccelerateVectorScorer(),
            runnerConfiguration: runnerConfiguration,
            shouldContinue: shouldContinueIndexing,
            onProgress: onIndexProgress,
            releaseInferenceResources: { await encoder.releaseModel() }
        )
    }

    private static func tokenizer(for tokenizerID: String) throws -> any MLTextTokenizer {
        switch tokenizerID {
        case "clip-bpe-77":
            return try CLIPBPETokenizer.bundledTinyCLIP()
        default:
            throw AppleSmartSearchRuntimeError.unsupportedTokenizer(tokenizerID)
        }
    }

    /// A loadable compiled model inside the install directory: a shipped `.mlmodelc` is used
    /// directly; a `.mlpackage` compiles once and the result is cached beside it (inside the
    /// Smart Search root, so purge removes it too).
    static func loadableModelURL(in installDirectory: URL) async throws -> URL {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: installDirectory, includingPropertiesForKeys: nil)) ?? []
        if let compiled = contents.first(where: { $0.pathExtension == "mlmodelc" }) {
            return compiled
        }
        guard let package = contents.first(where: { $0.pathExtension == "mlpackage" }) else {
            throw AppleSmartSearchRuntimeError.noModelArtifact
        }

        let cachedName = package.deletingPathExtension().lastPathComponent + ".mlmodelc"
        let cached = installDirectory.appendingPathComponent(cachedName)
        if fm.fileExists(atPath: cached.path) {
            return cached
        }
        let compiled = try await MLModel.compileModel(at: package)
        // First writer wins; a concurrent compile losing the rename race is discarded.
        do {
            try fm.moveItem(at: compiled, to: cached)
        } catch {
            try? fm.removeItem(at: compiled)
            guard fm.fileExists(atPath: cached.path) else { throw error }
        }
        return cached
    }
}
