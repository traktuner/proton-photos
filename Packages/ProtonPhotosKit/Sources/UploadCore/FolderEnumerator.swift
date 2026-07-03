import Foundation

/// Result of walking a folder for uploadable media.
public struct FolderEnumerationResult: Sendable, Equatable {
    /// Supported photo/video files, in deterministic (path-sorted) order.
    public var mediaFiles: [URL]
    /// Files that were found but skipped because their type isn't supported (reported, not silently dropped).
    public var skippedUnsupported: [URL]

    public init(mediaFiles: [URL] = [], skippedUnsupported: [URL] = []) {
        self.mediaFiles = mediaFiles
        self.skippedUnsupported = skippedUnsupported
    }
}

/// Recursively discovers uploadable media inside a folder.
///
/// Rules: hidden files are skipped by default; package bundles (`.app`, `.photoslibrary`, …) are not descended
/// into; only supported media types are returned; order is deterministic
/// (case-insensitive path sort) so the queue is reproducible.
public enum FolderEnumerator {
    public static func enumerate(
        _ folder: URL,
        includeHidden: Bool = false,
        fileManager: FileManager = .default
    ) -> FolderEnumerationResult {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !includeHidden { options.insert(.skipsHiddenFiles) }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return FolderEnumerationResult()
        }

        var media: [URL] = []
        var skipped: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            // Don't descend into packages presented as files (belt-and-suspenders alongside the option).
            if values?.isPackage == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if SupportedMedia.isSupported(url) {
                media.append(url)
            } else {
                skipped.append(url)
            }
        }

        let sort: (URL, URL) -> Bool = {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
        return FolderEnumerationResult(
            mediaFiles: media.sorted(by: sort),
            skippedUnsupported: skipped.sorted(by: sort)
        )
    }
}
