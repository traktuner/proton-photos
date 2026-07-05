import Foundation

/// Classifies local files into Proton-uploadable photo/video media. Kept as an explicit, testable
/// extension→MIME map (rather than relying on the system UTI database) so folder enumeration is
/// deterministic across machines and CI. Unknown extensions are treated as unsupported and skipped.
public enum SupportedMedia {
    public enum Kind: Sendable, Equatable {
        case image
        case video
    }

    /// Lowercased file extension → (kind, MIME type).
    public static let table: [String: (kind: Kind, mime: String)] = [
        // Images
        "jpg":  (.image, "image/jpeg"),
        "jpeg": (.image, "image/jpeg"),
        "png":  (.image, "image/png"),
        "heic": (.image, "image/heic"),
        "heif": (.image, "image/heif"),
        "dng":  (.image, "image/x-adobe-dng"),
        "tif":  (.image, "image/tiff"),
        "tiff": (.image, "image/tiff"),
        "webp": (.image, "image/webp"),
        "gif":  (.image, "image/gif"),
        "bmp":  (.image, "image/bmp"),
        // Videos
        "mov":  (.video, "video/quicktime"),
        "mp4":  (.video, "video/mp4"),
        "m4v":  (.video, "video/x-m4v"),
    ]

    /// The MIME type for a URL, or nil if the extension isn't a supported media type.
    public static func mimeType(for url: URL) -> String? {
        table[url.pathExtension.lowercased()]?.mime
    }

    public static func kind(for url: URL) -> Kind? {
        table[url.pathExtension.lowercased()]?.kind
    }

    public static func isSupported(_ url: URL) -> Bool {
        table[url.pathExtension.lowercased()] != nil
    }
}
