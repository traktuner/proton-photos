import Foundation

/// Resolves the correct on-disk file extension for an EXPORTED / SHARED original, from the best
/// available source in priority order.
///
/// Why this exists: the shared timeline `mediaType` is a lossy placeholder — `DriveSDKBridge`
/// collapses every image to `image/jpeg` and every video to `video/quicktime`, so an extension
/// derived from `PhotoItem.mediaType` alone mislabels a HEIC original as `.jpg` (the exact user bug
/// this fixes). This folds the *authoritative* signals — the real decrypted Proton link filename,
/// the true link MIME, and the original bytes' own magic-number signature — into one pure,
/// value-only decision that both the iOS and macOS export paths share.
///
/// Pure Foundation: no file I/O (callers pass the leading bytes), no `UniformTypeIdentifiers`/ImageIO
/// (would break the PhotosCore cross-platform import allowlist), no platform UI — so it is fully
/// unit-testable with byte fixtures (`OriginalFileNamingTests`). Byte sniffing reuses
/// ``VideoContentSniffer`` so there is one magic-number source of truth.
public enum OriginalFileNaming {

    /// Canonical lowercased MIME → extension (no dot). The reverse of
    /// ``UploadCore.SupportedMedia.table``; kept here so Core export naming never depends on the
    /// system UTI database (deterministic across machines and CI).
    public static let extensionForMIME: [String: String] = [
        "image/jpeg": "jpg",
        "image/jpg": "jpg",
        "image/png": "png",
        "image/heic": "heic",
        "image/heif": "heif",
        "image/heic-sequence": "heic",
        "image/heif-sequence": "heif",
        "image/avif": "avif",
        "image/tiff": "tiff",
        "image/webp": "webp",
        "image/gif": "gif",
        "image/bmp": "bmp",
        "image/x-adobe-dng": "dng",
        "video/quicktime": "mov",
        "video/mp4": "mp4",
        "video/x-m4v": "m4v",
        "video/mpeg": "mpg",
        "video/webm": "webm",
        "video/x-matroska": "mkv",
    ]

    /// The MIME types the SDK timeline stamps on EVERY item. They are too generic to trust for a
    /// concrete extension whenever a stronger signal (a real filename or the byte signature) exists —
    /// otherwise a HEIC would be labelled `.jpg`.
    public static let placeholderMIMETypes: Set<String> = ["image/jpeg", "video/quicktime"]

    /// Media extensions we will accept verbatim from a real Proton filename (`IMG_0001.HEIC` →
    /// `heic`). Union of the image + video extensions ``VideoContentSniffer`` recognises.
    public static let knownMediaExtensions: Set<String> = VideoContentSniffer.videoExtensions.union([
        "jpg", "jpeg", "png", "heic", "heif", "avif", "gif", "webp", "tiff", "tif", "bmp", "dng", "raw",
    ])

    // MARK: - Public API

    /// The best-source export extension (lowercased, no dot), or `nil` if nothing could be resolved
    /// (the caller then supplies a last-resort default). Resolution order:
    /// 1. the real `filename`'s own extension when it is a recognised media extension — it IS the
    ///    original name, so it is the most authoritative signal;
    /// 2. a *trustworthy* `mimeType`: present, mapped, and NOT the generic timeline placeholder;
    /// 3. the `header` bytes' magic-number signature — recovers HEIC/PNG/MP4/… when the MIME is the
    ///    `image/jpeg` / `video/quicktime` placeholder (the "mediaType lies" case);
    /// 4. the placeholder `mimeType` mapped anyway (e.g. a genuine JPEG with no bytes to sniff);
    /// 5. `fallbackMediaType` (the timeline `PhotoItem.mediaType`) mapped — last resort before `nil`.
    public static func fileExtension(
        filename: String?,
        mimeType: String?,
        header: Data?,
        fallbackMediaType: String? = nil
    ) -> String? {
        // 1. Real filename extension (authoritative — this is the original's own name).
        if let ext = recognizedExtension(fromFilename: filename) { return ext }

        // 2. Trustworthy metadata MIME (skip the generic timeline placeholder).
        if let mime = normalizedMIME(mimeType), !placeholderMIMETypes.contains(mime),
           let ext = extensionForMIME[mime] {
            return ext
        }

        // 3. Byte signature — the ground truth when the MIME is the placeholder.
        if let header, let ext = extensionForHeader(header) { return ext }

        // 4. Placeholder MIME mapped anyway (genuine JPEG/MOV with nothing better available).
        if let mime = normalizedMIME(mimeType), let ext = extensionForMIME[mime] { return ext }

        // 5. Timeline mediaType as the final mapped source.
        if let mime = normalizedMIME(fallbackMediaType), let ext = extensionForMIME[mime] { return ext }

        return nil
    }

    /// Convenience: the export extension with a guaranteed value. Falls back to `mov` for anything
    /// that looks like a video, else `jpg` — the same last-resort the iOS/macOS paths used before.
    public static func resolvedExtension(
        filename: String?,
        mimeType: String?,
        header: Data?,
        fallbackMediaType: String?,
        isVideo: Bool
    ) -> String {
        if let ext = fileExtension(
            filename: filename, mimeType: mimeType, header: header, fallbackMediaType: fallbackMediaType
        ) {
            return ext
        }
        return isVideo ? "mov" : "jpg"
    }

    /// The recognised media extension carried by a real filename, lowercased (no dot), or `nil` when
    /// the name is empty / has no extension / the extension isn't a known media type.
    public static func recognizedExtension(fromFilename filename: String?) -> String? {
        guard let filename, !filename.isEmpty else { return nil }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, knownMediaExtensions.contains(ext) else { return nil }
        return ext
    }

    /// The concrete extension for a media file from its leading bytes, or `nil` if unrecognised.
    /// Distinguishes still-image ISO-BMFF brands (HEIC/HEIF/AVIF) from playable video containers
    /// (MOV/MP4) — the distinction `PhotoItem.mediaType` cannot make.
    public static func extensionForHeader(_ rawHeader: Data) -> String? {
        // Rebase to a fresh 0-indexed buffer so subscripting is safe regardless of how the caller
        // sliced the Data, and bound the work to the signature region.
        let head = Data(rawHeader.prefix(32))
        guard head.count >= 4 else { return nil }

        // ISO-BMFF `ftyp`: split still-image brands from video containers.
        if head.count >= 12, head.subdata(in: 4 ..< 8).elementsEqual(Data("ftyp".utf8)) {
            let brand = (String(data: head.subdata(in: 8 ..< 12), encoding: .ascii) ?? "").lowercased()
            if brand.hasPrefix("heic") || brand.hasPrefix("heix") || brand.hasPrefix("hevc") || brand.hasPrefix("hevx") {
                return "heic"
            }
            if brand.hasPrefix("mif1") || brand.hasPrefix("msf1") || brand.hasPrefix("heif") { return "heif" }
            if brand.hasPrefix("avif") || brand.hasPrefix("avis") { return "avif" }
            // Anything else that is an ftyp box is a playable video container (qt→mov, else mp4).
            return VideoContentSniffer.videoExtension(forHeader: head)
        }

        // JPEG FF D8 FF
        if head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return "jpg" }
        // PNG 89 50 4E 47
        if head[0] == 0x89, head[1] == 0x50, head[2] == 0x4E, head[3] == 0x47 { return "png" }
        // GIF "GIF8"
        if head.prefix(4).elementsEqual(Data("GIF8".utf8)) { return "gif" }
        // TIFF little-endian "II*\0" / big-endian "MM\0*" (also the container of most camera RAW/DNG)
        if head[0] == 0x49, head[1] == 0x49, head[2] == 0x2A, head[3] == 0x00 { return "tiff" }
        if head[0] == 0x4D, head[1] == 0x4D, head[2] == 0x00, head[3] == 0x2A { return "tiff" }
        // WebP: "RIFF" .... "WEBP"
        if head.count >= 12, head.prefix(4).elementsEqual(Data("RIFF".utf8)),
           head.subdata(in: 8 ..< 12).elementsEqual(Data("WEBP".utf8)) {
            return "webp"
        }
        // Matroska / WebM: 1A 45 DF A3
        if head[0] == 0x1A, head[1] == 0x45, head[2] == 0xDF, head[3] == 0xA3 { return "mkv" }
        return nil
    }

    // MARK: - Private

    /// Lowercases + trims a MIME and strips any `; charset=…` parameter, or `nil` when empty.
    private static func normalizedMIME(_ mime: String?) -> String? {
        guard let mime else { return nil }
        let base = mime.split(separator: ";").first.map(String.init) ?? mime
        let trimmed = base.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
