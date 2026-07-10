import Foundation

public struct MLTokenizedText: Sendable, Equatable {
    public let inputIDs: ContiguousArray<Int32>
    public let endTokenIndex: Int

    public init(inputIDs: ContiguousArray<Int32>, endTokenIndex: Int) {
        self.inputIDs = inputIDs
        self.endTokenIndex = endTokenIndex
    }
}

public protocol MLTextTokenizer: Sendable {
    /// Fixed token count this tokenizer produces. Sessions must refuse to start when it does
    /// not match the catalog entry's runtime contract.
    var contextLength: Int { get }
    func tokenize(_ text: String) throws -> MLTokenizedText
}
