import Foundation
import PhotosCore

public struct MLPipelineID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let semanticSearch = MLPipelineID(rawValue: "semanticSearch")
    public static let people = MLPipelineID(rawValue: "people")
    public static let pets = MLPipelineID(rawValue: "pets")
}

public struct MLStageID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Operation semantics are Core data, not platform branches. Each embedding namespace identifies
/// an independent vector space so stores and schedulers can isolate their records.
public enum MLStageOperation: Sendable, Equatable, Codable {
    case imageEmbedding(namespace: String)
    case textEmbedding(namespace: String)
    case regionDetection(labels: [String])
    case regionEmbedding(namespace: String)
}

/// Input routing is explicit Core data. A detector can fan out only matching regions to separate
/// face, cat, dog or future embedders without model-name switches in platform code.
public enum MLStageInput: Sendable, Equatable, Codable {
    case asset
    case regions(producedBy: MLStageID, matchingLabels: [String])
}

public struct MLPipelineStage: Sendable, Equatable, Codable {
    public let id: MLStageID
    public let modelID: MLModelID
    public let operation: MLStageOperation
    public let input: MLStageInput
    public let dependsOn: [MLStageID]

    public init(
        id: MLStageID,
        modelID: MLModelID,
        operation: MLStageOperation,
        input: MLStageInput = .asset,
        dependsOn: [MLStageID] = []
    ) {
        self.id = id
        self.modelID = modelID
        self.operation = operation
        self.input = input
        self.dependsOn = dependsOn
    }
}

public struct MLPipelineDefinition: Sendable, Equatable, Codable {
    public let id: MLPipelineID
    public let feature: AppFeatureID
    public let stages: [MLPipelineStage]

    public init(id: MLPipelineID, feature: AppFeatureID, stages: [MLPipelineStage]) throws {
        guard !stages.isEmpty else { throw MLPipelineDefinitionError.empty }
        let ids = stages.map(\.id)
        guard Set(ids).count == ids.count else { throw MLPipelineDefinitionError.duplicateStage }
        let known = Set(ids)
        guard stages.allSatisfy({ Set($0.dependsOn).isSubset(of: known) && !$0.dependsOn.contains($0.id) }) else {
            throw MLPipelineDefinitionError.invalidDependency
        }
        let stagesByID = Dictionary(uniqueKeysWithValues: stages.map { ($0.id, $0) })
        for stage in stages {
            guard Self.hasValidInput(stage, stagesByID: stagesByID) else {
                throw MLPipelineDefinitionError.invalidInput
            }
        }
        guard Self.isAcyclic(stages) else { throw MLPipelineDefinitionError.cycle }
        self.id = id
        self.feature = feature
        self.stages = stages
    }

    private static func isAcyclic(_ stages: [MLPipelineStage]) -> Bool {
        let dependencies = Dictionary(uniqueKeysWithValues: stages.map { ($0.id, Set($0.dependsOn)) })
        var resolved: Set<MLStageID> = []
        while resolved.count < stages.count {
            let ready = stages.map(\.id).filter { !resolved.contains($0) && (dependencies[$0] ?? []).isSubset(of: resolved) }
            guard !ready.isEmpty else { return false }
            resolved.formUnion(ready)
        }
        return true
    }

    private static func hasValidInput(
        _ stage: MLPipelineStage,
        stagesByID: [MLStageID: MLPipelineStage]
    ) -> Bool {
        guard case .regions(let producerID, let matchingLabels) = stage.input else { return true }
        guard !matchingLabels.isEmpty,
              stage.dependsOn.contains(producerID),
              let producer = stagesByID[producerID],
              case .regionDetection(let producedLabels) = producer.operation else { return false }
        return Set(matchingLabels).isSubset(of: Set(producedLabels))
    }
}

public enum MLPipelineDefinitionError: Error, Equatable {
    case empty
    case duplicateStage
    case invalidDependency
    case invalidInput
    case cycle
}

/// Registry used by the scheduler to activate only pipelines whose feature gate is available.
public struct MLPipelineRegistry: Sendable {
    public let definitions: [MLPipelineDefinition]

    public init(_ definitions: [MLPipelineDefinition]) {
        var seen: Set<MLPipelineID> = []
        self.definitions = definitions.filter { seen.insert($0.id).inserted }
    }

    public func validate(models: MLModelCatalog) throws {
        for definition in definitions {
            for stage in definition.stages {
                guard let model = models.entry(for: stage.modelID) else {
                    throw MLPipelineRegistryError.missingModel(stage.modelID)
                }
                guard model.capabilities.contains(stage.operation.requiredCapability) else {
                    throw MLPipelineRegistryError.incompatibleModel(stage.modelID, stage.id)
                }
            }
        }
    }

    public func activeDefinitions(
        policy: AppFeaturePolicy,
        device: AppDeviceCapabilities,
        tier: AppProductTier
    ) -> [MLPipelineDefinition] {
        definitions.filter { policy.availability(of: $0.feature, device: device, tier: tier) == .available }
    }
}

private extension MLStageOperation {
    var requiredCapability: MLModelCapability {
        switch self {
        case .imageEmbedding: .imageEmbedding
        case .textEmbedding: .textEmbedding
        case .regionDetection: .regionDetection
        case .regionEmbedding: .regionEmbedding
        }
    }
}

public enum MLPipelineRegistryError: Error, Equatable {
    case missingModel(MLModelID)
    case incompatibleModel(MLModelID, MLStageID)
}
