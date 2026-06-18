import Foundation
import Testing
import PhotosCore

/// Tests for the native video playback pipeline (detection, byte-range math, cache merge, error
/// mapping, state-machine liveness). All pure — no AVFoundation / network — so they're deterministic.
@Suite("Video playback")
struct VideoPlaybackTests {

    // MARK: - Detection (VideoDetectionTest)

    @Test func detectsByExtension() {
        #expect(VideoContentSniffer.kind(filename: "clip.mp4") == .video)
        #expect(VideoContentSniffer.kind(filename: "clip.MOV") == .video)
        #expect(VideoContentSniffer.kind(filename: "clip.m4v") == .video)
        #expect(VideoContentSniffer.kind(filename: "photo.jpg") == .image)
        #expect(VideoContentSniffer.kind(filename: "photo.HEIC") == .image)
        #expect(VideoContentSniffer.kind(filename: "mystery.bin") == .unknown)
    }

    @Test func detectsByMime() {
        #expect(VideoContentSniffer.kind(mimeType: "video/quicktime") == .video)
        #expect(VideoContentSniffer.kind(mimeType: "image/png") == .image)
        // The timeline's generic placeholder must NOT short-circuit to image — it's untrustworthy.
        #expect(VideoContentSniffer.kind(mimeType: "") == .unknown)
    }

    @Test func unknownExtensionUsesContentSniff() {
        // Extensionless name + a real MP4 `ftyp` header → classified as video.
        let header = ftypHeader(brand: "isom")
        #expect(VideoContentSniffer.classify(mimeType: "image/jpeg", filename: "IMG_0001", header: header) == .image)
        // When MIME and name are both unknown, the header decides.
        #expect(VideoContentSniffer.classify(mimeType: nil, filename: "IMG_0001", header: header) == .video)
        #expect(VideoContentSniffer.classify(mimeType: nil, filename: nil, header: jpegHeader()) == .image)
    }

    // MARK: - Extension sniffing (ExtensionSniffingTest)

    @Test func sniffsContainerExtension() {
        #expect(VideoContentSniffer.videoExtension(forHeader: ftypHeader(brand: "isom")) == "mp4")
        #expect(VideoContentSniffer.videoExtension(forHeader: ftypHeader(brand: "mp42")) == "mp4")
        #expect(VideoContentSniffer.videoExtension(forHeader: ftypHeader(brand: "qt  ")) == "mov")
        // Not a container → nil (caller defaults).
        #expect(VideoContentSniffer.videoExtension(forHeader: jpegHeader()) == nil)
        #expect(VideoContentSniffer.videoExtension(forHeader: Data([0, 1, 2])) == nil)
        // HEIC is an ftyp box but an image, not a playable video container.
        #expect(VideoContentSniffer.headerIsImage(ftypHeader(brand: "heic")))
        #expect(!VideoContentSniffer.headerIsVideo(ftypHeader(brand: "heic")))
        #expect(VideoContentSniffer.videoExtension(forHeader: ftypHeader(brand: "heic")) == nil)
        #expect(VideoContentSniffer.classify(mimeType: nil, filename: nil, header: ftypHeader(brand: "heic")) == .image)
    }

    // MARK: - Range slicing (ResourceLoaderRangeTest)

    /// 3 blocks of 100 bytes each (indices 1..3), total 300.
    private var map: VideoBlockMap {
        VideoBlockMap(blockSizes: [(1, 100), (2, 100), (3, 100)], totalOverride: 300)
    }

    @Test func sliceWithinSingleBlock() {
        let slices = map.slices(offset: 10, length: 20)   // [10,30) — all inside block 1
        #expect(slices.count == 1)
        #expect(slices[0].blockIndex == 1)
        #expect(slices[0].inBlock == ByteRange(lower: 10, upper: 30))
        #expect(slices[0].fileOffset == 10)
    }

    @Test func sliceSpanningBlocks() {
        let slices = map.slices(offset: 90, length: 120)   // [90,210) — blocks 1,2,3
        #expect(slices.map(\.blockIndex) == [1, 2, 3])
        // Contiguity: concatenated slice lengths == requested length.
        #expect(slices.reduce(0) { $0 + $1.inBlock.length } == 120)
        #expect(slices[0].inBlock == ByteRange(lower: 90, upper: 100))
        #expect(slices[1].inBlock == ByteRange(lower: 0, upper: 100))
        #expect(slices[2].inBlock == ByteRange(lower: 0, upper: 10))
    }

    @Test func sliceClampsToFileSize() {
        let slices = map.slices(offset: 250, length: 1000)   // clamps to [250,300)
        #expect(slices.reduce(0) { $0 + $1.inBlock.length } == 50)
        #expect(slices.last?.blockIndex == 3)
        #expect(map.slices(offset: 300, length: 10).isEmpty)  // fully past EOF
    }

    @Test func repeatedAndOverlappingRequestsAreDeterministic() {
        // Asking twice (overlapping) yields identical slices — the loader can dedup against its cache.
        #expect(map.slices(offset: 50, length: 100) == map.slices(offset: 50, length: 100))
        let a = map.slices(offset: 0, length: 150)
        let b = map.slices(offset: 100, length: 50)
        // The overlap region (block 2) maps to the same block index in both.
        #expect(a.contains { $0.blockIndex == 2 })
        #expect(b.contains { $0.blockIndex == 2 })
    }

    // MARK: - Seek prioritization (SeekPrioritizationTest)

    @Test func seekRequestsOnlyTheNeededBlocks() {
        // A seek to the last block must NOT re-pull earlier blocks.
        let indices = map.blockIndices(offset: 220, length: 40)   // inside block 3
        #expect(indices == [3])
        // And an initial-play request for the head only touches block 1.
        #expect(map.blockIndices(offset: 0, length: 50) == [1])
    }

    // MARK: - Cache range merge (CacheRangeMergeTest)

    @Test func byteRangeSetMergesAdjacentAndOverlapping() {
        var set = ByteRangeSet()
        set.insert(ByteRange(lower: 0, upper: 10))
        set.insert(ByteRange(lower: 10, upper: 20))   // abuts → merges
        #expect(set.ranges == [ByteRange(lower: 0, upper: 20)])

        set.insert(ByteRange(lower: 5, upper: 25))    // overlaps → extends
        #expect(set.ranges == [ByteRange(lower: 0, upper: 25)])

        set.insert(ByteRange(lower: 40, upper: 50))   // disjoint → separate
        #expect(set.ranges == [ByteRange(lower: 0, upper: 25), ByteRange(lower: 40, upper: 50)])
        #expect(set.coveredBytes == 35)
    }

    @Test func byteRangeSetReportsHoles() {
        var set = ByteRangeSet()
        set.insert(ByteRange(lower: 0, upper: 30))
        set.insert(ByteRange(lower: 60, upper: 100))
        #expect(set.covers(ByteRange(lower: 0, upper: 20)))
        #expect(!set.covers(ByteRange(lower: 0, upper: 50)))
        #expect(set.missingPieces(in: ByteRange(lower: 0, upper: 100)) == [ByteRange(lower: 30, upper: 60)])
        #expect(set.missingPieces(in: ByteRange(lower: 0, upper: 30)).isEmpty)
    }

    // MARK: - Error mapping (ErrorMappingTest)

    @Test func mapsNetworkErrors() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(VideoPlaybackError.classify(offline) == .networkUnavailable)
    }

    @Test func mapsCodecErrors() {
        let codec = NSError(domain: "AVFoundationErrorDomain", code: -11828)
        #expect(VideoPlaybackError.classify(codec) == .unsupportedCodec)
        #expect(VideoPlaybackError.unsupportedCodec.isRetryable == false)
    }

    @Test func mapsHTTPStatusErrors() {
        #expect(VideoPlaybackError.classify(apiError(401)) == .authExpired)
        #expect(VideoPlaybackError.classify(apiError(429)) == .quotaOrRateLimited)
        #expect(VideoPlaybackError.classify(apiError(416)) == .rangeNotSupported)
    }

    @Test func mapsDecryptionErrors() {
        let decrypt = NSError(domain: "Custom", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "block decrypt failed"])
        #expect(VideoPlaybackError.classify(decrypt) == .decryptionFailed)
    }

    // MARK: - No infinite spinner (NoInfiniteSpinnerTest)

    @Test func everyTerminalStatusLeavesLoading() {
        // readyToPlay and failed are ALWAYS terminal (never nil ⇒ never "keep spinning"); only
        // `unknown` keeps the current state, and that is what the watchdog guards.
        #expect(VideoPlayerItemStatus.readyToPlay.nextState(error: nil) != nil)
        #expect(VideoPlayerItemStatus.failed.nextState(error: nil) != nil)

        // Busy states are mutually exclusive with playing/failed; nothing is both "busy" and terminal.
        let states: [VideoViewerState] = [
            .idle, .resolving, .preparingStream, .downloading(0.5), .buffering(nil),
            .ready, .playing, .seeking, .failed(.timedOut),
        ]
        for s in states {
            if s.isBusy { #expect(s.error == nil && s != .playing) }
            if case .failed = s { #expect(!s.isBusy) }
            if s == .playing { #expect(!s.isBusy) }
        }
    }

    // MARK: - Helpers

    private func ftypHeader(brand: String) -> Data {
        var d = Data([0, 0, 0, 0x18])                 // box size
        d.append(contentsOf: Array("ftyp".utf8))      // box type
        d.append(contentsOf: Array(brand.utf8).prefix(4))
        while d.count < 12 { d.append(0) }
        return d
    }

    private func jpegHeader() -> Data { Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0]) }

    private func apiError(_ status: Int) -> NSError {
        NSError(domain: "ProtonAuth", code: status,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(status) for /drive/x"])
    }
}
