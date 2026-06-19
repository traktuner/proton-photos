import AppKit
import Testing
import PhotosCore
@testable import TimelineFeature

// MARK: - Pure helpers (no shared global state — safe to run in parallel)

/// Backoff sequence + duration-lookup gate are pure logic, independently verifiable.
@Suite("Perf small pass — pure")
struct PerfSmallPassPureTests {

    // ThumbnailPollingBackoffTest: 120 / 240 / 480 ms, then holds at 480; clamps below 0.
    @MainActor @Test func thumbnailPollingBackoffSequence() {
        #expect(PhotoGridItem.pollBackoffMs(attempt: 0) == 120)
        #expect(PhotoGridItem.pollBackoffMs(attempt: 1) == 240)
        #expect(PhotoGridItem.pollBackoffMs(attempt: 2) == 480)
        #expect(PhotoGridItem.pollBackoffMs(attempt: 3) == 480)   // holds
        #expect(PhotoGridItem.pollBackoffMs(attempt: 50) == 480)  // holds
        #expect(PhotoGridItem.pollBackoffMs(attempt: -7) == 120)  // first check stays fast
    }

    // DurationLookupLimiterTest: at most 4 active, duplicates coalesced, completion promotes one.
    @Test func durationLimiterCapsAndCoalesces() {
        var gate = DurationLookupGate(maxConcurrent: 4)
        let uids = (0..<10).map { PhotoUID(volumeID: "v", nodeID: "\($0)") }

        let decisions = uids.map { gate.request($0) }
        #expect(decisions.prefix(4).allSatisfy { $0 == .start })
        #expect(decisions.dropFirst(4).allSatisfy { $0 == .queued })
        #expect(gate.activeCount == 4)
        #expect(gate.queuedCount == 6)

        // Duplicate uid (active or queued) is ignored — no duplicate task.
        #expect(gate.request(uids[0]) == .ignored)   // currently active
        #expect(gate.request(uids[7]) == .ignored)   // currently queued
        #expect(gate.activeCount == 4)
        #expect(gate.queuedCount == 6)
    }

    @Test func durationLimiterPromotesOnCompletion() {
        var gate = DurationLookupGate(maxConcurrent: 4)
        let uids = (0..<6).map { PhotoUID(volumeID: "v", nodeID: "\($0)") }
        for u in uids { _ = gate.request(u) }
        #expect(gate.activeCount == 4)

        // Completing an active uid promotes the head of the queue and never exceeds the cap.
        let next = gate.complete(uids[0])
        #expect(next == uids[4])
        #expect(gate.activeCount == 4)

        // A completed uid is never re-admitted.
        #expect(gate.request(uids[0]) == .ignored)

        // Drain the rest; active count only ever falls, never exceeds 4.
        _ = gate.complete(uids[1])  // promotes uids[5]
        #expect(gate.activeCount == 4)
        for u in [uids[2], uids[3], uids[4], uids[5]] { _ = gate.complete(u) }
        #expect(gate.activeCount == 0)
        #expect(gate.queuedCount == 0)
    }
}

// MARK: - Counter / cell-rendering behavior (shares PhotoDiagnostics.shared)

/// `.serialized`: these read `PhotoDiagnostics.shared` counter deltas, so they must not run in
/// parallel with one another. They use before/after deltas (not `resetForTests`) so they don't wipe
/// counters out from under other suites.
@Suite("Perf small pass — counters", .serialized)
@MainActor
struct PerfSmallPassCounterTests {

    private func counter(_ key: String) -> Int { PhotoDiagnostics.shared.counter(key) }

    private static func solidImage(width: Int, height: Int) -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 200, count: bytesPerRow * height)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    // DisplayedImageRectCacheInvalidationTest
    @Test func displayedImageRectCacheInvalidation() {
        let view = RoundedCellView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.thumbnailImage = Self.solidImage(width: 200, height: 100)
        view.showsPlaceholder = false
        view.cropMode = .aspectFit

        let hit0 = counter("perf.displayedRectCacheHit")
        let miss0 = counter("perf.displayedRectCacheMiss")

        _ = view.displayedImageRect   // miss (cold)
        _ = view.displayedImageRect   // hit (identical inputs)
        #expect(counter("perf.displayedRectCacheHit") - hit0 == 1)
        #expect(counter("perf.displayedRectCacheMiss") - miss0 == 1)

        view.cropMode = .squareFill   // crop mode changed → recompute
        _ = view.displayedImageRect
        #expect(counter("perf.displayedRectCacheMiss") - miss0 == 2)

        view.thumbnailImage = Self.solidImage(width: 100, height: 100)  // image size changed → recompute
        _ = view.displayedImageRect
        #expect(counter("perf.displayedRectCacheMiss") - miss0 == 3)

        view.frame = NSRect(x: 0, y: 0, width: 50, height: 50)          // bounds changed → recompute
        _ = view.displayedImageRect
        #expect(counter("perf.displayedRectCacheMiss") - miss0 == 4)

        _ = view.displayedImageRect   // stable again → hit
        #expect(counter("perf.displayedRectCacheHit") - hit0 == 2)
    }

    // PlaceholderDirectFillTest
    @Test func placeholderDrawsDirectFillWithoutImageOrRectCompute() {
        let view = RoundedCellView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        view.showsPlaceholder = true   // placeholderImage is assigned by init (production state)

        let fill0 = counter("perf.placeholderDirectFill")
        let miss0 = counter("perf.displayedRectCacheMiss")

        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)

        // Direct fill ran; the image-rect compute path was NOT entered for the placeholder (so the
        // placeholder is not drawn through the CGImage/interpolation path).
        #expect(counter("perf.placeholderDirectFill") - fill0 >= 1)
        #expect(counter("perf.displayedRectCacheMiss") - miss0 == 0)

        // displayedImageRect is still valid (== bounds) for the placeholder, so the badge can place.
        #expect(view.displayedImageRect == view.bounds)

        // The center pixel is the placeholder gray (~46/255), not transparent/black — no empty hole.
        if let color = rep.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB) {
            #expect(abs(color.redComponent - 46.0 / 255) < 0.04)
            #expect(abs(color.redComponent - color.greenComponent) < 0.02)
            #expect(color.alphaComponent > 0.9)
        } else {
            Issue.record("placeholder produced no sampleable pixel")
        }
    }

    // BadgeLayoutSkipTest
    @Test func badgeLayoutSkipsUnchangedInputs() {
        let item = PhotoGridItem()
        item.view.frame = NSRect(x: 0, y: 0, width: 100, height: 100)

        item.setDuration(5)              // badge visible; first layout (not a skip)
        let skip0 = counter("perf.badgeLayoutSkipped")

        item.setCropMode(.aspectFit)     // same imageRect/bounds/text → skip
        item.setCropMode(.aspectFit)     // skip
        #expect(counter("perf.badgeLayoutSkipped") - skip0 == 2)

        item.setDuration(125)            // text changed "0:05"→"2:05" → real layout (no skip)
        #expect(counter("perf.badgeLayoutSkipped") - skip0 == 2)

        item.setCropMode(.aspectFit)     // inputs match the new text → skip again
        #expect(counter("perf.badgeLayoutSkipped") - skip0 == 3)
    }

    // DiagnosticsCounterAccuracyTest (Part 9): presence checks are NOT counted as disk reads.
    @Test func diskPresenceCheckNotCountedAsDiskRead() {
        let d = PhotoDiagnostics.shared
        d.setActivePinch(true)
        defer { d.setActivePinch(false) }

        let before = d.hotPathCounters()
        d.recordDiskPresenceCheckDuringPinch()
        d.recordDiskPresenceCheckDuringPinch()
        d.recordDiskReadDuringPinch()
        let after = d.hotPathCounters()

        #expect(after.diskPresenceCheckDuringPinch - before.diskPresenceCheckDuringPinch == 2)
        #expect(after.diskReadDuringPinch - before.diskReadDuringPinch == 1)

        // Outside a pinch both are ignored.
        d.setActivePinch(false)
        let idle = d.hotPathCounters()
        d.recordDiskPresenceCheckDuringPinch()
        d.recordDiskReadDuringPinch()
        let stillIdle = d.hotPathCounters()
        #expect(stillIdle.diskPresenceCheckDuringPinch == idle.diskPresenceCheckDuringPinch)
        #expect(stillIdle.diskReadDuringPinch == idle.diskReadDuringPinch)
    }
}
