import Foundation
import Testing
import PhotosCore

/// The binary-search `slices` / `forwardBlocks` must be byte-for-byte identical to a straightforward
/// linear scan. These tests pin that equivalence on hand-picked edges and on many random maps, plus
/// the prefetch read-ahead window the resource loader schedules from.
@Suite("VideoBlockMap binary search")
struct VideoBlockMapBinarySearchTests {

    // MARK: - Linear reference implementations (the behavior the binary search must preserve)

    private func linearSlices(_ map: VideoBlockMap, offset: Int, length: Int) -> [BlockSlice] {
        let reqStart = max(0, offset)
        let reqEnd = min(offset + length, map.totalSize)
        guard reqStart < reqEnd else { return [] }
        var out: [BlockSlice] = []
        for block in map.blocks where block.clearSize > 0 {
            let bStart = block.clearOffset
            let bEnd = bStart + block.clearSize
            if bEnd <= reqStart { continue }
            if bStart >= reqEnd { break }
            let from = max(reqStart, bStart) - bStart
            let to = min(reqEnd, bEnd) - bStart
            if from < to {
                out.append(BlockSlice(blockIndex: block.index,
                                      inBlock: ByteRange(lower: from, upper: to),
                                      fileOffset: bStart + from))
            }
        }
        return out
    }

    private func linearForwardBlocks(_ map: VideoBlockMap, afterClearOffset offset: Int, count: Int) -> [ClearBlock] {
        Array(map.blocks.filter { $0.clearSize > 0 && $0.clearOffset + $0.clearSize > offset }.prefix(count))
    }

    // MARK: - Hand-picked edges

    private var map: VideoBlockMap { VideoBlockMap(blockSizes: [(1, 100), (2, 100), (3, 100)], totalOverride: 300) }

    @Test func rangeStartsBeforeFirstBlock() {
        #expect(map.slices(offset: -50, length: 70) == linearSlices(map, offset: -50, length: 70))
        // Negative offset clamps to 0 then maps into block 1.
        #expect(map.slices(offset: -50, length: 70).first?.blockIndex == 1)
    }

    @Test func rangeStartsInsideABlock() {
        #expect(map.slices(offset: 150, length: 30) == linearSlices(map, offset: 150, length: 30))
        #expect(map.slices(offset: 150, length: 30) == [BlockSlice(blockIndex: 2, inBlock: ByteRange(lower: 50, upper: 80), fileOffset: 150)])
    }

    @Test func rangeSpansMultipleBlocks() {
        #expect(map.slices(offset: 90, length: 120) == linearSlices(map, offset: 90, length: 120))
        #expect(map.slices(offset: 90, length: 120).map(\.blockIndex) == [1, 2, 3])
    }

    @Test func rangeEndsExactlyAtBlockBoundary() {
        // [100,200) ends exactly where block 2 ends — block 3 must NOT be included.
        #expect(map.slices(offset: 100, length: 100) == linearSlices(map, offset: 100, length: 100))
        #expect(map.slices(offset: 100, length: 100).map(\.blockIndex) == [2])
    }

    @Test func emptyBlocksAreIgnored() {
        let withHoles = VideoBlockMap(blockSizes: [(1, 100), (2, 0), (3, 100), (4, 0), (5, 100)], totalOverride: 300)
        for (offset, length) in [(0, 300), (90, 30), (100, 100), (199, 5), (0, 1)] {
            #expect(withHoles.slices(offset: offset, length: length) == linearSlices(withHoles, offset: offset, length: length))
        }
        // No zero-size block index ever appears.
        #expect(!withHoles.slices(offset: 0, length: 300).contains { [2, 4].contains($0.blockIndex) })
    }

    @Test func outOfRangeRequestReturnsEmpty() {
        #expect(map.slices(offset: 300, length: 10).isEmpty)
        #expect(map.slices(offset: 1000, length: 10).isEmpty)
        #expect(map.slices(offset: 50, length: 0).isEmpty)
    }

    // MARK: - Randomized equivalence

    @Test func matchesLinearForRandomMaps() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let blockCount = Int.random(in: 1...40, using: &rng)
            let sizes: [(index: Int, clearSize: Int)] = (1...blockCount).map { idx in
                // Mix in occasional zero-size blocks.
                (idx, Bool.random(using: &rng) && idx % 7 == 0 ? 0 : Int.random(in: 1...500, using: &rng))
            }
            let map = VideoBlockMap(blockSizes: sizes)
            let total = map.totalSize
            for _ in 0..<12 {
                let offset = Int.random(in: -50...(total + 50), using: &rng)
                let length = Int.random(in: 0...(total + 50), using: &rng)
                #expect(map.slices(offset: offset, length: length) == linearSlices(map, offset: offset, length: length))
            }
        }
    }

    // MARK: - Forward prefetch read-ahead window (ForwardPrefetchDedupTest support)

    @Test func forwardBlocksMatchesLinearFilter() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let blockCount = Int.random(in: 1...30, using: &rng)
            let sizes: [(index: Int, clearSize: Int)] = (1...blockCount).map { ($0, Int.random(in: 0...400, using: &rng)) }
            let map = VideoBlockMap(blockSizes: sizes)
            for _ in 0..<8 {
                let offset = Int.random(in: -10...(map.totalSize + 10), using: &rng)
                let count = Int.random(in: 0...6, using: &rng)
                #expect(map.forwardBlocks(afterClearOffset: offset, count: count) == linearForwardBlocks(map, afterClearOffset: offset, count: count))
            }
        }
    }

    @Test func forwardBlocksIsDeterministicAndAdvances() {
        // Repeating the same offset yields the identical read-ahead set — the loader dedups against the
        // last scheduled offset, so an unchanged offset re-schedules nothing new.
        let m = VideoBlockMap(blockSizes: [(1, 100), (2, 100), (3, 100), (4, 100)], totalOverride: 400)
        #expect(m.forwardBlocks(afterClearOffset: 0, count: 2) == m.forwardBlocks(afterClearOffset: 0, count: 2))
        #expect(m.forwardBlocks(afterClearOffset: 0, count: 2).map(\.index) == [1, 2])
        // Advancing past block 1 drops it from the window.
        #expect(m.forwardBlocks(afterClearOffset: 100, count: 2).map(\.index) == [2, 3])
        #expect(m.forwardBlocks(afterClearOffset: 250, count: 4).map(\.index) == [3, 4])
        #expect(m.forwardBlocks(afterClearOffset: 400, count: 4).isEmpty)
    }
}
