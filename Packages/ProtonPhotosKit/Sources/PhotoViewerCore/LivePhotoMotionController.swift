import AVFoundation
import Foundation
import Observation
import PhotosCore

/// Owns a Live Photo's paired *motion clip* - its single `AVPlayer`, the fully-preloaded encrypted streaming
/// asset, and the play/stop state the viewer crossfades on. Shared by the macOS and iOS viewers so Live Photo
/// motion behaves identically on both.
///
/// E2EE-safe: the clip streams through the SAME encrypted resource-loader path as regular video
/// (`makeStreamingAsset` → `protonvideo://`) - the ENCRYPTED blocks are cached locally and decrypted ONLY in
/// RAM, so plaintext local motion-video files are forbidden by the local E2EE contract and never written.
/// UNLIKE timeline videos (which stream as they play), the clip is FULLY pre-downloaded (encrypted) before
/// `player` is exposed, so the first press plays INSTANTLY from the local encrypted cache. Without a `player`
/// (still loading / not a Live Photo / disabled), play/stop are no-ops.
///
/// Deliberately carries no audio-session configuration: on macOS a plain `AVPlayer` mixes with system audio and
/// never ducks; on iOS the default (`.soloAmbient`) session already gives Live-Photo-correct behavior (obeys the
/// silence switch, plays through the speaker). Adding a category here is the one thing that would cause ducking.
@MainActor
@Observable
public final class LivePhotoMotionController {
    /// The motion clip's player once fully prepared, else nil. The viewer overlays it above the still image and
    /// crossfades it in on `isPlaying`.
    public private(set) var player: AVPlayer?

    /// True while the motion clip is playing - the viewer crossfades the motion layer in/out on this.
    public private(set) var isPlaying = false

    /// Retains the streaming asset, the ONLY strong owner of the range resource-loader (AVFoundation holds it
    /// weakly) - it must live as long as the player or every `protonvideo://` range request goes unserved.
    private var asset: StreamingVideoAsset?
    private var prepareTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?

    public init() {}

    /// Preloads the paired motion clip for a Live Photo. No-op for non-Live items / when no streamer is
    /// available (per `LivePhotoMotionPolicy`). `isStillCurrent` lets the caller abort if the user paged away
    /// mid-load, so a swiped-past item never attaches a player; any prior clip is torn down first.
    public func prepare(for item: PhotoItem, streamer: VideoStreamProvider?,
                        isStillCurrent: @escaping @MainActor () -> Bool) {
        teardown()
        guard LivePhotoMotionPolicy.shouldPrepare(item: item, hasStreamer: streamer != nil),
              let motionUID = item.relatedVideoUID, let streamer else { return }
        prepareTask = Task { [weak self] in
            // 1) Fully download the ENCRYPTED clip into the local encrypted block cache (no plaintext on disk).
            try? await streamer.prefetchEncrypted(for: motionUID)
            guard !Task.isCancelled, isStillCurrent() else { return }
            // 2) Build the streaming player - its resource loader now serves entirely from the local encrypted cache.
            guard let stream = try? await streamer.makeStreamingAsset(for: motionUID),
                  !Task.isCancelled, isStillCurrent() else { return }
            let player = AVPlayer(playerItem: AVPlayerItem(asset: stream.asset))
            player.actionAtItemEnd = .pause
            player.automaticallyWaitsToMinimizeStalling = false
            // Wait until ready, then preroll - the clip is local + encrypted-cached, so this is fast.
            if let item = player.currentItem {
                var tries = 0
                while item.status == .unknown, !Task.isCancelled, tries < LivePhotoMotionPolicy.prerollMaxTries {
                    try? await Task.sleep(for: .milliseconds(LivePhotoMotionPolicy.prerollPollMilliseconds))
                    tries += 1
                }
                guard item.status == .readyToPlay, !Task.isCancelled, isStillCurrent() else { return }
                player.preroll(atRate: 1) { _ in }
            }
            // 3) Expose only now - play/stop is a no-op until the clip is 100% ready (then plays instantly).
            guard let self, !Task.isCancelled, isStillCurrent() else { return }
            self.asset = stream
            self.player = player
        }
    }

    /// Plays the motion clip ONCE from the start, WITH sound. Idempotent while already playing. `isMuted`/`volume`
    /// are reset every call (they persist on the `AVPlayer`), so a prior `stop()` can never leave the next play muted.
    public func play() {
        guard let player, !isPlaying else { return }
        isPlaying = true
        player.isMuted = false
        player.volume = 1
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.stop() } }
    }

    /// Stops the motion clip and lets the viewer crossfade back to the still (release, or auto at end-of-clip).
    public func stop() {
        guard isPlaying else { return }
        isPlaying = false
        player?.pause()
        player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        removeEndObserver()
    }

    /// Cancels any in-flight preload and releases the player + streaming resource loader (viewer close / paging away).
    public func teardown() {
        prepareTask?.cancel()
        prepareTask = nil
        removeEndObserver()
        player?.pause()
        isPlaying = false
        player = nil
        asset = nil
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}
