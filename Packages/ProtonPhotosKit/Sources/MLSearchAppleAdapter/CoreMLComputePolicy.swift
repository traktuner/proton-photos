import Foundation
import CoreML
import MLSearchCore

/// Compute-unit policy for CoreML inference.
///
/// **Production constraint:** only `.cpuAndNeuralEngine` is allowed for production inference.
/// This enforces Neural Engine priority (ANE compute) while keeping CPU as a fallback.
/// `.all` (GPU) and `.cpuOnly` are restricted to debug/test escapes only.
///
/// - **Energy efficient**: Neural Engine for the heavy lifting, CPU as fallback.
/// - **Battery-safe**: Doesn't monopolize the GPU when not needed (e.g., background indexing).
/// - **Thermal-mindful**: Less heat than full GPU occupancy during extended crawling.
public struct CoreMLComputePolicy: Sendable, Equatable {
    public let computeUnits: MLComputeUnits
    
    /// **Only** production-allowed policy: CPU + Neural Engine.
    ///
    /// Public API surface is restricted to this one static member so production code cannot
    /// accidentally choose GPU (`.all`) or CPU-only inference. Debug/test escape hatches live
    /// behind `#if DEBUG` and are unavailable in release builds.
    public static let `default`: CoreMLComputePolicy = .init(computeUnits: .cpuAndNeuralEngine)
    
    /// Creates the default production policy.
    public init() {
        self.computeUnits = .cpuAndNeuralEngine
    }
    
    /// Private initializer preserving arbitrary unit selection for debug/test factories.
    private init(computeUnits: MLComputeUnits) {
        self.computeUnits = computeUnits
    }
    
    /// Converts this policy into a CoreML model configuration that can be passed to `MLModel(configuration:)`.
    public var modelConfiguration: MLModelConfiguration {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        return config
    }
}

#if DEBUG
/// Debug-only testing factory. Not available in production.
///
/// Allows tests to exercise CPU-only paths and verify behavior under different compute units
/// without leaking these options into production APIs.
internal extension CoreMLComputePolicy {
    static func debugOnlyTestingFactory(computeUnits: MLComputeUnits) -> CoreMLComputePolicy {
        .init(computeUnits: computeUnits)
    }
}
#endif
