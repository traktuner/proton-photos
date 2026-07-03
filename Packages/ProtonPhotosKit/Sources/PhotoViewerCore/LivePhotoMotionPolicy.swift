import PhotosCore

/// Pure, platform-neutral policy for Live Photo motion playback — the single source of truth for *when* a
/// motion clip is preloaded and how long to wait for its (local, encrypted-cached) player to become ready.
/// Shared by the macOS and iOS viewers so the rule can never drift between platforms.
public enum LivePhotoMotionPolicy {
    /// Master kill-switch. Set `false` to disable Live Photo motion instantly (e.g. if it ever reintroduces the
    /// Swift-6.2 #76804 executor crash on this toolchain); prepare/play become no-ops and the still viewer stays
    /// fully functional.
    public static let playbackEnabled = true

    /// Poll interval (ms) while waiting for the preloaded clip's player item to reach `.readyToPlay`.
    public static let prerollPollMilliseconds = 20

    /// Max number of `prerollPollMilliseconds` polls before giving up. The clip is fully pre-downloaded, so
    /// readiness is normally near-instant; this bounds the wait so a stuck item can never hang the preload task.
    public static let prerollMaxTries = 100

    /// True only when a motion clip should be preloaded for `item`: motion is enabled, the item is a Live Photo
    /// with a paired video, and a streamer is available to fetch it.
    public static func shouldPrepare(item: PhotoItem, hasStreamer: Bool) -> Bool {
        playbackEnabled && item.isLivePhoto && item.relatedVideoUID != nil && hasStreamer
    }
}
