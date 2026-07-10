import Foundation
import CoreML
import MLSearchCore

/// `MLModelLocator` that resolves descriptors to compiled `.mlmodelc` bundle resources.
///
/// The bundle is injected (defaults to `.main`) so hosts can point at their own bundle and
/// tests can point at a fixture directory — a hardcoded `Bundle.main` is neither. Lookup is
/// by `descriptor.identifier` only: the artifact for a new model version replaces the old
/// one at build time, and the descriptor's `version` gates re-indexing, not file naming.
///
/// No model artifact is committed yet (license spike pending), so production currently
/// resolves to `.missing`. Once an artifact ships, the inference engine loads it via
/// `MLModel(contentsOf:configuration:)` with `CoreMLComputePolicy.default` (Neural Engine).
public struct BundleMLModelLocator: MLModelLocator, @unchecked Sendable {
    // Bundle is not Sendable by declaration, but resource lookup is documented thread-safe.
    private let bundle: Bundle

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    public func availability(for descriptor: MLModelDescriptor) -> MLModelAvailability {
        if let url = bundle.url(forResource: descriptor.identifier, withExtension: "mlmodelc") {
            return .available(url: url)
        }
        return .missing(descriptor: descriptor)
    }
}
