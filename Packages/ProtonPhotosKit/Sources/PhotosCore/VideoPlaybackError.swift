import Foundation

/// Every way the native video path can fail, mapped to a stable case so the UI can show a readable
/// reason (never an infinite spinner) and diagnostics can log a consistent token. Mirrors the
/// failure surface Proton Drive Web reports for its streaming preview (broken-video / SW-timeout /
/// first-block-timeout / decrypt failure), translated to AVFoundation terms.
public enum VideoPlaybackError: Error, Equatable, Sendable {
    /// The opened item turned out not to be a video (server/content says image) — caller falls back
    /// to the image path. Not user-visible.
    case notVideo
    /// File/link metadata (size, block map, content key) could not be resolved.
    case metadataUnavailable
    /// AVFoundation reached `.failed` with a codec/format it cannot decode.
    case unsupportedCodec
    /// Backend exposes no stream URL and no range path.
    case streamURLUnavailable
    /// The backend cannot serve byte ranges, so progressive streaming is impossible.
    case rangeNotSupported
    /// A block failed to decrypt (wrong key / corrupt packet).
    case decryptionFailed
    /// No network / transport error while fetching bytes.
    case networkUnavailable
    /// Auth expired and could not be refreshed.
    case authExpired
    /// Server returned 429 / quota / rate-limit.
    case quotaOrRateLimited
    /// A local cache/temp file could not be written or read.
    case localFileError
    /// `AVPlayerItem.status` became `.failed` (generic player error) — `detail` carries the AVError.
    case playerItemFailed(detail: String?)
    /// The player never became ready / stalled past the watchdog deadline with no recoverable reason.
    case timedOut
    /// Anything not otherwise classified — `detail` carries the original description.
    case unknown(detail: String?)

    /// Readable, user-facing message, localized via the package String Catalog.
    public var userMessage: String {
        switch self {
        case .notVideo: return L10n.string("error.video.not_a_video")
        case .metadataUnavailable: return L10n.string("error.video.metadata_unavailable")
        case .unsupportedCodec: return L10n.string("error.video.unsupported_codec")
        case .streamURLUnavailable: return L10n.string("error.video.stream_unavailable")
        case .rangeNotSupported: return L10n.string("error.video.range_not_supported")
        case .decryptionFailed: return L10n.string("error.video.decryption_failed")
        case .networkUnavailable: return L10n.string("error.video.network_unavailable")
        case .authExpired: return L10n.string("error.video.auth_expired")
        case .quotaOrRateLimited: return L10n.string("error.video.quota_rate_limited")
        case .localFileError: return L10n.string("error.video.local_file_error")
        case .playerItemFailed: return L10n.string("error.video.player_item_failed")
        case .timedOut: return L10n.string("error.video.timed_out")
        case .unknown: return L10n.string("error.video.unknown")
        }
    }

    /// Stable token for the `[VideoViewer]`/`[VideoPlayer]` diagnostic `error=` field.
    public var token: String {
        switch self {
        case .notVideo: return "notVideo"
        case .metadataUnavailable: return "metadataUnavailable"
        case .unsupportedCodec: return "unsupportedCodec"
        case .streamURLUnavailable: return "streamURLUnavailable"
        case .rangeNotSupported: return "rangeNotSupported"
        case .decryptionFailed: return "decryptionFailed"
        case .networkUnavailable: return "networkUnavailable"
        case .authExpired: return "authExpired"
        case .quotaOrRateLimited: return "quotaOrRateLimited"
        case .localFileError: return "localFileError"
        case .playerItemFailed(let d): return "playerItemFailed(\(d ?? "-"))"
        case .timedOut: return "timedOut"
        case .unknown(let d): return "unknown(\(d ?? "-"))"
        }
    }

    /// Whether it's worth offering a "Retry" affordance (transient failures) vs. a hard "no" (codec).
    public var isRetryable: Bool {
        switch self {
        case .unsupportedCodec, .notVideo: return false
        default: return true
        }
    }
}

public extension VideoPlaybackError {
    /// Classifies an arbitrary `Error` (NSURLError / Proton API error / AVError) into a playback
    /// error. Kept pure (string/NSError based) so it's unit-testable without AVFoundation. The
    /// network/HTTP heuristics match the codes the app's `DriveSession` raises.
    static func classify(_ error: Error) -> VideoPlaybackError {
        let ns = error as NSError

        // URLSession transport failures.
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                return .networkUnavailable
            default:
                return .networkUnavailable
            }
        }

        // AVFoundation media errors.
        if ns.domain == "AVFoundationErrorDomain" {
            // -11828 mediaFormatNotRecognized, -11833 unsupported, -11839 cannotDecode, etc.
            let unsupported: Set<Int> = [-11828, -11829, -11833, -11839, -11850]
            if unsupported.contains(ns.code) { return .unsupportedCodec }
            return .playerItemFailed(detail: "AV\(ns.code)")
        }

        // Cocoa file errors.
        if ns.domain == NSCocoaErrorDomain {
            return .localFileError
        }

        // HTTP status surfaced by the app's API layer (message contains "HTTP <code>").
        let text = ns.localizedDescription
        if let code = httpStatus(in: text) {
            switch code {
            case 401: return .authExpired
            case 429: return .quotaOrRateLimited
            case 416: return .rangeNotSupported
            case 404, 410: return .streamURLUnavailable
            default: break
            }
        }
        let lower = text.lowercased()
        if lower.contains("decrypt") { return .decryptionFailed }
        if lower.contains("not a video") || lower.contains("notavideo") { return .notVideo }
        return .unknown(detail: text)
    }

    private static func httpStatus(in text: String) -> Int? {
        guard let range = text.range(of: "HTTP ") else { return nil }
        let tail = text[range.upperBound...].prefix(3)
        return Int(tail)
    }
}
