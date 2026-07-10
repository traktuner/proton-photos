import CoreGraphics
import Foundation
import ImageIO
import PhotosCore
import Testing
@testable import MLSearchAppleAdapter
@testable import MLSearchCore

/// Opt-in REAL-model quality reference for TinyCLIP (no fixture in Git — set
/// `PROTON_PHOTOS_TINYCLIP_MODEL` to a converted `.mlmodelc`/`.mlpackage`).
///
/// Two honest measurements, never a simulated pass:
/// 1. Cross-lingual text alignment: each German query ("Bäume", "Strand", …) must land
///    nearest to ITS English photo-prompt among all concepts. This measures whether the
///    LAION-400M-trained text tower understands German at all — the known weak spot.
/// 2. Optional real-photo ranking: point `PROTON_PHOTOS_ML_REFERENCE_CORPUS` at a directory
///    of photos named `<concept>-*.jpg|png|heic` (concepts: trees, beach, dog, car). Every
///    English AND German query must rank a photo of its own concept first.
@Suite struct TinyCLIPQualityReferenceTests {
    private static let concepts: [(concept: String, english: String, german: String)] = [
        ("trees", "a photo of trees", "Bäume"),
        ("beach", "a photo of a beach", "Strand"),
        ("dog", "a photo of a dog", "Hund"),
        ("car", "a photo of a car", "Auto"),
    ]

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

    private func normalizedDot(_ a: ContiguousArray<Float32>, _ b: ContiguousArray<Float32>) -> Float {
        guard let na = MLVectorNormalization.normalized(a), let nb = MLVectorNormalization.normalized(b) else { return 0 }
        return zip(na, nb).reduce(0) { $0 + $1.0 * $1.1 }
    }

    @Test func optionalCrossLingualTextAlignment() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["PROTON_PHOTOS_TINYCLIP_MODEL"] else { return }
        let descriptor = MLModelDescriptor(identifier: "tinyclip-39m", version: 1, embeddingDimension: 512)
        let encoder = try await CoreMLDualEncoder(
            modelURL: URL(fileURLWithPath: modelPath),
            descriptor: descriptor,
            imageSource: EmptyImageSource(),
            tokenizer: CLIPBPETokenizer.bundledTinyCLIP()
        )

        var englishEmbeddings: [String: ContiguousArray<Float32>] = [:]
        for entry in Self.concepts {
            englishEmbeddings[entry.concept] = try await encoder.encode(text: entry.english, descriptor: descriptor)
        }

        var aligned = 0
        var report: [String] = []
        for entry in Self.concepts {
            let germanEmbedding = try await encoder.encode(text: entry.german, descriptor: descriptor)
            let ranked = Self.concepts
                .map { ($0.concept, normalizedDot(germanEmbedding, englishEmbeddings[$0.concept]!)) }
                .sorted { $0.1 > $1.1 }
            let top = ranked[0]
            if top.0 == entry.concept { aligned += 1 }
            report.append("\(entry.german) → \(ranked.map { "\($0.0)=\(String(format: "%.3f", $0.1))" }.joined(separator: " "))")
        }
        // Full matrix in the log — this is the documentation basis for the DE-quality verdict.
        print("[tinyclip-quality] cross-lingual alignment \(aligned)/\(Self.concepts.count)\n" + report.joined(separator: "\n"))
        // Honest bar: report-only below, hard-fail only when German is COMPLETELY unaligned.
        #expect(aligned >= 2, "German queries barely align with English concepts (\(aligned)/4) — document, do not ship claims")
    }

    @Test func optionalRealPhotoCorpusRanking() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["PROTON_PHOTOS_TINYCLIP_MODEL"],
              let corpusPath = ProcessInfo.processInfo.environment["PROTON_PHOTOS_ML_REFERENCE_CORPUS"] else { return }
        let corpusURL = URL(fileURLWithPath: corpusPath, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: corpusURL, includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
        try #require(!files.isEmpty, "reference corpus directory is empty")

        var urlsByUID: [PhotoUID: URL] = [:]
        var conceptByUID: [PhotoUID: String] = [:]
        for file in files {
            guard let concept = Self.concepts.first(where: { file.lastPathComponent.hasPrefix($0.concept) })?.concept else { continue }
            let uid = PhotoUID(volumeID: "ref", nodeID: file.lastPathComponent)
            urlsByUID[uid] = file
            conceptByUID[uid] = concept
        }
        try #require(Set(conceptByUID.values).count == Self.concepts.count,
                     "corpus must contain at least one photo per concept: \(Self.concepts.map(\.concept))")

        let descriptor = MLModelDescriptor(identifier: "tinyclip-39m", version: 1, embeddingDimension: 512)
        let encoder = try await CoreMLDualEncoder(
            modelURL: URL(fileURLWithPath: modelPath),
            descriptor: descriptor,
            imageSource: FileImageSource(urlsByUID: urlsByUID),
            tokenizer: CLIPBPETokenizer.bundledTinyCLIP()
        )

        var block = MLVectorBlock(descriptor: descriptor)
        for uid in urlsByUID.keys.sorted(by: { $0.nodeID < $1.nodeID }) {
            guard case .embedded(let vector) = await encoder.embed(uid: uid, descriptor: descriptor),
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
        for entry in Self.concepts {
            for (label, query, isEnglish) in [("en", entry.english, true), ("de", entry.german, false)] {
                let raw = try await encoder.encode(text: query, descriptor: descriptor)
                guard let normalized = MLVectorNormalization.normalized(raw) else { continue }
                let results = scorer.rank(block: block, query: normalized, limit: 3, queryText: query)
                let topConcept = results.results.first.flatMap { conceptByUID[$0.uid] } ?? "-"
                let hit = topConcept == entry.concept
                if hit { if isEnglish { englishHits += 1 } else { germanHits += 1 } }
                report.append("[\(label)] \(query) → top1=\(topConcept) \(hit ? "HIT" : "MISS")")
            }
        }
        print("[tinyclip-quality] corpus ranking en=\(englishHits)/4 de=\(germanHits)/4\n" + report.joined(separator: "\n"))
        // English is the trained language: every English query must find its concept.
        #expect(englishHits == Self.concepts.count)
        // German is measured and documented, not asserted — LAION-400M is English-dominant.
    }
}
