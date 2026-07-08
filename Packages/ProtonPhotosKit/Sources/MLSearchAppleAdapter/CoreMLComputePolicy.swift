import Foundation
import CoreML
import MLSearchCore

/// Compute-unit policy for CoreML inference.
///
/// Mirrors the existing `MLComputeUnits` enum from CoreML but scoped explicitly to our
/// MLSearch integration. The default is `.cpuAndNeuralEngine` per task specification:
/// - **Energy efficient**: Neural Engine for the heavy lifting, CPU as fallback.
/// - **Battery-safe**: Doesn't monopolize the GPU when not needed (e.g., background indexing).
/// - **Thermal-mindful**: Less heat than full GPU occupancy during extended crawling.
public struct CoreMLComputePolicy: Sendable, Equatable {
    public let computeUnits: MLComputeUnits
    
    /// Default production policy: CPU + Neural Engine.
    public static let `default`: CoreMLComputePolicy = .init(computeUnits: .cpuAndNeuralEngine)
    
    /// Production-ready with GPU fallback.
    public static let performanceOptimized: CoreMLComputePolicy = .init(computeUnits: .all)
    
    /// Debug-friendly: CPU only (deterministic, no thermal throttling).
    public static let cpuOnly: CoreMLComputePolicy = .init(computeUnits: .cpuOnly)
    
    /// Creates a policy from the CoreML enum.
    public init(computeUnits: MLComputeUnits) {
        self.computeUnits = computeUnits
    }
    
    /// Converts this policy into a CoreML model configuration that can be passed to `MLModel(configuration:)`.
    public var modelConfiguration: MLModelConfiguration {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        return config
    }
}
