import Foundation
import Testing
@testable import MLSearchCore

@Suite struct MLRemoteModelCatalogTests {
    private let baseURL = URL(string: "https://models.oncloud.at/models/")!

    @Test func signedPayloadDataCanOnlyAttachDistributionToTrustedContracts() throws {
        let document = MLRemoteModelCatalogDocument(models: [
            .init(id: .tinyCLIPVit40M, revision: "r1-content", artifacts: [
                artifact("TinyCLIP.mlmodelc/weights/weight.bin", bytes: 166_234_752),
            ]),
            .init(id: .sigLIP2Base256, revision: "r1-multilingual", artifacts: [
                artifact("SigLIP2.mlmodelc/weights/weight.bin", bytes: 749_313_088),
                artifact("tokenizer.json", bytes: 10_781_028),
            ]),
        ])

        let catalog = try MLRemoteModelCatalogResolver(
            trustedCatalog: .builtIn,
            allowedBaseURL: baseURL
        ).resolve(document)

        let tiny = try #require(catalog.entry(for: .tinyCLIPVit40M))
        #expect(tiny.descriptor == MLModelCatalogEntry.tinyCLIPVit40M.descriptor)
        #expect(tiny.downloadPlan?.totalByteCount == 166_234_752)
        let siglip = try #require(catalog.entry(for: .sigLIP2Base256))
        #expect(siglip.runtimeResourcePaths == ["tokenizer.json"])
        #expect(siglip.downloadPlan?.totalByteCount == 760_094_116)
        #expect(catalog.entry(for: .appleMobileCLIPS2Developer)?.downloadPlan == nil)
    }

    @Test func rejectsUnknownModelsAndUntrustedArtifactURLs() {
        let resolver = MLRemoteModelCatalogResolver(trustedCatalog: .builtIn, allowedBaseURL: baseURL)
        #expect(throws: MLRemoteModelCatalogError.unknownModel("future-model")) {
            _ = try resolver.resolve(.init(models: [
                .init(id: MLModelID("future-model"), revision: "r1", artifacts: [artifact("Model.mlmodelc/a")]),
            ]))
        }
        #expect(throws: MLRemoteModelCatalogError.invalidArtifactURL("https://example.test/model.bin")) {
            _ = try resolver.resolve(.init(models: [
                .init(id: .tinyCLIPVit40M, revision: "r1", artifacts: [
                    .init(path: "TinyCLIP.mlmodelc/a", url: URL(string: "https://example.test/model.bin")!, sha256: String(repeating: "a", count: 64), bytes: 1),
                ]),
            ]))
        }
    }

    @Test func sigLIPRequiresItsPinnedTokenizerSidecar() {
        let resolver = MLRemoteModelCatalogResolver(trustedCatalog: .builtIn, allowedBaseURL: baseURL)
        #expect(throws: MLRemoteModelCatalogError.missingRuntimeResource("tokenizer.json")) {
            _ = try resolver.resolve(.init(models: [
                .init(id: .sigLIP2Base256, revision: "r1", artifacts: [artifact("SigLIP2.mlmodelc/weights.bin")]),
            ]))
        }
    }

    private func artifact(_ path: String, bytes: Int64 = 1) -> MLRemoteModelCatalogDocument.Artifact {
        .init(
            path: path,
            url: baseURL.appendingPathComponent("test/" + path),
            sha256: String(repeating: "a", count: 64),
            bytes: bytes
        )
    }
}

private extension MLModelID {
    static let tinyCLIPVit40M = MLModelCatalogEntry.tinyCLIPVit40M.id
    static let sigLIP2Base256 = MLModelCatalogEntry.sigLIP2Base256.id
    static let appleMobileCLIPS2Developer = MLModelCatalogEntry.appleMobileCLIPS2Developer.id
}
