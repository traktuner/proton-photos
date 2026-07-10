import CryptoKit
import Foundation

/// Byte transport for one artifact download. Implementations (URLSession in the Apple adapter,
/// scripted fakes in tests) write the complete artifact to `destination`, reporting progress as
/// `(bytesReceived, expectedTotalBytes?)`. They may resume a partial file already present at
/// `destination`; correctness never depends on it because the installer verifies size and
/// SHA-256 before any byte becomes visible to the model loader.
public protocol MLModelArtifactTransport: Sendable {
    func download(
        from url: URL,
        to destination: URL,
        expectedByteCount: Int64,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws
}

public enum MLModelInstallError: Error, Equatable {
    case unsafeArtifactPath(String)
    case sizeMismatch(artifact: String, expected: Int64, actual: Int64)
    case checksumMismatch(artifact: String)
    case artifactMissing(String)
    case installRecordUnreadable
    case notDownloadable
    case cancelled
}

/// Durable record written into an install directory after every artifact verified. Its presence
/// (with matching specs) is the definition of "installed"; a directory without it is garbage
/// from an interrupted install and gets cleaned up.
public struct MLModelInstallRecord: Sendable, Equatable, Codable {
    public let modelID: MLModelID
    public let revision: String
    public let artifacts: [MLModelArtifactSpec]
    public let installedByteCount: Int64
    public let installedAt: Date

    public init(modelID: MLModelID, revision: String, artifacts: [MLModelArtifactSpec], installedByteCount: Int64, installedAt: Date) {
        self.modelID = modelID
        self.revision = revision
        self.artifacts = artifacts
        self.installedByteCount = installedByteCount
        self.installedAt = installedAt
    }
}

/// A verified, activated installation the runtime may load.
public struct MLInstalledModel: Sendable, Equatable {
    public let entry: MLModelCatalogEntry
    public let record: MLModelInstallRecord
    /// Directory containing the verified artifacts.
    public let installDirectory: URL

    public init(entry: MLModelCatalogEntry, record: MLModelInstallRecord, installDirectory: URL) {
        self.entry = entry
        self.record = record
        self.installDirectory = installDirectory
    }
}

/// Download/verify/install progress for one model, coalesced for UI.
public struct MLModelTransferProgress: Sendable, Equatable {
    public var bytesReceived: Int64
    public var totalBytes: Int64?

    public init(bytesReceived: Int64 = 0, totalBytes: Int64? = nil) {
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
    }

    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(totalBytes))
    }
}

/// Downloads, verifies and atomically installs model artifacts.
///
/// Guarantees:
/// - **Verified before visible.** Every artifact's size and SHA-256 must match its pinned spec
///   before the staging directory is promoted; the install directory either contains a complete
///   verified set plus `install.json`, or it does not exist.
/// - **Idempotent.** Installing an already-installed `(model, revision)` returns immediately.
/// - **Restart-safe.** Partial downloads live in `tmp/` keyed by content hash; interrupted
///   staging directories are discarded and rebuilt. Nothing in `tmp/` is ever loaded.
/// - **Single-flight.** Concurrent install requests for the same model await one task.
/// - **Traversal-proof.** Artifact relative paths are validated before any filesystem use.
public actor MLModelInstaller {
    private let layout: MLModelInstallLayout
    private let transport: any MLModelArtifactTransport
    private let now: @Sendable () -> Date
    private var inFlight: [MLModelID: Task<MLModelInstallRecord, Error>] = [:]

    public init(
        layout: MLModelInstallLayout,
        transport: any MLModelArtifactTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.layout = layout
        self.transport = transport
        self.now = now
    }

    /// The verified installation for `entry` at `revision`, or `nil` when none exists.
    /// Never trusts a directory without a matching, fully verifiable `install.json`.
    public nonisolated func installedRecord(for entry: MLModelCatalogEntry, revision: String) -> MLModelInstallRecord? {
        Self.readVerifiedRecord(
            at: layout.installRecordURL(for: entry.id, revision: revision),
            expecting: entry.id,
            revision: revision,
            installDirectory: layout.installDirectory(for: entry.id, revision: revision)
        )
    }

    /// Any verified installation for `entry`, regardless of revision (newest first).
    public nonisolated func anyInstalledRecord(for entry: MLModelCatalogEntry) -> MLModelInstallRecord? {
        let modelDir = layout.modelDirectory(for: entry.id)
        guard let revisions = try? FileManager.default.contentsOfDirectory(atPath: modelDir.path) else { return nil }
        return revisions
            .compactMap { revision in
                Self.readVerifiedRecord(
                    at: layout.installRecordURL(for: entry.id, revision: revision),
                    expecting: entry.id,
                    revision: revision,
                    installDirectory: layout.installDirectory(for: entry.id, revision: revision)
                )
            }
            .max { $0.installedAt < $1.installedAt }
    }

    /// Download and install `entry` from its pinned plan. Progress covers download bytes only;
    /// verification/installation are separate lifecycle phases.
    public func install(
        _ entry: MLModelCatalogEntry,
        onProgress: @escaping @Sendable (MLModelTransferProgress) -> Void
    ) async throws -> MLModelInstallRecord {
        guard let plan = entry.downloadPlan else { throw MLModelInstallError.notDownloadable }

        if let existing = inFlight[entry.id] {
            return try await existing.value
        }
        if let installed = installedRecord(for: entry, revision: plan.revision) {
            return installed
        }

        let layout = self.layout
        let transport = self.transport
        let now = self.now
        let task = Task {
            try await Self.performInstall(
                entry: entry,
                plan: plan,
                layout: layout,
                transport: transport,
                now: now,
                onProgress: onProgress
            )
        }
        inFlight[entry.id] = task
        defer { inFlight[entry.id] = nil }
        return try await task.value
    }

    /// Install `entry` by copying a developer-provided local artifact directory. Checksums are
    /// computed from the local content (there is no pinned upstream), so the install record
    /// stays self-verifying. Revision is derived from the content hashes.
    public func installFromLocalArtifact(
        _ entry: MLModelCatalogEntry,
        artifactDirectory: URL
    ) async throws -> MLModelInstallRecord {
        let fm = FileManager.default
        guard fm.fileExists(atPath: artifactDirectory.path) else {
            throw MLModelInstallError.artifactMissing(artifactDirectory.lastPathComponent)
        }
        var specs: [MLModelArtifactSpec] = []
        let files = try Self.regularFiles(under: artifactDirectory)
        guard !files.isEmpty else { throw MLModelInstallError.artifactMissing(artifactDirectory.lastPathComponent) }
        for relativePath in files.sorted() {
            guard MLModelInstallLayout.isSafeRelativePath(relativePath) else {
                throw MLModelInstallError.unsafeArtifactPath(relativePath)
            }
            let fileURL = artifactDirectory.appendingPathComponent(relativePath)
            let digest = try Self.sha256Hex(of: fileURL)
            let size = try Self.fileSize(of: fileURL)
            specs.append(MLModelArtifactSpec(relativePath: relativePath, sha256: digest, byteCount: size))
        }
        // Deterministic content revision: hash of the sorted per-file hashes.
        let combined = specs.map { "\($0.relativePath):\($0.sha256)" }.joined(separator: "\n")
        let revision = "local-" + SHA256.hash(data: Data(combined.utf8)).compactMap { String(format: "%02x", $0) }.joined().prefix(16)

        if let installed = installedRecord(for: entry, revision: String(revision)) {
            return installed
        }

        let staging = layout.stagingDirectory(for: entry.id, revision: String(revision))
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for spec in specs {
            let destination = staging.appendingPathComponent(spec.relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: artifactDirectory.appendingPathComponent(spec.relativePath), to: destination)
        }
        return try Self.promote(
            staging: staging,
            entry: entry,
            revision: String(revision),
            specs: specs,
            layout: layout,
            installedAt: now()
        )
    }

    /// Remove every installed revision of `entry` (used after model switches and on purge).
    public func uninstall(_ entry: MLModelCatalogEntry) {
        inFlight[entry.id]?.cancel()
        inFlight[entry.id] = nil
        try? FileManager.default.removeItem(at: layout.modelDirectory(for: entry.id))
    }

    /// Cancel an in-flight install, if any. Partial downloads stay in `tmp/` for a later
    /// resume/restart; they are never loadable and vanish on purge.
    public func cancelInstall(of id: MLModelID) {
        inFlight[id]?.cancel()
        inFlight[id] = nil
    }

    // MARK: - Install pipeline (static: no actor hops during I/O)

    private static func performInstall(
        entry: MLModelCatalogEntry,
        plan: MLModelDownloadPlan,
        layout: MLModelInstallLayout,
        transport: any MLModelArtifactTransport,
        now: @Sendable () -> Date,
        onProgress: @escaping @Sendable (MLModelTransferProgress) -> Void
    ) async throws -> MLModelInstallRecord {
        let fm = FileManager.default
        for item in plan.items where !MLModelInstallLayout.isSafeRelativePath(item.artifact.relativePath) {
            throw MLModelInstallError.unsafeArtifactPath(item.artifact.relativePath)
        }
        try fm.createDirectory(at: layout.temporaryDirectory, withIntermediateDirectories: true)

        // Download every artifact into hash-keyed temp files.
        let totalBytes = plan.totalByteCount
        var completedBytes: Int64 = 0
        for item in plan.items {
            try Task.checkCancellation()
            let tempURL = layout.downloadFileURL(sha256: item.artifact.sha256)
            // A verified temp file from an interrupted earlier attempt is reused as-is;
            // anything else is (re)downloaded.
            if verifyFile(at: tempURL, against: item.artifact) != nil {
                let base = completedBytes
                do {
                    try await transport.download(
                        from: item.url,
                        to: tempURL,
                        expectedByteCount: item.artifact.byteCount
                    ) { received, _ in
                        onProgress(MLModelTransferProgress(bytesReceived: base + received, totalBytes: totalBytes))
                    }
                } catch is CancellationError {
                    throw MLModelInstallError.cancelled
                }
                if let failure = verifyFile(at: tempURL, against: item.artifact) {
                    // Corrupt download: remove so the next attempt restarts cleanly.
                    try? fm.removeItem(at: tempURL)
                    throw failure
                }
            }
            completedBytes += item.artifact.byteCount
            onProgress(MLModelTransferProgress(bytesReceived: completedBytes, totalBytes: totalBytes))
        }

        // Assemble the staging directory from verified temp files.
        try Task.checkCancellation()
        let staging = layout.stagingDirectory(for: entry.id, revision: plan.revision)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for item in plan.items {
            let destination = staging.appendingPathComponent(item.artifact.relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: layout.downloadFileURL(sha256: item.artifact.sha256), to: destination)
            if let failure = verifyFile(at: destination, against: item.artifact) {
                try? fm.removeItem(at: staging)
                throw failure
            }
        }

        let record = try promote(
            staging: staging,
            entry: entry,
            revision: plan.revision,
            specs: plan.items.map(\.artifact),
            layout: layout,
            installedAt: now()
        )
        for item in plan.items {
            try? fm.removeItem(at: layout.downloadFileURL(sha256: item.artifact.sha256))
        }
        return record
    }

    /// Atomically promote a fully verified staging directory into the install location and
    /// stamp it with its install record. The rename is the transaction point.
    private static func promote(
        staging: URL,
        entry: MLModelCatalogEntry,
        revision: String,
        specs: [MLModelArtifactSpec],
        layout: MLModelInstallLayout,
        installedAt: Date
    ) throws -> MLModelInstallRecord {
        let fm = FileManager.default
        let record = MLModelInstallRecord(
            modelID: entry.id,
            revision: revision,
            artifacts: specs,
            installedByteCount: specs.reduce(0) { $0 + $1.byteCount },
            installedAt: installedAt
        )
        let recordData = try JSONEncoder().encode(record)
        try recordData.write(to: staging.appendingPathComponent(MLModelInstallLayout.installRecordFileName), options: .atomic)

        let installDir = layout.installDirectory(for: entry.id, revision: revision)
        try fm.createDirectory(at: installDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: installDir)
        try fm.moveItem(at: staging, to: installDir)
        return record
    }

    /// `nil` when the file matches the spec; otherwise the error describing the mismatch.
    private static func verifyFile(at url: URL, against spec: MLModelArtifactSpec) -> MLModelInstallError? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .artifactMissing(spec.relativePath)
        }
        guard let size = try? fileSize(of: url), size == spec.byteCount else {
            return .sizeMismatch(
                artifact: spec.relativePath,
                expected: spec.byteCount,
                actual: (try? fileSize(of: url)) ?? -1
            )
        }
        guard let digest = try? sha256Hex(of: url), digest == spec.sha256 else {
            return .checksumMismatch(artifact: spec.relativePath)
        }
        return nil
    }

    private static func readVerifiedRecord(
        at recordURL: URL,
        expecting id: MLModelID,
        revision: String,
        installDirectory: URL
    ) -> MLModelInstallRecord? {
        guard let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(MLModelInstallRecord.self, from: data),
              record.modelID == id,
              record.revision == revision else { return nil }
        // Cheap structural re-check on every read (existence + size). Full hashing happened at
        // install; hashing hundreds of MB on every launch would be wasted work.
        for artifact in record.artifacts {
            let url = installDirectory.appendingPathComponent(artifact.relativePath)
            guard let size = try? fileSize(of: url), size == artifact.byteCount else { return nil }
        }
        return record
    }

    // MARK: - File helpers

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? Int64) ?? Int64((attributes[.size] as? Int) ?? 0)
    }

    private static func regularFiles(under root: URL) throws -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var paths: [String] = []
        let rootPath = root.standardizedFileURL.path
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let fullPath = fileURL.standardizedFileURL.path
            guard fullPath.hasPrefix(rootPath + "/") else { continue }
            paths.append(String(fullPath.dropFirst(rootPath.count + 1)))
        }
        return paths
    }
}
