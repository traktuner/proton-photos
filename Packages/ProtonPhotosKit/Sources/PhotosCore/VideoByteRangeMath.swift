import Foundation

/// A half-open byte range `[lower, upper)` into the *cleartext* file. Pure value type so the range
/// bookkeeping the streaming loader and the byte cache depend on can be unit-tested without any
/// AVFoundation / network involvement.
public struct ByteRange: Equatable, Sendable, Comparable {
    public var lower: Int   // inclusive
    public var upper: Int   // exclusive

    public init(lower: Int, upper: Int) {
        precondition(lower <= upper, "ByteRange lower must be <= upper")
        self.lower = lower
        self.upper = upper
    }

    public init(offset: Int, length: Int) {
        self.init(lower: offset, upper: offset + length)
    }

    public var length: Int { upper - lower }
    public var isEmpty: Bool { upper <= lower }

    public func contains(_ offset: Int) -> Bool { offset >= lower && offset < upper }

    /// Intersection with `other`, or `nil` if they don't overlap.
    public func intersection(_ other: ByteRange) -> ByteRange? {
        let lo = Swift.max(lower, other.lower)
        let hi = Swift.min(upper, other.upper)
        return lo < hi ? ByteRange(lower: lo, upper: hi) : nil
    }

    public static func < (a: ByteRange, b: ByteRange) -> Bool {
        a.lower != b.lower ? a.lower < b.lower : a.upper < b.upper
    }
}

/// A set of non-overlapping, coalesced byte ranges - the "what have we got on disk?" model for the
/// byte cache and the buffered-progress UI. Adjacent and overlapping ranges merge automatically so
/// `CacheRangeMergeTest` holds: inserting `[0,10)` then `[10,20)` yields a single `[0,20)`.
public struct ByteRangeSet: Equatable, Sendable {
    public private(set) var ranges: [ByteRange]

    public init(_ ranges: [ByteRange] = []) {
        self.ranges = []
        for r in ranges { insert(r) }
    }

    public var isEmpty: Bool { ranges.isEmpty }

    /// Total covered bytes across all ranges.
    public var coveredBytes: Int { ranges.reduce(0) { $0 + $1.length } }

    /// Inserts a range, merging it with any that overlap or abut it (so the set stays minimal).
    public mutating func insert(_ range: ByteRange) {
        guard !range.isEmpty else { return }
        var merged = range
        var result: [ByteRange] = []
        for r in ranges {
            if r.upper < merged.lower || r.lower > merged.upper {
                result.append(r)            // disjoint (and not abutting) - keep as is
            } else {
                merged = ByteRange(lower: Swift.min(r.lower, merged.lower),
                                   upper: Swift.max(r.upper, merged.upper))
            }
        }
        result.append(merged)
        result.sort()
        ranges = result
    }

    /// True if `range` is fully covered by the set (no holes).
    public func covers(_ range: ByteRange) -> Bool {
        guard !range.isEmpty else { return true }
        var cursor = range.lower
        for r in ranges where r.lower <= cursor {
            if r.upper > cursor { cursor = r.upper }
            if cursor >= range.upper { return true }
        }
        return cursor >= range.upper
    }

    /// The sub-ranges of `range` NOT yet covered (the holes the loader still has to fetch).
    public func missingPieces(in range: ByteRange) -> [ByteRange] {
        guard !range.isEmpty else { return [] }
        var holes: [ByteRange] = []
        var cursor = range.lower
        for r in ranges.sorted() {
            guard r.upper > range.lower, r.lower < range.upper else { continue }
            if r.lower > cursor { holes.append(ByteRange(lower: cursor, upper: Swift.min(r.lower, range.upper))) }
            cursor = Swift.max(cursor, r.upper)
            if cursor >= range.upper { break }
        }
        if cursor < range.upper { holes.append(ByteRange(lower: cursor, upper: range.upper)) }
        return holes
    }
}

/// One cleartext block of the file: its index plus where its decrypted bytes live in the whole file.
/// (The encrypted bytes are larger due to PGP overhead, but AVFoundation only ever sees cleartext
/// offsets, so the map is expressed entirely in cleartext coordinates.)
public struct ClearBlock: Equatable, Sendable {
    public let index: Int          // 1-based block index (matches Proton's revision block index)
    public let clearOffset: Int    // byte offset of this block's first decrypted byte in the file
    public let clearSize: Int      // decrypted length of this block

    public init(index: Int, clearOffset: Int, clearSize: Int) {
        self.index = index
        self.clearOffset = clearOffset
        self.clearSize = clearSize
    }

    public var clearRange: ByteRange { ByteRange(offset: clearOffset, length: clearSize) }
}

/// One block's contribution to a requested range: which block to read, and the sub-slice of that
/// block's *decrypted* bytes to hand back. Returned in file order so concatenating the slices yields
/// exactly the requested window with no gaps - the contiguity AVFoundation requires.
public struct BlockSlice: Equatable, Sendable {
    public let blockIndex: Int
    /// Byte range *within the decrypted block* (0-based) to copy out.
    public let inBlock: ByteRange
    /// Where these bytes land in the file (absolute cleartext offset of `inBlock.lower`).
    public let fileOffset: Int

    public init(blockIndex: Int, inBlock: ByteRange, fileOffset: Int) {
        self.blockIndex = blockIndex
        self.inBlock = inBlock
        self.fileOffset = fileOffset
    }
}

/// Maps an arbitrary requested byte range onto the ordered list of block slices that cover it. This
/// is the native equivalent of Proton Drive Web's `blockSizes[]`→block-indices mapping (the legacy
/// `useVideoStreaming` service-worker path): given the cleartext block sizes, a `Range` request is
/// resolved to the specific blocks to download + decrypt and the exact sub-slices to return.
public struct VideoBlockMap: Sendable {
    public let blocks: [ClearBlock]
    public let totalSize: Int

    /// Builds the map from cleartext block sizes (in revision-index order). `totalOverride` prefers
    /// the authoritative size from XAttr; otherwise the summed block sizes are used.
    public init(blockSizes: [(index: Int, clearSize: Int)], totalOverride: Int? = nil) {
        var built: [ClearBlock] = []
        var offset = 0
        for b in blockSizes.sorted(by: { $0.index < $1.index }) {
            built.append(ClearBlock(index: b.index, clearOffset: offset, clearSize: b.clearSize))
            offset += b.clearSize
        }
        self.blocks = built
        let summed = offset
        self.totalSize = (totalOverride.map { $0 > 0 ? $0 : summed }) ?? summed
    }

    public init(blocks: [ClearBlock], totalSize: Int) {
        self.blocks = blocks
        self.totalSize = totalSize
    }

    /// The ordered block slices needed to satisfy a request for `length` bytes starting at `offset`.
    /// Clamps to the file size, skips empty blocks, and returns slices in file order so the loader
    /// can stream `respond(with:)` calls contiguously. An out-of-range request returns `[]`.
    ///
    /// Blocks are stored in ascending `clearOffset` order (so their cleartext *ends* are non-decreasing);
    /// a binary search skips straight to the first block that can overlap the window instead of scanning
    /// every block from the front - the output is byte-for-byte identical to the old linear scan.
    public func slices(offset: Int, length: Int) -> [BlockSlice] {
        let reqStart = Swift.max(0, offset)
        let reqEnd = Swift.min(offset + length, totalSize)
        guard reqStart < reqEnd else { return [] }
        var out: [BlockSlice] = []
        var i = firstBlockIndex(endGreaterThan: reqStart)
        while i < blocks.count {
            let block = blocks[i]
            i += 1
            guard block.clearSize > 0 else { continue }
            let bStart = block.clearOffset
            let bEnd = bStart + block.clearSize
            if bStart >= reqEnd { break }        // past the window (blocks are ordered)
            let from = Swift.max(reqStart, bStart) - bStart
            let to = Swift.min(reqEnd, bEnd) - bStart
            if from < to {
                out.append(BlockSlice(blockIndex: block.index,
                                      inBlock: ByteRange(lower: from, upper: to),
                                      fileOffset: bStart + from))
            }
        }
        return out
    }

    /// The block indices a request touches (for prefetch / cancellation bookkeeping).
    public func blockIndices(offset: Int, length: Int) -> [Int] {
        slices(offset: offset, length: length).map(\.blockIndex)
    }

    /// Up to `count` non-empty blocks (in file order) whose cleartext bytes extend past `clearOffset` -
    /// the read-ahead set for forward prefetch. Binary-searches to the first candidate so a large block
    /// count isn't rescanned linearly on every range request. Equivalent to
    /// `blocks.filter { $0.clearSize > 0 && $0.clearOffset + $0.clearSize > clearOffset }.prefix(count)`.
    public func forwardBlocks(afterClearOffset clearOffset: Int, count: Int) -> [ClearBlock] {
        guard count > 0 else { return [] }
        var out: [ClearBlock] = []
        var i = firstBlockIndex(endGreaterThan: clearOffset)
        while i < blocks.count, out.count < count {
            let block = blocks[i]
            i += 1
            if block.clearSize > 0 { out.append(block) }
        }
        return out
    }

    /// Index of the first block whose cleartext *end* (`clearOffset + clearSize`) is strictly greater
    /// than `offset` - i.e. the first block that could contain or follow `offset`. Block ends are
    /// non-decreasing, so this is a standard lower-bound binary search.
    func firstBlockIndex(endGreaterThan offset: Int) -> Int {
        var lo = 0
        var hi = blocks.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if blocks[mid].clearOffset + blocks[mid].clearSize > offset {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        return lo
    }
}
