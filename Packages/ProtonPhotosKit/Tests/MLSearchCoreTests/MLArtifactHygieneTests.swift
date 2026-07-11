import Foundation
import Testing
@testable import MLSearchCore

/// Repo gate: model weights and compiled ML artifacts must never be committed. Models are
/// downloaded (verified, checksummed) or installed from developer-provided local artifacts;
/// Git carries only code, manifests, tokenizer data and licenses.
@Suite struct MLArtifactHygieneTests {
    private static let forbiddenExtensions: Set<String> = [
        "mlmodel", "mlpackage", "mlmodelc", "onnx", "pt", "pth", "safetensors", "gguf", "tflite", "ckpt",
    ]
    /// Anything this large in a source tree is a weight blob, whatever its extension.
    private static let maxSourceFileBytes = 20 << 20

    @Test func noModelWeightArtifactsAreCommitted() throws {
        var repoRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repoRoot.deleteLastPathComponent() }

        let scanRoots = [
            repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources"),
            repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Tests"),
            repoRoot.appendingPathComponent("App"),
            repoRoot.appendingPathComponent("iOSApp"),
            repoRoot.appendingPathComponent("Tools"),
        ]

        var violations: [String] = []
        let fm = FileManager.default
        for root in scanRoots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }
                if Self.forbiddenExtensions.contains(fileURL.pathExtension.lowercased()) {
                    violations.append("forbidden model artifact: \(fileURL.path)")
                }
                if let size = values?.fileSize, size > Self.maxSourceFileBytes {
                    violations.append("oversized file (\(size) bytes), weights must not be committed: \(fileURL.path)")
                }
            }
        }

        #expect(violations.isEmpty, "Model weights/compiled artifacts found in the source tree:\n\(violations.joined(separator: "\n"))")
    }

    @Test func sigLIP2ConversionRecipeMatchesCatalogAndProducesCanonicalDistribution() throws {
        var repoRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repoRoot.deleteLastPathComponent() }
        let scriptURL = repoRoot.appendingPathComponent("Tools/MLModels/SigLIP2/convert_siglip2.py")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let entry = MLModelCatalogEntry.sigLIP2Base256

        #expect(script.contains("REVISION = \"\(entry.sourceRevision ?? "")\""))
        #expect(script.contains("coremlcompiler"))
        #expect(script.contains("image_coreml_torch_cosine"))
        #expect(script.contains("artifact-manifest.json"))
        #expect(!script.contains("/Users/"))
    }
}
