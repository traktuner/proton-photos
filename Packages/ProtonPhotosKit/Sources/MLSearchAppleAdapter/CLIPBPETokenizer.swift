import Foundation
import MLSearchCore

public enum CLIPBPETokenizerError: Error, Equatable {
    case missingBundledVocabulary
    case invalidVocabulary
    case unknownToken(String)
}

public final class CLIPBPETokenizer: MLTextTokenizer, @unchecked Sendable {
    private struct Document: Decodable {
        struct Model: Decodable {
            let vocab: [String: Int32]
            let merges: [String]
        }

        let model: Model
    }

    private struct Pair: Hashable {
        let first: String
        let second: String
    }

    private final class TokenBox {
        let ids: [Int32]

        init(_ ids: [Int32]) {
            self.ids = ids
        }
    }

    public static let contextLength = 77
    public static let startTokenID: Int32 = 49_406
    public static let endTokenID: Int32 = 49_407

    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#
    )
    private static let whitespacePattern = try! NSRegularExpression(pattern: #"\s+"#)

    private let vocabulary: [String: Int32]
    private let mergeRanks: [Pair: Int]
    private let byteEncoder: [String]
    private let cache = NSCache<NSString, TokenBox>()

    public init(data: Data) throws {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw CLIPBPETokenizerError.invalidVocabulary
        }

        guard document.model.vocab["<|startoftext|>"] == Self.startTokenID,
              document.model.vocab["<|endoftext|>"] == Self.endTokenID else {
            throw CLIPBPETokenizerError.invalidVocabulary
        }

        var ranks: [Pair: Int] = [:]
        ranks.reserveCapacity(document.model.merges.count)
        for (rank, merge) in document.model.merges.enumerated() {
            let symbols = merge.split(separator: " ", maxSplits: 1).map(String.init)
            guard symbols.count == 2 else { throw CLIPBPETokenizerError.invalidVocabulary }
            ranks[Pair(first: symbols[0], second: symbols[1])] = rank
        }

        vocabulary = document.model.vocab
        mergeRanks = ranks
        byteEncoder = Self.makeByteEncoder()
        cache.countLimit = 4_096
    }

    public static func bundledTinyCLIP() throws -> CLIPBPETokenizer {
        guard let url = Bundle.module.url(forResource: "TinyCLIP-tokenizer", withExtension: "json") else {
            throw CLIPBPETokenizerError.missingBundledVocabulary
        }
        return try CLIPBPETokenizer(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public func tokenize(_ text: String) throws -> MLTokenizedText {
        let normalized = normalize(text)
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        var ids: [Int32] = [Self.startTokenID]
        ids.reserveCapacity(Self.contextLength)

        for match in Self.tokenPattern.matches(in: normalized, range: range) {
            guard let tokenRange = Range(match.range, in: normalized) else { continue }
            let token = String(normalized[tokenRange])
            let encoded = token.utf8.map { byteEncoder[Int($0)] }.joined()

            if let cached = cache.object(forKey: encoded as NSString) {
                ids.append(contentsOf: cached.ids)
                continue
            }

            let pieces = bytePairEncode(encoded)
            let pieceIDs = try pieces.map { piece -> Int32 in
                guard let id = vocabulary[piece] else { throw CLIPBPETokenizerError.unknownToken(piece) }
                return id
            }
            cache.setObject(TokenBox(pieceIDs), forKey: encoded as NSString)
            ids.append(contentsOf: pieceIDs)
        }

        if ids.count >= Self.contextLength {
            ids.removeSubrange((Self.contextLength - 1)..<ids.count)
        }
        ids.append(Self.endTokenID)
        let endIndex = ids.count - 1
        if ids.count < Self.contextLength {
            ids.append(contentsOf: repeatElement(Self.endTokenID, count: Self.contextLength - ids.count))
        }
        return MLTokenizedText(inputIDs: ContiguousArray(ids), endTokenIndex: endIndex)
    }

    private func normalize(_ text: String) -> String {
        let canonical = text.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
        let range = NSRange(canonical.startIndex..<canonical.endIndex, in: canonical)
        return Self.whitespacePattern
            .stringByReplacingMatches(in: canonical, range: range, withTemplate: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bytePairEncode(_ token: String) -> [String] {
        var symbols = token.map(String.init)
        guard !symbols.isEmpty else { return [] }
        symbols[symbols.count - 1] += "</w>"

        while symbols.count > 1 {
            var bestPair: Pair?
            var bestRank = Int.max
            for index in 0..<(symbols.count - 1) {
                let pair = Pair(first: symbols[index], second: symbols[index + 1])
                if let rank = mergeRanks[pair], rank < bestRank {
                    bestPair = pair
                    bestRank = rank
                }
            }
            guard let bestPair else { break }

            var merged: [String] = []
            merged.reserveCapacity(symbols.count)
            var index = 0
            while index < symbols.count {
                if index + 1 < symbols.count,
                   symbols[index] == bestPair.first,
                   symbols[index + 1] == bestPair.second {
                    merged.append(bestPair.first + bestPair.second)
                    index += 2
                } else {
                    merged.append(symbols[index])
                    index += 1
                }
            }
            symbols = merged
        }
        return symbols
    }

    private static func makeByteEncoder() -> [String] {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var scalars = bytes
        var extra = 0
        let known = Set(bytes)
        for byte in 0...255 where !known.contains(byte) {
            bytes.append(byte)
            scalars.append(256 + extra)
            extra += 1
        }

        var result = Array(repeating: "", count: 256)
        for (byte, scalar) in zip(bytes, scalars) {
            guard let unicode = UnicodeScalar(scalar) else { continue }
            result[byte] = String(Character(unicode))
        }
        return result
    }
}
