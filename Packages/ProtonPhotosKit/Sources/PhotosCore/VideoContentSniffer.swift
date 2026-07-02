import Foundation

/// How an item was classified, and by which signal - so the viewer can decide stream-vs-image and
/// diagnostics can record *why*. The main "All Photos" timeline reports everything as `image/jpeg`
/// (the SDK doesn't surface the real type), so the viewer can't trust `mediaType` alone; this folds
/// MIME + filename extension + a content sniff into one decision.
public enum MediaKind: String, Sendable, Equatable {
    case image
    case video
    case unknown
}

/// Pure content/type detection. No file I/O - callers pass the leading bytes - so it's fully
/// unit-testable (ExtensionSniffingTest / VideoDetectionTest).
public enum VideoContentSniffer {
    /// Known video filename extensions (lowercased, no dot).
    public static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "qt", "avi", "mkv", "webm", "3gp", "mpg", "mpeg", "m2ts", "mts"
    ]

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "dng", "raw"
    ]

    /// ISO-BMFF brands that are still images (HEIC/HEIF/AVIF), not playable video containers.
    private static let imageBrands = ["heic", "heix", "heif", "mif1", "msf1", "avif"]

    /// Returns the playable container extension ("mov"/"mp4") sniffed from an ISO-BMFF `ftyp` header,
    /// or `nil` if the bytes aren't a recognized MP4/QuickTime container. AVFoundation opens
    /// extensionless temp files unreliably, so the download path uses this to give the file a real
    /// extension before handing it to `AVURLAsset`.
    public static func videoExtension(forHeader head: Data) -> String? {
        guard head.count >= 12 else { return nil }
        let box = head.subdata(in: 4..<8)
        guard let boxStr = String(data: box, encoding: .ascii), boxStr == "ftyp" else { return nil }
        let brand = (String(data: head.subdata(in: 8..<12), encoding: .ascii) ?? "").lowercased()
        // HEIC/HEIF/AVIF are ISO-BMFF too but are still images, not playable video containers.
        if imageBrands.contains(where: { brand.hasPrefix($0) }) { return nil }
        return brand.hasPrefix("qt") ? "mov" : "mp4"
    }

    /// True if the leading bytes look like a video container (ISO-BMFF `ftyp`, or other common
    /// signatures we may meet: Matroska/WebM, AVI/RIFF).
    public static func headerIsVideo(_ head: Data) -> Bool {
        if videoExtension(forHeader: head) != nil { return true }
        if head.count >= 4 {
            // EBML (Matroska/WebM): 1A 45 DF A3
            if head[0] == 0x1A, head[1] == 0x45, head[2] == 0xDF, head[3] == 0xA3 { return true }
            // RIFF (....AVI ): "RIFF"
            if let riff = String(data: head.prefix(4), encoding: .ascii), riff == "RIFF" { return true }
        }
        return false
    }

    /// Whether the header decodes as a still image (JPEG/PNG/GIF/HEIF magic bytes).
    public static func headerIsImage(_ head: Data) -> Bool {
        guard head.count >= 4 else { return false }
        // JPEG FF D8 FF
        if head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return true }
        // PNG 89 50 4E 47
        if head[0] == 0x89, head[1] == 0x50, head[2] == 0x4E, head[3] == 0x47 { return true }
        // GIF "GIF8"
        if let gif = String(data: head.prefix(4), encoding: .ascii), gif == "GIF8" { return true }
        // HEIF/HEIC: ftyp with an heic/mif1/heix/hevc brand
        if head.count >= 12, let box = String(data: head.subdata(in: 4..<8), encoding: .ascii), box == "ftyp" {
            let brand = (String(data: head.subdata(in: 8..<12), encoding: .ascii) ?? "").lowercased()
            if brand.hasPrefix("heic") || brand.hasPrefix("heix") || brand.hasPrefix("mif1") || brand.hasPrefix("msf1") {
                return true
            }
        }
        return false
    }

    /// Classifies by MIME type alone (when trustworthy). Returns `.unknown` for the generic
    /// `image/jpeg` placeholder the timeline stamps on every item - forcing a content check.
    public static func kind(mimeType: String?) -> MediaKind {
        guard let m = mimeType?.lowercased(), !m.isEmpty else { return .unknown }
        if m.hasPrefix("video/") { return .video }
        if m.hasPrefix("image/") { return .image }
        return .unknown
    }

    /// Classifies by filename extension.
    public static func kind(filename: String?) -> MediaKind {
        guard let name = filename, let ext = name.split(separator: ".").last.map({ $0.lowercased() }) else {
            return .unknown
        }
        if videoExtensions.contains(ext) { return .video }
        if imageExtensions.contains(ext) { return .image }
        return .unknown
    }

    /// Combined best-effort classification: trust an explicit MIME/extension, else sniff the header.
    /// Used to decide stream-vs-image when the timeline's `mediaType` can't be trusted.
    public static func classify(mimeType: String?, filename: String?, header: Data?) -> MediaKind {
        let byMime = kind(mimeType: mimeType)
        if byMime != .unknown { return byMime }
        let byName = kind(filename: filename)
        if byName != .unknown { return byName }
        if let head = header {
            if headerIsVideo(head) { return .video }
            if headerIsImage(head) { return .image }
        }
        return .unknown
    }
}
