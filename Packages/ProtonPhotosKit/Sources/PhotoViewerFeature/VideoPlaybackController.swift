import Foundation
import AVFoundation
import PhotosCore

/// Owns the single `AVPlayer` and every AVFoundation observation for the video path, and drives the
/// `VideoViewerState` machine. Pulled out of `PhotoViewerModel` so the viewer no longer carries
/// playback wiring — the model only decides *which* source to play; this decides *how it's going*.
///
/// The one rule it enforces (the reason it exists): the UI never gets stuck. Every attached player is
/// guarded by a watchdog — if it doesn't reach `.playing` within the deadline it fails or asks the
/// model to fall back to a full download (the native equivalent of Proton Drive Web's
/// `FIRST_BLOCK_TIMEOUT`). Mid-stream stalls surface as `.buffering` (a real reason), not a frozen
/// frame, and `failedToPlayToEndTime` maps to a readable error.
@MainActor
@Observable
public final class VideoPlaybackController {
    public private(set) var state: VideoViewerState = .idle
    /// The single AVPlayer (streaming or local file). `nil` for images / before a video is attached.
    public private(set) var player: AVPlayer?

    /// Retains the streaming asset + its resource-loader delegate for as long as the player lives
    /// (AVFoundation holds the resource-loader delegate weakly).
    private var streamingAsset: AnyObject?
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var watchdog: Task<Void, Never>?
    private var currentUID: PhotoUID?
    private var isStreaming = false
    private var didReachPlaying = false

    /// Seconds to wait for first playback before declaring the attempt stuck. Matches the web client's
    /// 30 s first-block timeout.
    private let firstFrameDeadline: TimeInterval

    public init(firstFrameDeadline: TimeInterval = 30) {
        self.firstFrameDeadline = firstFrameDeadline
    }

    // MARK: - State the model pushes in (resolution phase, before a player exists)

    public func setResolving() { transition(.resolving) }
    public func setDownloading(_ progress: Double) { transition(.downloading(progress)) }

    /// Resets to idle and tears down any player — used when navigating to a new item or when a
    /// stream-resolve turns out to be an image.
    public func reset() { teardown(); transition(.idle) }

    // MARK: - Playback entry points

    /// Plays a range-streamed asset. Starts in `.buffering` (bytes arrive on demand) and is guarded by
    /// the watchdog; on first `.readyToPlay` it flips to `.playing`.
    public func playStreaming(asset: AVURLAsset, retaining: AnyObject, uid: PhotoUID) {
        teardown()
        currentUID = uid
        isStreaming = true
        streamingAsset = retaining
        transition(.preparingStream)
        attach(AVPlayerItem(asset: asset), uid: uid, initial: .buffering(nil))
    }

    /// Hard failure (resolution/download path gave up). Shows the error; no player.
    public func fail(_ error: VideoPlaybackError, uid: PhotoUID) {
        guard uid == currentUID || currentUID == nil else { return }
        teardownKeepingState()
        transition(.failed(error))
    }

    // MARK: - Attach + observe

    private func attach(_ item: AVPlayerItem, uid: PhotoUID, initial: VideoViewerState) {
        didReachPlaying = false
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        if isStreaming {
            // Buffer well AHEAD of playback. Each ~4 MB block is a network fetch + decrypt round-trip through the
            // custom range loader; the default automatic buffer stayed too shallow for higher-bitrate video and
            // micro-stalled (~2 spinners/sec). A generous forward buffer lets the loader's read-ahead get in front
            // and stay there. (0 = automatic; we set an explicit window.)
            item.preferredForwardBufferDuration = 30
        }
        self.player = player
        transition(initial)
        logPlayer(item: item, player: player)

        let box = Weak(self)

        // AVPlayerItem.status — the primary readiness signal.
        observations.append(item.observe(\.status, options: [.new, .initial]) { observed, _ in
            let raw = observed.status.rawValue
            let err = observed.error
            Task { @MainActor in box.value?.onStatus(raw, error: err, uid: uid) }
        })
        // Buffer health — surfaces a real "buffering" reason instead of a frozen frame.
        observations.append(item.observe(\.isPlaybackBufferEmpty, options: [.new]) { observed, _ in
            let empty = observed.isPlaybackBufferEmpty
            Task { @MainActor in box.value?.onBufferEmpty(empty, uid: uid) }
        })
        observations.append(item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { observed, _ in
            let likely = observed.isPlaybackLikelyToKeepUp
            Task { @MainActor in box.value?.onLikelyToKeepUp(likely, uid: uid) }
        })
        observations.append(item.observe(\.loadedTimeRanges, options: [.new]) { observed, _ in
            let ranges = observed.loadedTimeRanges.map { $0.timeRangeValue }
            Task { @MainActor in box.value?.onLoadedRanges(ranges, uid: uid) }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { observed, _ in
            let raw = observed.timeControlStatus.rawValue
            Task { @MainActor in box.value?.onTimeControl(raw, uid: uid) }
        })

        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { note in
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            Task { @MainActor in box.value?.onFailedToPlayToEnd(err, uid: uid) }
        })
        notificationTokens.append(center.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { _ in
            Task { @MainActor in box.value?.onStalled(uid: uid) }
        })

        startWatchdog(uid: uid)
        player.play()
    }

    // MARK: - Observation handlers

    private func onStatus(_ raw: Int, error: Error?, uid: PhotoUID) {
        guard uid == currentUID, let player else { return }
        logPlayer(item: player.currentItem, player: player, error: error)
        guard let next = VideoPlayerItemStatus(rawValue: raw)?
            .nextState(error: error.map(VideoPlaybackError.classify)) else { return }
        switch next {
        case .playing:
            markPlaying()
        case .failed(let e):
            handleFailure(e, uid: uid)
        default:
            break
        }
    }

    private func onBufferEmpty(_ empty: Bool, uid: PhotoUID) {
        guard uid == currentUID, let player else { return }
        logPlayer(item: player.currentItem, player: player)   // buffering is driven by timeControlStatus
    }

    private func onLikelyToKeepUp(_ likely: Bool, uid: PhotoUID) {
        guard uid == currentUID else { return }
        // Secondary readiness path: some assets flip likelyToKeepUp before status==readyToPlay.
        if likely, !didReachPlaying { markPlaying() }
    }

    private func onLoadedRanges(_ ranges: [CMTimeRange], uid: PhotoUID) {
        guard uid == currentUID, let player else { return }
        logPlayer(item: player.currentItem, player: player)
    }

    /// After the first frame, `timeControlStatus` is the authoritative "is it actually moving?"
    /// signal — `.waitingToPlayAtSpecifiedRate` is a real stall (show buffering), `.playing` resumes,
    /// `.paused` is the user's own pause (clear any overlay; never a spinner). Before the first frame
    /// it's ignored so the status/likelyToKeepUp handoff isn't disturbed.
    private func onTimeControl(_ raw: Int, uid: PhotoUID) {
        guard uid == currentUID, let player else { return }
        logPlayer(item: player.currentItem, player: player)
        guard didReachPlaying else { return }
        switch player.timeControlStatus {
        case .waitingToPlayAtSpecifiedRate:
            transition(.buffering(nil))
        case .playing:
            transition(.playing)
        case .paused:
            if state.isBusy { transition(.playing) }   // user paused: hide overlay, native UI shows it
        @unknown default:
            break
        }
    }

    private func onFailedToPlayToEnd(_ error: NSError?, uid: PhotoUID) {
        guard uid == currentUID else { return }
        handleFailure(error.map(VideoPlaybackError.classify) ?? .playerItemFailed(detail: "failedToPlayToEnd"), uid: uid)
    }

    private func onStalled(uid: PhotoUID) {
        guard uid == currentUID, let player else { return }
        logPlayer(item: player.currentItem, player: player)
    }

    private func markPlaying() {
        didReachPlaying = true
        watchdog?.cancel(); watchdog = nil
        transition(.playing)
        player?.play()
        if let player { logPlayer(item: player.currentItem, player: player) }
    }

    /// A player-level failure is surfaced directly. We deliberately do not fall back to a full local video
    /// download: that would require a decrypted plaintext temp file, violating the app-wide local E2EE rule.
    private func handleFailure(_ error: VideoPlaybackError, uid: PhotoUID) {
        teardownKeepingState()
        transition(.failed(error))
    }

    // MARK: - Watchdog

    private func startWatchdog(uid: PhotoUID) {
        watchdog?.cancel()
        let deadline = firstFrameDeadline
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(deadline))
            guard let self, !Task.isCancelled else { return }
            guard self.currentUID == uid, !self.didReachPlaying else { return }
            PhotoDiagnostics.shared.emit("VideoPlayer", [
                "uid": self.key(uid), "event": "watchdogTimeout", "deadline": "\(Int(deadline))s",
            ])
            self.handleFailure(.timedOut, uid: uid)
        }
    }

    // MARK: - Teardown

    /// Full teardown: stops the player, removes observers, clears state owner.
    public func teardown() {
        watchdog?.cancel(); watchdog = nil
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
        player?.pause()
        player = nil
        streamingAsset = nil
        currentUID = nil
        didReachPlaying = false
        isStreaming = false
    }

    /// Tears down the player/observers but keeps `currentUID` so a `.failed` state stays attributed to
    /// the right item (used right before transitioning to `.failed`).
    private func teardownKeepingState() {
        let uid = currentUID
        teardown()
        currentUID = uid
    }

    // MARK: - State + logging

    private func transition(_ next: VideoViewerState) {
        guard state != next else { return }
        state = next
    }

    private func key(_ uid: PhotoUID) -> String { "\(uid.volumeID)~\(uid.nodeID)" }

    private func logPlayer(item: AVPlayerItem?, player: AVPlayer, error: Error? = nil) {
        guard let item else { return }
        let loaded = item.loadedTimeRanges
            .map { $0.timeRangeValue }
            .map { "\(String(format: "%.1f", $0.start.seconds))-\(String(format: "%.1f", ($0.start + $0.duration).seconds))" }
            .joined(separator: ",")
        let duration = item.duration.isNumeric ? String(format: "%.1f", item.duration.seconds) : "?"
        PhotoDiagnostics.shared.emit("VideoPlayer", [
            "uid": currentUID.map(key) ?? "-",
            "status": "\(item.status.rawValue)",
            "timeControl": "\(player.timeControlStatus.rawValue)",
            "bufferEmpty": "\(item.isPlaybackBufferEmpty)",
            "likelyToKeepUp": "\(item.isPlaybackLikelyToKeepUp)",
            "loadedTimeRanges": loaded.isEmpty ? "none" : loaded,
            "duration": duration,
            "state": state.label,
            "error": (error.map(VideoPlaybackError.classify)?.token) ?? state.error?.token ?? "none",
        ], throttleSeconds: 0.3)
    }
}

/// Sendable weak box so the `@Sendable` KVO / notification closures can hop back to the
/// `@MainActor` controller without capturing it directly under Swift 6 concurrency.
private final class Weak<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
