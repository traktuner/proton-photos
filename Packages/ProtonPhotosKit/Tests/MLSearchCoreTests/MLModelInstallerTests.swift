import CryptoKit
import Foundation
import Testing
@testable import MLSearchCore

/// Download → verify → atomic install pipeline: checksum/size rejection, path-traversal
/// rejection, idempotency, duplicate-download suppression, local developer installs, and the
/// "verified before visible" invariant. Pure Core + filesystem; no network, no CoreML.
@Suite struct MLModelInstallerTests {
    private final class ScriptedTransport: MLModelArtifactTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var payloads: [URL: Data]
        private var failures: [URL: Int]
        private(set) var downloadCounts: [URL: Int] = [:]
        var progressSteps = 1

        init(payloads: [URL: Data], failFirst failures: [URL: Int] = [:]) {
            self.payloads = payloads
            self.failures = failures
        }

        func download(
            from url: URL,
            to destination: URL,
            expectedByteCount: Int64,
            progress: @escaping @Sendable (Int64, Int64?) -> Void
        ) async throws {
            let payload: Data = try lock.withLock {
                downloadCounts[url, default: 0] += 1
                if let remaining = failures[url], remaining > 0 {
                    failures[url] = remaining - 1
                    throw URLError(.networkConnectionLost)
                }
                guard let data = payloads[url] else { throw URLError(.fileDoesNotExist) }
                return data
            }
            let steps = max(1, progressSteps)
            for step in 1...steps {
                progress(Int64(payload.count * step / steps), Int64(payload.count))
            }
            try payload.write(to: destination)
        }

        func downloadCount(_ url: URL) -> Int {
            lock.withLock { downloadCounts[url, default: 0] }
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func entry(
        id: String,
        plan: MLModelDownloadPlan?,
        track: MLModelReleaseTrack = .production,
        license: MLModelLicense = .mit,
        qualification: MLModelReleaseQualification? = nil
    ) -> MLModelCatalogEntry {
        MLModelCatalogEntry(
            id: MLModelID(id),
            displayName: id,
            family: "Test",
            descriptor: MLModelDescriptor(identifier: id, version: 1, embeddingDimension: 4),
            tokenizerID: "test-tokenizer",
            preprocessingID: "test-preprocessing",
            license: license,
            releaseTrack: track,
            estimatedInstalledBytes: 100,
            downloadPlan: plan,
            releaseQualification: qualification
        )
    }

    private func plan(revision: String = "rev1", files: [(String, Data, URL)]) -> MLModelDownloadPlan {
        MLModelDownloadPlan(revision: revision, items: files.map { name, data, url in
            MLModelDownloadPlan.Item(
                url: url,
                artifact: MLModelArtifactSpec(relativePath: name, sha256: sha256(data), byteCount: Int64(data.count))
            )
        })
    }

    @Test func verifiedDownloadInstallsAtomicallyAndIsIdempotent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data("model-bytes".utf8)
        let url = URL(string: "https://example.test/model.mlmodelc/weights.bin")!
        let testEntry = entry(id: "model-a", plan: plan(files: [("weights.bin", payload, url)]))
        let transport = ScriptedTransport(payloads: [url: payload])
        let installer = MLModelInstaller(layout: layout, transport: transport)

        let record = try await installer.install(testEntry) { _ in }
        #expect(record.revision == "rev1")
        #expect(record.installedByteCount == Int64(payload.count))

        let installedFile = layout.installDirectory(for: testEntry.id, revision: "rev1")
            .appendingPathComponent("weights.bin")
        #expect(try Data(contentsOf: installedFile) == payload)
        #expect(installer.installedRecord(for: testEntry, revision: "rev1") != nil)
        // Second install: already installed, no new download.
        _ = try await installer.install(testEntry) { _ in }
        #expect(transport.downloadCount(url) == 1)
    }

    @Test func releaseReadinessRequiresEvidenceForExactHostedRevision() {
        let payload = Data("model".utf8)
        let url = URL(string: "https://example.test/model.bin")!
        let hostedPlan = plan(revision: "rev2", files: [("model.bin", payload, url)])
        let stale = MLModelReleaseQualification(
            artifactRevision: "rev1",
            hardwareModel: "oldest-supported-device",
            osVersion: "test",
            peakResidentBytes: 1,
            imageP95Milliseconds: 1,
            textP95Milliseconds: 1,
            reachedSeriousThermalState: false,
            neuralEngineExecutionVerified: true,
            passed: true
        )
        let matching = MLModelReleaseQualification(
            artifactRevision: "rev2",
            hardwareModel: "oldest-supported-device",
            osVersion: "test",
            peakResidentBytes: 1,
            imageP95Milliseconds: 1,
            textP95Milliseconds: 1,
            reachedSeriousThermalState: false,
            neuralEngineExecutionVerified: true,
            passed: true
        )

        #expect(!entry(id: "missing", plan: hostedPlan).isReleaseReady)
        #expect(!entry(id: "stale", plan: hostedPlan, qualification: stale).isReleaseReady)
        #expect(entry(id: "ready", plan: hostedPlan, qualification: matching).isReleaseReady)
    }

    @Test func checksumMismatchNeverBecomesInstalled() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let goodPayload = Data("expected-bytes".utf8)
        let corruptPayload = Data("corrupted-bytes".utf8)
        let url = URL(string: "https://example.test/corrupt.bin")!
        // Plan pins the hash of goodPayload, transport serves corruptPayload (same length
        // would also fail; use different length to exercise the size check first).
        let testEntry = entry(id: "model-corrupt", plan: plan(files: [("weights.bin", goodPayload, url)]))
        let transport = ScriptedTransport(payloads: [url: corruptPayload])
        let installer = MLModelInstaller(layout: layout, transport: transport)

        await #expect(throws: MLModelInstallError.self) {
            _ = try await installer.install(testEntry) { _ in }
        }
        #expect(installer.installedRecord(for: testEntry, revision: "rev1") == nil)
        #expect(!FileManager.default.fileExists(atPath: layout.installDirectory(for: testEntry.id, revision: "rev1").path))
    }

    @Test func equalLengthCorruptionFailsChecksum() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let goodPayload = Data("aaaaaaaa".utf8)
        let corruptPayload = Data("bbbbbbbb".utf8)
        let url = URL(string: "https://example.test/samesize.bin")!
        let testEntry = entry(id: "model-samesize", plan: plan(files: [("weights.bin", goodPayload, url)]))
        let installer = MLModelInstaller(layout: layout, transport: ScriptedTransport(payloads: [url: corruptPayload]))

        do {
            _ = try await installer.install(testEntry) { _ in }
            Issue.record("install must fail")
        } catch let error as MLModelInstallError {
            #expect(error == .checksumMismatch(artifact: "weights.bin"))
        }
    }

    @Test func pathTraversalInManifestIsRejected() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data("x".utf8)
        let url = URL(string: "https://example.test/evil.bin")!
        let testEntry = entry(id: "model-evil", plan: plan(files: [("../../evil.bin", payload, url)]))
        let installer = MLModelInstaller(layout: layout, transport: ScriptedTransport(payloads: [url: payload]))

        do {
            _ = try await installer.install(testEntry) { _ in }
            Issue.record("install must fail")
        } catch let error as MLModelInstallError {
            #expect(error == .unsafeArtifactPath("../../evil.bin"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("evil.bin").path))
    }

    @Test func unsafeRelativePathRules() {
        #expect(MLModelInstallLayout.isSafeRelativePath("weights.bin"))
        #expect(MLModelInstallLayout.isSafeRelativePath("nested/dir/weights.bin"))
        #expect(!MLModelInstallLayout.isSafeRelativePath("/absolute"))
        #expect(!MLModelInstallLayout.isSafeRelativePath("../up"))
        #expect(!MLModelInstallLayout.isSafeRelativePath("a/../b"))
        #expect(!MLModelInstallLayout.isSafeRelativePath("a//b"))
        #expect(!MLModelInstallLayout.isSafeRelativePath("."))
        #expect(!MLModelInstallLayout.isSafeRelativePath(""))
    }

    @Test func failedDownloadRetriesCleanly() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data("retry-bytes".utf8)
        let url = URL(string: "https://example.test/retry.bin")!
        let testEntry = entry(id: "model-retry", plan: plan(files: [("weights.bin", payload, url)]))
        let transport = ScriptedTransport(payloads: [url: payload], failFirst: [url: 1])
        let installer = MLModelInstaller(layout: layout, transport: transport)

        await #expect(throws: Error.self) {
            _ = try await installer.install(testEntry) { _ in }
        }
        #expect(installer.installedRecord(for: testEntry, revision: "rev1") == nil)

        let record = try await installer.install(testEntry) { _ in }
        #expect(record.revision == "rev1")
        #expect(transport.downloadCount(url) == 2)
    }

    @Test func interruptedDownloadResumesFromStagingWithoutASecondModelCopy() async throws {
        final class ResumingTransport: MLModelArtifactTransport, @unchecked Sendable {
            let payload: Data
            private(set) var starts: [Int] = []

            init(payload: Data) { self.payload = payload }

            func download(
                from url: URL,
                to destination: URL,
                expectedByteCount: Int64,
                progress: @escaping @Sendable (Int64, Int64?) -> Void
            ) async throws {
                let existing = (try? Data(contentsOf: destination)) ?? Data()
                starts.append(existing.count)
                let split = payload.count / 2
                if existing.isEmpty {
                    try payload.prefix(split).write(to: destination)
                    progress(Int64(split), expectedByteCount)
                    throw URLError(.networkConnectionLost)
                }
                var resumed = existing
                resumed.append(payload.dropFirst(existing.count))
                try resumed.write(to: destination)
                progress(Int64(resumed.count), expectedByteCount)
            }
        }

        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data(repeating: 0xA5, count: 4 << 20)
        let url = URL(string: "https://example.test/resume.bin")!
        let testEntry = entry(id: "model-resume", plan: plan(files: [("Model.mlmodelc/weights.bin", payload, url)]))
        let transport = ResumingTransport(payload: payload)
        let installer = MLModelInstaller(layout: layout, transport: transport)

        await #expect(throws: Error.self) {
            _ = try await installer.install(testEntry) { _ in }
        }
        let partial = layout.stagingDirectory(for: testEntry.id, revision: "rev1")
            .appendingPathComponent("Model.mlmodelc/weights.bin.partial")
        #expect(FileManager.default.fileExists(atPath: partial.path))
        #expect((try Data(contentsOf: partial)).count == payload.count / 2)

        let record = try await installer.install(testEntry) { _ in }
        #expect(record.installedByteCount == Int64(payload.count))
        #expect(transport.starts == [0, payload.count / 2])
    }

    @Test func concurrentInstallsShareOneDownload() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data("shared-bytes".utf8)
        let url = URL(string: "https://example.test/shared.bin")!
        let testEntry = entry(id: "model-shared", plan: plan(files: [("weights.bin", payload, url)]))
        let transport = ScriptedTransport(payloads: [url: payload])
        let installer = MLModelInstaller(layout: layout, transport: transport)

        async let first = installer.install(testEntry) { _ in }
        async let second = installer.install(testEntry) { _ in }
        _ = try await (first, second)
        #expect(transport.downloadCount(url) == 1)
    }

    @Test func localDeveloperInstallHashesAndInstallsContent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let source = root.appendingPathComponent("dev-artifact", isDirectory: true)
        let model = source.appendingPathComponent("Test.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: model.appendingPathComponent("Weights"), withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: model.appendingPathComponent("Manifest.json"))
        try Data("weights".utf8).write(to: model.appendingPathComponent("Weights/weight.bin"))
        let testEntry = entry(id: "model-dev", plan: nil, track: .developerOnly)
        let installer = MLModelInstaller(layout: layout, transport: ScriptedTransport(payloads: [:]))

        let record = try await installer.installFromLocalArtifact(testEntry, artifactDirectory: source)
        #expect(record.revision.hasPrefix("local-"))
        #expect(record.artifacts.count == 2)
        #expect(installer.anyInstalledRecord(for: testEntry)?.revision == record.revision)

        // Re-install of identical content is a no-op with the same revision.
        let again = try await installer.installFromLocalArtifact(testEntry, artifactDirectory: source)
        #expect(again.revision == record.revision)

        // A record whose files were tampered with (size change) is no longer trusted.
        try Data("weights-tampered".utf8).write(
            to: layout.installDirectory(for: testEntry.id, revision: record.revision)
                .appendingPathComponent("Test.mlmodelc/Weights/weight.bin")
        )
        #expect(installer.anyInstalledRecord(for: testEntry) == nil)
    }

    @Test func localInstallRejectsMultipleModelRepresentations() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("ambiguous", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Model.mlmodelc"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Model.mlpackage"), withIntermediateDirectories: true)
        try Data("compiled".utf8).write(to: source.appendingPathComponent("Model.mlmodelc/model.bin"))
        try Data("package".utf8).write(to: source.appendingPathComponent("Model.mlpackage/model.bin"))
        let installer = MLModelInstaller(
            layout: MLModelInstallLayout(rootDirectory: root.appendingPathComponent("install")),
            transport: ScriptedTransport(payloads: [:])
        )

        await #expect(throws: MLModelInstallError.ambiguousModelArtifact) {
            _ = try await installer.installFromLocalArtifact(
                entry(id: "ambiguous", plan: nil, track: .developerOnly),
                artifactDirectory: source
            )
        }
    }

    @Test func researchOnlyLicenseIsTechnicallyBlockedFromDownload() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data("research-weights".utf8)
        let url = URL(string: "https://example.test/research.bin")!
        // A download plan misconfigured onto research-only weights must stay inert: the
        // license is a hard gate at the transfer boundary, not a data annotation.
        let testEntry = entry(
            id: "model-research",
            plan: plan(files: [("weights.bin", payload, url)]),
            license: .appleAMLR
        )
        #expect(!testEntry.isDownloadable)
        let transport = ScriptedTransport(payloads: [url: payload])
        let installer = MLModelInstaller(layout: layout, transport: transport)

        do {
            _ = try await installer.install(testEntry) { _ in }
            Issue.record("install must fail on a research-only license")
        } catch let error as MLModelInstallError {
            #expect(error == .licenseProhibitsDistribution)
        }
        #expect(transport.downloadCount(url) == 0, "no byte of research-only weights may be fetched")
        #expect(installer.anyInstalledRecord(for: testEntry) == nil)
        #expect(!FileManager.default.fileExists(atPath: layout.modelDirectory(for: testEntry.id).path))
    }

    @Test func uninstallRemovesEveryRevision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)
        let payload = Data("bytes".utf8)
        let url = URL(string: "https://example.test/u.bin")!
        let testEntry = entry(id: "model-u", plan: plan(files: [("weights.bin", payload, url)]))
        let installer = MLModelInstaller(layout: layout, transport: ScriptedTransport(payloads: [url: payload]))

        _ = try await installer.install(testEntry) { _ in }
        await installer.uninstall(testEntry)
        #expect(installer.anyInstalledRecord(for: testEntry) == nil)
        #expect(!FileManager.default.fileExists(atPath: layout.modelDirectory(for: testEntry.id).path))
    }
}
