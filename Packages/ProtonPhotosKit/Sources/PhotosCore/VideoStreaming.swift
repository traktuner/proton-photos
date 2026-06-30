import Foundation
import AVFoundation

/// A ready-to-play streaming video asset whose bytes are fetched + decrypted on demand (range
/// requests), so playback starts almost immediately instead of waiting for a full download.
///
/// Holds the `AVURLAsset` plus the object that must stay alive for the custom resource loader to
/// keep serving (AVFoundation holds the resource-loader delegate weakly). Keep a strong reference
/// to this for as long as the player is in use.
public final class StreamingVideoAsset: @unchecked Sendable {
    public let asset: AVURLAsset
    private let retained: AnyObject

    public init(asset: AVURLAsset, retaining: AnyObject) {
        self.asset = asset
        self.retained = retaining
    }
}

/// Signals raised by a `VideoStreamProvider`. `.notAVideo` lets the viewer tell "this item is an
/// image, use the image path" apart from "streaming a real video failed, fall back to download".
public enum VideoStreamError: Error {
    case notAVideo
}

/// Optional backend capability: stream a video with range-based buffering instead of a full
/// download. The viewer uses this when available and falls back to `FullMediaProvider` otherwise,
/// so playback never breaks if streaming setup fails.
public protocol VideoStreamProvider: Sendable {
    func makeStreamingAsset(for uid: PhotoUID) async throws -> StreamingVideoAsset
    /// Fully downloads + caches the clip's ENCRYPTED blocks locally (never plaintext), so a subsequent
    /// `makeStreamingAsset` plays instantly from the local encrypted cache. Used for Live Photo motion, which
    /// must be 100% loaded before hover/click plays it (unlike streamed timeline videos). Default: no-op.
    func prefetchEncrypted(for uid: PhotoUID) async throws
}

public extension VideoStreamProvider {
    func prefetchEncrypted(for uid: PhotoUID) async throws {}   // optional capability
}
