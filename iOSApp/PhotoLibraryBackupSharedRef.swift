import Foundation
import PhotoLibraryBackupAdapter

/// The BGProcessingTask handler outlives every SwiftUI scene, so the current account's backup
/// controller registers itself here (weak - sign-out releases it naturally).
@MainActor
final class PhotoLibraryBackupSharedRef {
    static let shared = PhotoLibraryBackupSharedRef()
    weak var controller: PhotoLibraryBackupController?

    private init() {}
}
