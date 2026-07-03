import AppKit
import Testing
import PhotosCore
import MediaCache
@testable import TimelineFeature

/// Proves the feed adapter's governor hook (`applyMemoryPressure`) scales/purges BOTH RAM tiers it owns —
/// the platform-image wrapper cache (shared `WrapperImageCache`) and the decoded-CGImage core tier — and
/// that a restored scale lets the tiers refill from the encrypted disk cache. The AppKit and UIKit feeds
/// share this exact structure (same wrapper cache type, same `applyDecodedMemoryPressure` core hook), so
/// this locks the behavior for both platforms.
@Suite struct ThumbnailFeedMemoryPressureTests {
    private struct StubLoader: ThumbnailBatchLoader {
        func loadThumbnails(
            for uids: [PhotoUID],
            onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
        ) async -> ThumbnailBatchLoadResult {
            ThumbnailBatchLoadResult()
        }
    }

    private static func pngData(side: Int = 12) -> Data {
        let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func pressurePurgesWrapperAndDecodedTiersAndRestoreRefills() async throws {
        let uid = PhotoUID(volumeID: "vol", nodeID: "pressure-\(UUID().uuidString)")
        let cache = ThumbnailCache(
            namespace: "feed-pressure-\(UUID().uuidString)",
            rootDirectory: timelineFeatureTestCacheRoot("feed-pressure")
        )
        cache.storeToDisk(Self.pngData(), for: uid)
        let feed = ThumbnailFeed(cache: cache, loader: StubLoader(), concurrency: 1, batch: 1)

        // Warm disk → RAM, then touch the wrapper tier so both tiers hold the image.
        let warmed = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(warmed.decodedFromDisk == 1)
        #expect(feed.memoryImage(for: uid) != nil)
        #expect(feed.memoryCGImage(for: uid) != nil)

        // Critical tier: purge now. BOTH tiers must drop — the wrapper cannot silently rebuild either,
        // because the decoded tier underneath it is gone too.
        feed.applyMemoryPressure(scale: 0.0, purge: true)
        #expect(feed.memoryCGImage(for: uid) == nil)
        #expect(feed.memoryImage(for: uid) == nil)

        // Recovery: full budgets restored → the same bytes re-decode from the (untouched) disk tier.
        feed.applyMemoryPressure(scale: 1.0, purge: false)
        let rewarmed = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(rewarmed.decodedFromDisk == 1)
        #expect(feed.memoryImage(for: uid) != nil)
    }
}
