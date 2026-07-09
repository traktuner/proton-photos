import Foundation
import PhotosCore

/// Availability state for a model artifact on the local filesystem.
public enum MLModelAvailability: Sendable, Equatable {
    case available(url: URL)
    case missing(descriptor: MLModelDescriptor)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Resolves a pure `MLModelDescriptor` to a concrete on-disk model artifact.
///
/// This is the seam between Core identity and platform model loading: Core code (planners,
/// engines, UI state) asks "is this epoch's model usable?", and an injected locator answers.
/// The Apple adapter ships a bundle-resource locator; a future locator may resolve to a
/// downloaded (Background Assets) or Proton-synced file. Keeping the protocol in Core means
/// hosts and tests can fake availability without any CoreML import.
public protocol MLModelLocator: Sendable {
    func availability(for descriptor: MLModelDescriptor) -> MLModelAvailability
}
