import Foundation
import MLSearchCore

public enum SentencePieceBPETokenizerError: Error, Equatable {
    case invalidVocabulary
    case unsupportedType(String)
}

/// SentencePiece **BPE** tokenizer (Gemma-style vocabularies, used by the SigLIP family;
/// the Gemma `tokenizer.model` is `model_type: BPE` with scores = negative merge ranks).
///
/// Data-driven: the vocabulary (pieces + scores + special-token ids + preprocessing flags)
/// ships as `tokenizer.json` INSIDE the verified model artifact — exported from the pinned
/// upstream revision at conversion time and hash-verified by the installer like every other
/// artifact file. Nothing model-specific is compiled into the app.
///
/// Semantics match `sentencepiece` BPE inference for Gemma vocabularies:
/// - normalization: identity, apart from optional lowercasing (SigLIP canonical
///   preprocessing, a JSON flag) and escaping spaces as ▁ (U+2581); no dummy prefix, no NFKC
/// - segmentation: repeatedly merge the adjacent symbol pair whose concatenation has the
///   highest vocabulary score (leftmost wins ties), until no merge applies
/// - unknown code points: byte-fallback pieces (`<0xXX>`)
/// - assembly: optional BOS, optional EOS, truncation to the fixed context length, PAD fill
///
/// Correctness is pinned by `tokenizer-fixtures.json` (reference tokenizations produced by
/// the upstream Python tokenizer), replayed exactly by the opt-in adapter tests.
public final class SentencePieceBPETokenizer: MLTextTokenizer, @unchecked Sendable {
    private struct Document: Decodable {
        struct Piece: Decodable {
            let piece: String
            let score: Float
        }

        let type: String
        let context_length: Int
        let pad_id: Int32
        let bos_id: Int32?
        let eos_id: Int32?
        let unk_id: Int32
        let add_bos: Bool
        let add_eos: Bool
        /// SigLIP-family canonical preprocessing lowercases text before segmentation.
        let lowercase: Bool?
        let pieces: [Piece]
    }

    private struct Candidate {
        let id: Int32
        let score: Float
    }

    public let contextLength: Int

    private let piecesByText: [String: Candidate]
    private let byteFallbackIDs: [Int32]        // 256 entries, or empty when unavailable
    private let padID: Int32
    private let bosID: Int32?
    private let eosID: Int32?
    private let unkID: Int32
    private let addBOS: Bool
    private let addEOS: Bool
    private let lowercases: Bool

    public init(data: Data) throws {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw SentencePieceBPETokenizerError.invalidVocabulary
        }
        guard document.type == "sentencepiece-bpe" else {
            throw SentencePieceBPETokenizerError.unsupportedType(document.type)
        }
        guard document.context_length > 0, !document.pieces.isEmpty else {
            throw SentencePieceBPETokenizerError.invalidVocabulary
        }

        var byText: [String: Candidate] = [:]
        byText.reserveCapacity(document.pieces.count)
        var byteIDs = [Int32](repeating: -1, count: 256)
        for (index, piece) in document.pieces.enumerated() {
            let id = Int32(index)
            // Byte-fallback pieces are control tokens, never direct matches.
            if piece.piece.count == 6, piece.piece.hasPrefix("<0x"), piece.piece.hasSuffix(">"),
               let byte = UInt8(piece.piece.dropFirst(3).dropLast(), radix: 16) {
                byteIDs[Int(byte)] = id
                continue
            }
            // First writer wins on duplicate surface forms (matches sentencepiece).
            if byText[piece.piece] == nil {
                byText[piece.piece] = Candidate(id: id, score: piece.score)
            }
        }

        self.contextLength = document.context_length
        self.piecesByText = byText
        self.byteFallbackIDs = byteIDs.contains(-1) ? [] : byteIDs
        self.padID = document.pad_id
        self.bosID = document.bos_id
        self.eosID = document.eos_id
        self.unkID = document.unk_id
        self.addBOS = document.add_bos
        self.addEOS = document.add_eos
        self.lowercases = document.lowercase ?? false
    }

    public convenience init(fileURL: URL) throws {
        try self.init(data: Data(contentsOf: fileURL, options: .mappedIfSafe))
    }

    public func tokenize(_ text: String) throws -> MLTokenizedText {
        var ids: [Int32] = []
        ids.reserveCapacity(contextLength)
        if addBOS, let bosID { ids.append(bosID) }
        ids.append(contentsOf: segment(normalize(text)))

        // Truncate, keeping room for EOS (HF semantics: specials count toward max_length).
        let bodyLimit = contextLength - (addEOS && eosID != nil ? 1 : 0)
        if ids.count > bodyLimit {
            ids.removeSubrange(bodyLimit..<ids.count)
        }
        if addEOS, let eosID { ids.append(eosID) }
        let endIndex = max(0, ids.count - 1)
        if ids.count < contextLength {
            ids.append(contentsOf: repeatElement(padID, count: contextLength - ids.count))
        }
        return MLTokenizedText(inputIDs: ContiguousArray(ids), endTokenIndex: endIndex)
    }

    /// Identity normalizer plus the two Gemma/SigLIP specifics: optional lowercase
    /// (data-driven) and spaces escaped as ▁. No dummy prefix, no NFKC.
    private func normalize(_ text: String) -> String {
        let cased = lowercases ? text.lowercased() : text
        return String(cased.map { $0 == " " ? "\u{2581}" : $0 })
    }

    /// SentencePiece BPE: start from single code points, repeatedly merge the adjacent pair
    /// whose concatenation is a vocabulary piece with the highest score (scores are negative
    /// merge ranks, so the earliest-learned merge wins; leftmost wins score ties).
    private func segment(_ text: String) -> [Int32] {
        var symbols = text.unicodeScalars.map(String.init)
        guard !symbols.isEmpty else { return [] }

        while symbols.count > 1 {
            var bestIndex = -1
            var bestScore = -Float.infinity
            for index in 0..<(symbols.count - 1) {
                guard let candidate = piecesByText[symbols[index] + symbols[index + 1]] else { continue }
                if candidate.score > bestScore {
                    bestScore = candidate.score
                    bestIndex = index
                }
            }
            guard bestIndex >= 0 else { break }
            symbols[bestIndex] += symbols[bestIndex + 1]
            symbols.remove(at: bestIndex + 1)
        }

        var ids: [Int32] = []
        ids.reserveCapacity(symbols.count)
        for symbol in symbols {
            if let candidate = piecesByText[symbol] {
                ids.append(candidate.id)
            } else {
                // Single code point not in the vocabulary: byte fallback (or UNK).
                ids.append(contentsOf: fallbackIDs(for: symbol))
            }
        }
        return ids
    }

    private func fallbackIDs(for symbol: String) -> [Int32] {
        guard !byteFallbackIDs.isEmpty else { return [unkID] }
        return symbol.utf8.map { byteFallbackIDs[Int($0)] }
    }
}
