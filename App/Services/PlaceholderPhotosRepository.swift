import Foundation
import PhotosCore

/// TEMPORARY placeholder so the timeline screen builds and runs end-to-end before the
/// real `DriveSDKBridge` (HttpClient + AccountClient + ProtonPhotosClient) is wired in.
///
/// Phase 1b/2 will replace this with an implementation backed by the Proton Drive SDK.
struct PlaceholderPhotosRepository: PhotosRepository, ThumbnailProvider {
    func loadTimeline() async throws -> [TimelineSection] {
        // Simulate the initial cache-building spinner, then show an empty library.
        try? await Task.sleep(for: .milliseconds(600))
        return []
    }

    func thumbnail(for uid: PhotoUID) async throws -> Data {
        throw CocoaError(.featureUnsupported)
    }
}
