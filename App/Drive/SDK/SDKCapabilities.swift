import Foundation

/// Central, honest record of what the wired Proton SDK / HTTP layer can actually do. Logged once at
/// sign-in for diagnostics — nothing here currently gates UI (see UploadBackendCapabilities for that).
///
/// This documents "does the SDK support X?" for the diagnostic log. When the SDK gains album APIs (or
/// we implement album-write crypto over HTTP), flip the relevant flag here (purely informational today).
struct SDKCapabilities {
    // ProtonPhotosClient — present and wrapped by `DriveSDKBridge`.
    var photosClientAvailable = true
    var enumerateTimeline = true
    var downloadThumbnails = true
    var download = true
    var downloadOperation = true
    var cancelPhotoDownload = true

    // Upload — SDK methods exist; the storage stream is now implemented in `SDKHttpClient`.
    var uploadPhoto = true
    var startUpload = true
    var uploadOperation = true
    var cancelUpload = true

    // Albums — the Swift SDK exposes no album API. Listing works via direct HTTP; writes
    // (create/add/cover) need album-node encryption that isn't implemented, so they're unsupported.
    var albumsViaSDK = false
    var albumsViaHTTP = true        // list + album-contents reads
    var albumCreateSupported = false
    var albumAddSupported = false
    var albumSetCoverSupported = false

    static let current = SDKCapabilities()

    /// Emits the `[SDKCapabilities]` diagnostic block.
    func log() {
        let lines = """
        [SDKCapabilities]
        photosClientAvailable=\(photosClientAvailable)
        uploadPhoto=\(uploadPhoto)
        startUpload=\(startUpload)
        uploadOperation=\(uploadOperation)
        cancelUpload=\(cancelUpload)
        cancelPhotoDownload=\(cancelPhotoDownload)
        downloadOperation=\(downloadOperation)
        albumsViaSDK=\(albumsViaSDK)
        albumsViaHTTP=\(albumsViaHTTP)
        albumCreate=\(albumCreateSupported)
        albumAdd=\(albumAddSupported)
        albumSetCover=\(albumSetCoverSupported)
        """
        DebugLog.log(lines)
    }
}
