import CoreGraphics
import Foundation
import ImageIO
import PhotosCore
import Testing
@testable import MLSearchAppleAdapter
@testable import MLSearchCore

/// Opt-in REAL-model validation of the multilingual production candidate (SigLIP2-base-256).
///
/// Set `PROTON_PHOTOS_SIGLIP2_ARTIFACT` to a converted artifact directory containing
/// `SigLIP2.mlpackage` (or `.mlmodelc`), `tokenizer.json` and `tokenizer-fixtures.json`
/// (produced by `ml-model-spike.noindex/convert_siglip2.py` from the pinned upstream
/// revision). Optionally set `PROTON_PHOTOS_ML_REFERENCE_CORPUS` to a directory of photos
/// named `<concept>-*.jpg` for the end-to-end ranking measurement.
///
/// Three proofs, none simulated:
/// 1. The Swift SentencePiece tokenizer reproduces the upstream Python tokenizations exactly.
/// 2. The converted artifact satisfies the catalog runtime contract and embeds image+text.
/// 3. German AND English queries rank real photos correctly (the multilingual claim).
@Suite struct SigLIP2QualityReferenceTests {
    private static let descriptor = MLModelCatalogEntry.sigLIP2Base256.descriptor

    private struct FixtureDocument: Decodable {
        struct Fixture: Decodable {
            let text: String
            let input_ids: [Int32]
        }

        let context_length: Int
        let fixtures: [Fixture]
    }

    private struct FileImageSource: CoreMLImageSource {
        let urlsByUID: [PhotoUID: URL]

        func image(for uid: PhotoUID) async -> CoreMLImageSourceOutcome {
            guard let url = urlsByUID[uid],
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return .permanentFailure(reason: "unreadable reference image")
            }
            return .image(CoreMLSourceImage(cgImage: image))
        }
    }

    private struct EmptyImageSource: CoreMLImageSource {
        func image(for uid: PhotoUID) async -> CoreMLImageSourceOutcome { .transientFailure }
    }

    private static func artifactDirectory() -> URL? {
        ProcessInfo.processInfo.environment["PROTON_PHOTOS_SIGLIP2_ARTIFACT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func makeEncoder(artifact: URL, imageSource: any CoreMLImageSource) async throws -> CoreMLDualEncoder {
        let entry = MLModelCatalogEntry.sigLIP2Base256
        let tokenizer = try SentencePieceBPETokenizer(
            fileURL: artifact.appendingPathComponent("tokenizer.json")
        )
        #expect(tokenizer.contextLength == entry.runtimeContract.textContextLength)
        var schema = CoreMLDualEncoderSchema(contract: entry.runtimeContract)
        schema.imageCropMode = try AppleSmartSearchRuntimeProvider.cropMode(for: entry.preprocessingID)
        let modelURL = try await AppleSmartSearchRuntimeProvider.loadableModelURL(in: artifact)
        return try await CoreMLDualEncoder(
            modelURL: modelURL,
            descriptor: descriptor,
            imageSource: imageSource,
            tokenizer: tokenizer,
            schema: schema
        )
    }

    @Test func optionalTokenizerMatchesUpstreamFixturesExactly() throws {
        guard let artifact = Self.artifactDirectory() else { return }
        let tokenizer = try SentencePieceBPETokenizer(
            fileURL: artifact.appendingPathComponent("tokenizer.json")
        )
        let document = try JSONDecoder().decode(
            FixtureDocument.self,
            from: Data(contentsOf: artifact.appendingPathComponent("tokenizer-fixtures.json"))
        )
        #expect(tokenizer.contextLength == document.context_length)
        for fixture in document.fixtures {
            let tokenized = try tokenizer.tokenize(fixture.text)
            #expect(Array(tokenized.inputIDs) == fixture.input_ids, "\"\(fixture.text)\"")
        }
    }

    @Test(.timeLimit(.minutes(10))) func optionalRuntimeContractAndDualEmbeddingSmoke() async throws {
        guard let artifact = Self.artifactDirectory() else { return }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 256 * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        let image = try #require(context.makeImage())
        let encoder = try await Self.makeEncoder(
            artifact: artifact,
            imageSource: FileImageSource(urlsByUID: [:])
        )
        _ = encoder // contract validated in init (functions, ids-only text input, 256px, 768-d)

        let direct = try await Self.makeEncoder(
            artifact: artifact,
            imageSource: CachedThumbnailMLImageSourceStandIn(image: image)
        )
        let imageOutcome = await direct.embed(uid: PhotoUID(volumeID: "v", nodeID: "smoke"), descriptor: Self.descriptor)
        guard case .embedded(let imageEmbedding) = imageOutcome else {
            Issue.record("expected image embedding")
            return
        }
        let textEmbedding = try await direct.encode(text: "ein Foto von einem Hund", descriptor: Self.descriptor)
        #expect(imageEmbedding.count == 768)
        #expect(textEmbedding.count == 768)
        #expect(imageEmbedding.allSatisfy { $0.isFinite })
        #expect(textEmbedding.allSatisfy { $0.isFinite })
    }

    private struct CachedThumbnailMLImageSourceStandIn: CoreMLImageSource {
        let image: CGImage
        func image(for uid: PhotoUID) async -> CoreMLImageSourceOutcome {
            .image(CoreMLSourceImage(cgImage: image))
        }
    }

    @Test(.timeLimit(.minutes(10))) func optionalRealPhotoCorpusRankingGermanAndEnglish() async throws {
        guard let artifact = Self.artifactDirectory(),
              let corpusPath = ProcessInfo.processInfo.environment["PROTON_PHOTOS_ML_REFERENCE_CORPUS"] else { return }
        let corpusURL = URL(fileURLWithPath: corpusPath, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: corpusURL, includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
        try #require(!files.isEmpty, "reference corpus directory is empty")

        let concepts = TinyCLIPQualityReferenceTests.concepts
        var urlsByUID: [PhotoUID: URL] = [:]
        var conceptByUID: [PhotoUID: String] = [:]
        for file in files {
            guard let concept = concepts.first(where: { file.lastPathComponent.hasPrefix($0.concept) })?.concept else { continue }
            let uid = PhotoUID(volumeID: "ref", nodeID: file.lastPathComponent)
            urlsByUID[uid] = file
            conceptByUID[uid] = concept
        }
        try #require(Set(conceptByUID.values).count == concepts.count,
                     "corpus must contain at least one photo per concept: \(concepts.map(\.concept))")

        let encoder = try await Self.makeEncoder(
            artifact: artifact,
            imageSource: FileImageSource(urlsByUID: urlsByUID)
        )

        var block = MLVectorBlock(descriptor: Self.descriptor)
        for uid in urlsByUID.keys.sorted(by: { $0.nodeID < $1.nodeID }) {
            guard case .embedded(let vector) = await encoder.embed(uid: uid, descriptor: Self.descriptor),
                  let normalized = MLVectorNormalization.normalized(vector) else {
                Issue.record("failed to embed reference image \(uid.nodeID)")
                continue
            }
            block.append(uid: uid, vector: normalized)
        }

        let scorer = AccelerateVectorScorer()
        var englishHits = 0
        var germanHits = 0
        var report: [String] = []
        for entry in concepts {
            for (label, query, isEnglish) in [("en", entry.english, true), ("de", entry.german, false)] {
                let raw = try await encoder.encode(text: query, descriptor: Self.descriptor)
                guard let normalized = MLVectorNormalization.normalized(raw) else { continue }
                let results = scorer.rank(block: block, query: normalized, limit: 3, queryText: query)
                let topConcept = results.results.first.flatMap { conceptByUID[$0.uid] } ?? "-"
                let hit = topConcept == entry.concept
                if hit { if isEnglish { englishHits += 1 } else { germanHits += 1 } }
                report.append("[\(label)] \(query) → top1=\(topConcept) \(hit ? "HIT" : "MISS")")
            }
        }
        print("[siglip2-quality] corpus ranking en=\(englishHits)/\(concepts.count) de=\(germanHits)/\(concepts.count)\n" + report.joined(separator: "\n"))
        // The multilingual claim, asserted with slack for tiny-corpus noise (2026-07 Python
        // reference measured en 7/8 prompts, de 7/8 words on the same corpus).
        #expect(englishHits >= concepts.count * 3 / 4)
        #expect(germanHits >= concepts.count * 3 / 4, "German must hold near-English parity — that is why SigLIP2 exists in the catalog")
    }
}
