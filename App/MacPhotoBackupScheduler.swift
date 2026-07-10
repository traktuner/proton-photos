import AppKit
import PhotoLibraryBackupAdapter

/// Native macOS catch-up scheduling for the shared PhotoKit backup controller. The scheduler adds
/// execution opportunities only; ownership, recovery, dedupe, and progress remain in shared Core.
@MainActor
final class MacPhotoBackupScheduler {
    private var scheduler: NSBackgroundActivityScheduler?

    func configure(controller: PhotoLibraryBackupController) {
        invalidate()
        let scheduler = NSBackgroundActivityScheduler(identifier: "me.protonphotos.mac.photo-backup")
        scheduler.interval = 15 * 60
        scheduler.tolerance = 5 * 60
        scheduler.repeats = true
        scheduler.qualityOfService = .utility
        scheduler.schedule { completion in
            Task { @MainActor in
                guard controller.isEnabled else {
                    completion(.finished)
                    return
                }
                let activity = ProcessInfo.processInfo.beginActivity(
                    options: .background,
                    reason: "Backing up the photo library"
                )
                defer {
                    ProcessInfo.processInfo.endActivity(activity)
                    completion(.finished)
                }
                await controller.backgroundCatchUp(owner: .macOSBackgroundActivity)
            }
        }
        self.scheduler = scheduler
    }

    func invalidate() {
        scheduler?.invalidate()
        scheduler = nil
    }
}
