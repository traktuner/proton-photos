import PhotoLibraryBackupAdapter
import UIKit

/// Uses the short system grace window after the app enters the background. It never owns backup
/// state: the shared controller keeps every transition durable and the scheduled BGProcessingTask
/// remains the longer catch-up path.
@MainActor
final class PhotoBackupBackgroundGrace {
    static let shared = PhotoBackupBackgroundGrace()

    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var work: Task<Void, Never>?
    private var generation: UUID?

    func begin(controller: PhotoLibraryBackupController) {
        end()
        let generation = UUID()
        self.generation = generation
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Photo backup") { [weak self, weak controller] in
            controller?.stopSync()
            self?.end(generation: generation)
        }
        guard identifier != .invalid else {
            self.generation = nil
            return
        }

        work = Task { [weak self, weak controller] in
            guard let controller else {
                self?.end(generation: generation)
                return
            }
            await controller.backgroundCatchUp(owner: .iOSBackgroundTask)
            self?.end(generation: generation)
        }
    }

    func end(generation expectedGeneration: UUID? = nil) {
        if let expectedGeneration, generation != expectedGeneration { return }
        work?.cancel()
        work = nil
        guard identifier != .invalid else {
            generation = nil
            return
        }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
        generation = nil
    }
}
