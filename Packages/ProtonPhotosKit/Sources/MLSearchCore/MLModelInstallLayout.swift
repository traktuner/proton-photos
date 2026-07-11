import Foundation

/// On-disk layout of all Smart Search state for one account.
///
/// Everything Smart Search persists lives under one root directory:
///
/// ```
/// <root>/                            (e.g. …/Application Support/ProtonPhotos/<uid>/SmartSearch)
///   state.json                       lifecycle state (enabled, selection, journal)
///   ml-search-index-v1.sqlite(+wal/shm)  encrypted vector index
///   models/<modelID>/<revision>/     verified installed artifacts + install.json
///   tmp/                             partial downloads and staging dirs
/// ```
///
/// Purge deletes the root recursively — the single-root invariant is what makes "no known ML
/// artifact remains" provable. Nothing outside the root may ever be written by Smart Search,
/// and nothing inside it is shared with any other subsystem.
public struct MLModelInstallLayout: Sendable, Equatable {
    public static let installRecordFileName = "install.json"
    public static let stateFileName = "state.json"

    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public var stateFileURL: URL { rootDirectory.appendingPathComponent(Self.stateFileName) }
    public var modelsDirectory: URL { rootDirectory.appendingPathComponent("models", isDirectory: true) }
    public var temporaryDirectory: URL { rootDirectory.appendingPathComponent("tmp", isDirectory: true) }
    public var indexDatabaseURL: URL { rootDirectory.appendingPathComponent(SQLiteMLIndexStore.databaseFileName) }

    /// SQLite sidecar files that must be part of any purge inventory.
    public var indexDatabaseFileURLs: [URL] {
        ["", "-wal", "-shm"].map { URL(fileURLWithPath: indexDatabaseURL.path + $0) }
    }

    public func modelDirectory(for id: MLModelID) -> URL {
        modelsDirectory.appendingPathComponent(safePathComponent(id.rawValue), isDirectory: true)
    }

    public func installDirectory(for id: MLModelID, revision: String) -> URL {
        modelDirectory(for: id).appendingPathComponent(safePathComponent(revision), isDirectory: true)
    }

    public func installRecordURL(for id: MLModelID, revision: String) -> URL {
        installDirectory(for: id, revision: revision).appendingPathComponent(Self.installRecordFileName)
    }

    /// Staging directory an install is assembled in before its atomic promotion.
    public func stagingDirectory(for id: MLModelID, revision: String) -> URL {
        temporaryDirectory.appendingPathComponent(
            "staging-\(safePathComponent(id.rawValue))-\(safePathComponent(revision))",
            isDirectory: true
        )
    }

    /// `true` iff `path` is a safe install-relative path: non-empty, relative, and free of
    /// `.`/`..` components. Manifest file names must pass this before touching the filesystem.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Flattens an identifier into one path component (defense in depth: catalog IDs and
    /// revisions are trusted, but never become nested paths).
    private func safePathComponent(_ raw: String) -> String {
        String(raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" })
    }
}
