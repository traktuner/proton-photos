import Foundation
import CoreML
import MLSearchCore

/// Availability state for a model asset on the local filesystem.
public enum MLModelAvailability: Sendable, Equatable {
    case available(url: URL)
    case missing(descriptor: MLModelDescriptor)
    case invalidURL(reason: String)
    case loading
}

/// Diagnostic report describing why a model is unavailable (or succeeded).
public struct MLModelDiagnostics: Sendable {
    public let descriptor: MLModelDescriptor
    public let status: MLModelAvailability
    
    public init(descriptor: MLModelDescriptor, status: MLModelAvailability) {
        self.descriptor = descriptor
        self.status = status
    }
    
    public var isAvailable: Bool {
        if case .available = status { return true }
        return false
    }
}

/// Facade that resolves a `MLModelDescriptor` to a concrete `.mlmodelc` URL.
///
/// This is the **seam** that connects pure Core (`MLModelDescriptor`) to Apple's codegen'd
/// model classes (generated from `.mlmodelc`). The implementation is intentionally stubbed
/// here because no model artifact is committed yet. Host apps provide the real lookup path
/// via dependency injection (e.g., a bundle resource lookup or a decrypted Proton-synced file).
///
/// ## Integration steps (Stage 1B+)
/// 1. Commit or download a permissively-licensed MobileCLIP-class `.mlmodelc` bundle.
/// 2. Wire this facade's `resolveModel(for:)` to return the actual URL (bundle resource or cached file).
/// 3. Generate the model class with Xcode / `coremlc`; instantiate via `MLModel(contentsOf:)`.
///
/// ## Thread safety
/// The facade is stateless and `Sendable`. It does not hold a `MLModel` instance —
/// inference engines create fresh instances as needed.
public enum MLModelAvailabilityFacade: Sendable {
    /// Resolves a descriptor to a model URL.
    ///
    /// Currently looks up the descriptor's `identifier` as a `.mlmodelc` bundle resource on the
    /// main bundle; returns `.missing` when no such artifact is present. No model is committed
    /// in-tree yet, so in practice this returns `.missing` until Stage 1B wires a real bundle
    /// (or decrypted Proton-synced file) lookup path.
    public static func resolveModel(for descriptor: MLModelDescriptor) -> MLModelAvailability {
        let candidateURL = Bundle.main.url(forResource: descriptor.identifier, withExtension: "mlmodelc")
        if let url = candidateURL {
            return .available(url: url)
        } else {
            return .missing(descriptor: descriptor)
        }
    }
    
    /// Convenience overload returning only availability (dropping the diagnostic struct).
    public static func availability(for descriptor: MLModelDescriptor) -> MLModelAvailability {
        resolveModel(for: descriptor)
    }
    
    /// Optional extension for hosts that need a quick boolean (e.g., disable UI when missing).
    public static func isModelAvailable(for descriptor: MLModelDescriptor) -> Bool {
        if case .available = resolveModel(for: descriptor) { return true }
        return false
    }
}
