import Foundation
import AlbumsFeature
import UploadFeature

/// Central, honest record of what the wired Proton SDK / HTTP layer can actually do. Logged once at
/// sign-in for diagnostics — nothing here currently gates UI.
///
/// The album + upload sections are NOT hand-rolled here: they reference the same canonical capability
/// presets the UI gates on (`AlbumCapabilities.httpReadAndCover`, `UploadBackendCapabilities.sdkUploader`),
/// so the diagnostic can't drift from the real backend. When the SDK gains album APIs (or we implement
/// album-write crypto), flip the preset and both the gating and the log follow.
struct SDKCapabilities {
    // ProtonPhotosClient — present and wrapped by `DriveSDKBridge`.
    var photosClientAvailable = true
    var enumerateTimeline = true
    var downloadThumbnails = true
    var download = true
    var downloadOperation = true
    var cancelPhotoDownload = true

    /// Upload capabilities, as the UI sees them (the wired SDK uploader). Single source of truth.
    var upload = UploadBackendCapabilities.sdkUploader

    /// Album capabilities, as the UI sees them. The Swift SDK exposes no album API (`albumsViaSDK`);
    /// listing + set-cover go via direct HTTP, create/add need unimplemented album-node write crypto.
    var albumsViaSDK = false
    var albums = AlbumCapabilities.httpReadAndCover

    static let current = SDKCapabilities()

    /// Emits the `[SDKCapabilities]` diagnostic block.
    func log() {
        let lines = """
        [SDKCapabilities]
        photosClientAvailable=\(photosClientAvailable)
        canUpload=\(upload.canUpload)
        uploadCancel=\(upload.supportsCancel)
        uploadPauseResume=\(upload.supportsPauseResume)
        cancelPhotoDownload=\(cancelPhotoDownload)
        downloadOperation=\(downloadOperation)
        albumsViaSDK=\(albumsViaSDK)
        albumList=\(albums.canList)
        albumCreate=\(albums.canCreate)
        albumAdd=\(albums.canAddPhotos)
        albumSetCover=\(albums.canSetCover)
        """
        DebugLog.log(lines)
    }
}
