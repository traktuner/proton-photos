import XCTest
import PhotosCore
@testable import MLSearchCore

final class MLPipelineDefinitionTests: XCTestCase {
    func testConditionalPipelineIsAValidatedDAG() throws {
        let detector = MLStageID(rawValue: "petDetector")
        let catEmbedder = MLStageID(rawValue: "catEmbedder")
        let dogEmbedder = MLStageID(rawValue: "dogEmbedder")
        let pipeline = try MLPipelineDefinition(
            id: .pets,
            feature: .petRecognition,
            stages: [
                .init(id: detector, modelID: .init("detector"), operation: .regionDetection(labels: ["cat", "dog"])),
                .init(
                    id: catEmbedder,
                    modelID: .init("cat-embedder"),
                    operation: .regionEmbedding(namespace: "cat-faces"),
                    input: .regions(producedBy: detector, matchingLabels: ["cat"]),
                    dependsOn: [detector]
                ),
                .init(
                    id: dogEmbedder,
                    modelID: .init("dog-embedder"),
                    operation: .regionEmbedding(namespace: "dog-faces"),
                    input: .regions(producedBy: detector, matchingLabels: ["dog"]),
                    dependsOn: [detector]
                ),
            ]
        )
        XCTAssertEqual(pipeline.stages.count, 3)
    }

    func testPipelineRejectsRegionLabelTheDetectorCannotProduce() {
        let detector = MLStageID(rawValue: "petDetector")
        XCTAssertThrowsError(try MLPipelineDefinition(
            id: .pets,
            feature: .petRecognition,
            stages: [
                .init(id: detector, modelID: .init("detector"), operation: .regionDetection(labels: ["cat"])),
                .init(
                    id: .init(rawValue: "dogEmbedder"),
                    modelID: .init("dog-embedder"),
                    operation: .regionEmbedding(namespace: "dog-faces"),
                    input: .regions(producedBy: detector, matchingLabels: ["dog"]),
                    dependsOn: [detector]
                ),
            ]
        )) { XCTAssertEqual($0 as? MLPipelineDefinitionError, .invalidInput) }
    }

    func testCycleIsRejected() {
        let a = MLStageID(rawValue: "a")
        let b = MLStageID(rawValue: "b")
        XCTAssertThrowsError(try MLPipelineDefinition(
            id: .people,
            feature: .peopleRecognition,
            stages: [
                .init(id: a, modelID: .init("a"), operation: .regionDetection(labels: []), dependsOn: [b]),
                .init(id: b, modelID: .init("b"), operation: .regionEmbedding(namespace: "faces"), dependsOn: [a]),
            ]
        )) { XCTAssertEqual($0 as? MLPipelineDefinitionError, .cycle) }
    }

    func testRegistryRejectsModelWithWrongCapability() throws {
        let model = MLModelCatalogEntry(
            id: .init("semantic"), displayName: "Semantic", family: "Test",
            descriptor: .init(identifier: "semantic", version: 1, embeddingDimension: 2),
            tokenizerID: "tokenizer", preprocessingID: "preprocess", license: .mit,
            releaseTrack: .developerOnly, estimatedInstalledBytes: 1, downloadPlan: nil
        )
        let stage = MLPipelineStage(
            id: .init(rawValue: "detector"), modelID: model.id,
            operation: .regionDetection(labels: ["person"])
        )
        let registry = MLPipelineRegistry([try .init(id: .people, feature: .peopleRecognition, stages: [stage])])
        XCTAssertThrowsError(try registry.validate(models: .init(entries: [model])))
    }
}
