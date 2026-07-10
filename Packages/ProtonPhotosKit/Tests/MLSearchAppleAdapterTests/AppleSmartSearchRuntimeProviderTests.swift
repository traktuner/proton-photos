import Foundation
import Testing
@testable import MLSearchAppleAdapter
@testable import MLSearchCore

/// Adapter-side runtime provider: model artifact resolution inside verified installs,
/// tokenizer identity validation, and transport policy. Model loading itself is covered by
/// `CoreMLDualEncoder` tests with a real fixture where available.
@Suite struct AppleSmartSearchRuntimeProviderTests {
    private func makeInstallDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-search-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func compiledModelDirectoryIsUsedDirectly() async throws {
        let dir = try makeInstallDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let compiled = dir.appendingPathComponent("TinyCLIP.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)

        let resolved = try await AppleSmartSearchRuntimeProvider.loadableModelURL(in: dir)
        #expect(resolved.lastPathComponent == "TinyCLIP.mlmodelc")
    }

    @Test func installWithoutModelArtifactIsRejected() async throws {
        let dir = try makeInstallDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not a model".utf8).write(to: dir.appendingPathComponent("README.txt"))

        await #expect(throws: AppleSmartSearchRuntimeError.noModelArtifact) {
            _ = try await AppleSmartSearchRuntimeProvider.loadableModelURL(in: dir)
        }
    }

    @Test func transportRefusesPlainHTTP() async throws {
        let transport = URLSessionMLModelArtifactTransport()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("transport-\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: destination) }

        await #expect(throws: MLArtifactTransportError.notHTTPS) {
            try await transport.download(
                from: URL(string: "http://example.test/model.bin")!,
                to: destination,
                expectedByteCount: 1
            ) { _, _ in }
        }
    }
}
