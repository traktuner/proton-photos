import Foundation

/// Explicit lifecycle of the full-screen video path (Deliverable 5). The viewer drives the UI from
/// this instead of inferring "is it loading?" from a tangle of optionals, so a stuck spinner or a
/// silent black frame becomes an observable, loggable state with a reason.
public enum VideoViewerState: Equatable, Sendable {
    case idle                       // not a video / nothing to play yet
    case resolving                  // fetching the link + keys, deciding stream vs download
    case downloading(Double)        // full-download fallback in progress (0…1)
    case ready                      // a playable AVPlayer exists, awaiting first frame
    case playing                    // AVPlayerItem reached .readyToPlay and playback started
    case failed(String)             // gave up — message is shown to the user + logged

    public var label: String {
        switch self {
        case .idle: return "idle"
        case .resolving: return "resolving"
        case .downloading: return "downloading"
        case .ready: return "ready"
        case .playing: return "playing"
        case .failed: return "failed"
        }
    }

    public var progress: Double {
        switch self {
        case .downloading(let p): return p
        case .playing, .ready: return 1
        default: return 0
        }
    }

    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    /// True while the viewer should show a loading affordance (spinner / percentage).
    public var isBusy: Bool {
        switch self {
        case .resolving, .downloading: return true
        default: return false
        }
    }
}

/// Maps an `AVPlayerItem.status` raw value (0 unknown, 1 readyToPlay, 2 failed) onto the viewer
/// state. Pure so the transition is testable without spinning up AVFoundation.
public enum VideoPlayerItemStatus: Int, Sendable {
    case unknown = 0
    case readyToPlay = 1
    case failed = 2

    public func nextState(error: String?) -> VideoViewerState? {
        switch self {
        case .unknown: return nil                       // keep current state
        case .readyToPlay: return .playing
        case .failed: return .failed(error ?? "Video konnte nicht abgespielt werden.")
        }
    }
}

/// Builds the `[VideoViewer]` diagnostic line (Deliverable 5 logging contract).
public func videoViewerLogFields(
    uid: PhotoUID,
    state: VideoViewerState,
    localURLExists: Bool,
    assetPlayable: Bool,
    playerItemStatus: Int,
    error: String?
) -> [String: String] {
    [
        "uid": "\(uid.volumeID)~\(uid.nodeID)",
        "state": state.label,
        "progress": String(format: "%.2f", state.progress),
        "localURLExists": "\(localURLExists)",
        "assetPlayable": "\(assetPlayable)",
        "playerItemStatus": "\(playerItemStatus)",
        "error": error ?? "none",
    ]
}
