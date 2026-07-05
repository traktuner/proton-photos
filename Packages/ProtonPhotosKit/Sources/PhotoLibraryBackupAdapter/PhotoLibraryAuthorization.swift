import Foundation
import Photos

/// Platform-neutral projection of PhotoKit's read-write authorization state.
public enum PhotoBackupAccessState: String, Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    /// The user granted access to a selection only. Backup runs honestly over that selection;
    /// the UI must say so and offer the system's selection management.
    case limited
    case full

    public var allowsBackup: Bool { self == .full || self == .limited }
}

public enum PhotoLibraryAuthorization {

    public static func currentState() -> PhotoBackupAccessState {
        state(from: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Requests read-write access. Call ONLY from an explicit user action (enabling backup) -
    /// never at launch.
    public static func request() async -> PhotoBackupAccessState {
        state(from: await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    private static func state(from status: PHAuthorizationStatus) -> PhotoBackupAccessState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .full
        case .limited: return .limited
        @unknown default: return .denied
        }
    }
}
