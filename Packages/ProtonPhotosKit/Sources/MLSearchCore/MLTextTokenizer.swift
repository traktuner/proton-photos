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
    func tokenize(_ text: String) throws -> MLTokenizedText
}
