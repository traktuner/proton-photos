#if canImport(UIKit)
import CoreGraphics
import GridCore
import MediaCacheUIKitAdapter
import MetalGridTextureCore
import PhotosCore
import TimelineUIKitAdapter
import UIKit

/// The grid host's decode/warm pipeline: the feed's arrival wake, the visible warm pass, and the
/// direction-biased scroll-ahead prefetch — all strictly subordinate to the render loop in
/// `UIKitTimelineGridHost.swift`, which schedules them from settled frames only.
extension UIKitTimelineGridHostView {
    /// Arrival wake from the shared feed (a background download landed thumbnails on disk while this viewport is
    /// live). Re-warm the still-missing visible cells (decoding the new bytes disk→RAM) and redraw — this is what
    /// lets the render loop legitimately idle through a network wait instead of spinning, since an arrival always
    /// re-arms it. One-hop to the main actor; the pump coalesces the redraw to at most one frame.
    func handleImagesAvailable() {
        warmNeedsRepass = true
        requestRender()
    }

    func newestFirst(_ uids: [PhotoUID]) -> [PhotoUID] {
        uids.sorted { lhs, rhs in
            (itemIndexByUID[lhs] ?? -1) > (itemIndexByUID[rhs] ?? -1)
        }
    }

    /// The still-missing visible tiles (newest-first, reliability-critical order) followed by any additional warm
    /// UIDs the composer requested (upgrade re-decode sources), de-duplicated. A no-op-ish superset when settled
    /// is off (the composer's warm list is then just the missing tiles).
    func warmUnion(_ missing: [PhotoUID], _ streamWarm: [PhotoUID]) -> [PhotoUID] {
        guard !streamWarm.isEmpty else { return missing }
        var out = missing
        var seen = Set(missing)
        for uid in streamWarm where seen.insert(uid).inserted { out.append(uid) }
        return out
    }

    /// Pre-decode the rows just beyond the streamed window in the user's travel direction, disk→RAM, at
    /// `.nearViewportScrollAhead` priority — the shared `GridScrollAheadPolicy` range over this host's flat
    /// UID order. Strictly subordinate to visible work: it runs only on settled frames with NO visible warm
    /// pass in flight, decodes in small chunks, and aborts between chunks the moment a visible pass starts.
    /// RAM-neutral by design — it fills the EXISTING decoded budget ahead of need; no cache grows.
    func scheduleScrollAheadWarmIfIdle(plan: GridFramePlan) {
        // Never pre-warm ahead for an inactive/hidden grid — that would decode disk→RAM off-screen while the
        // user is in another tab/menu. (renderNow only runs when active, so this is defense-in-depth.)
        guard framePump.isActive else { return }
        guard let thumbnailFeed, let down = scrollDirectionDown, !itemUIDs.isEmpty else { return }
        guard !warmInFlight, !aheadWarmInFlight else { return }
        let indices = plan.visibleSlots.map(\.index)
        guard let minIndex = indices.min(), let maxIndex = indices.max() else { return }
        let range = GridScrollAheadPolicy.aheadRange(
            coveredIndexRange: minIndex ... maxIndex,
            itemCount: itemUIDs.count,
            columns: plan.columns,
            rowsAhead: 3,
            direction: down ? .towardHigherIndices : .towardLowerIndices
        )
        guard !range.isEmpty else { return }
        let key = "\(range.lowerBound)-\(range.upperBound)-\(down)-\(plan.levelID)"
        guard key != lastAheadKey else { return }
        lastAheadKey = key
        let missing = range
            .map { itemUIDs[$0] }
            .filter { thumbnailFeed.memoryCGImage(for: $0) == nil && !thumbnailFeed.isKnownUnfetchable($0) }
        guard !missing.isEmpty else { return }
        let pixelSize = GridTextureUploadSizing.uploadPixels(
            slotSidePoints: plan.slotSide,
            backingScale: metalView.metalLayer.contentsScale,
            headroom: 1.15,
            floor: 64,
            cap: textureCache?.maxTexturePixels ?? 320
        )
        let requests = missing.map { ThumbnailRequest(uid: $0, pixelSize: pixelSize, cropMode: displayMode.rawValue) }
        aheadWarmInFlight = true
        aheadWarmTask = Task { [weak self, thumbnailFeed] in
            // Small chunks so a visible warm pass (which takes strict priority) never waits behind a long
            // ahead batch on the serial feed actor; abort the remainder the moment visible work starts.
            for chunk in stride(from: 0, to: requests.count, by: 12).map({ Array(requests[$0 ..< min($0 + 12, requests.count)]) }) {
                if Task.isCancelled { break }
                let visibleBusy = await MainActor.run { [weak self] in self?.warmInFlight ?? true }
                if visibleBusy { break }
                _ = await thumbnailFeed.warmDecoded(chunk, priority: .nearViewportScrollAhead, limit: chunk.count)
            }
            await MainActor.run { [weak self] in self?.aheadWarmInFlight = false }
        }
    }

    /// Decode the still-missing visible cells disk→RAM (queuing network for the rest), at most one pass at a time.
    ///
    /// The gate is `warmInFlight`, NOT exact-set equality: a pass is re-issued whenever the missing set changed OR
    /// `warmNeedsRepass` was raised (a feed arrival / demand move). That is what fixes "black until the user
    /// scrolls a nudge further" — under a STATIC viewport, a tile whose bytes land on disk (via the crawl worker,
    /// which only stores to disk) is re-warmed on the next pass and decoded into the RAM tier the renderer reads,
    /// instead of being permanently deduped away because the visible set never changed. On completion it redraws;
    /// if cells are still missing the next frame re-invokes this, so the fill continues to convergence.
    func scheduleWarmIfNeeded(_ uids: [PhotoUID], pixelSize: Int) {
        guard let thumbnailFeed else { return }
        let unique = uniqueUIDs(uids)
        guard !unique.isEmpty else { lastWarmIDs = []; warmNeedsRepass = false; return }
        if warmInFlight {
            // A pass is running; if demand moved, remember to re-issue once it finishes.
            if unique != lastWarmIDs { warmNeedsRepass = true }
            return
        }
        guard unique != lastWarmIDs || warmNeedsRepass else { return }
        warmNeedsRepass = false
        lastWarmIDs = unique
        warmInFlight = true
        warmGeneration &+= 1
        let generation = warmGeneration
        let requests = unique.map { ThumbnailRequest(uid: $0, pixelSize: pixelSize, cropMode: displayMode.rawValue) }
        warmTask = Task { [weak self, thumbnailFeed] in
            _ = await thumbnailFeed.warmDecoded(requests, priority: .visibleNow, limit: max(1, requests.count))
            await MainActor.run {
                guard let self, self.warmGeneration == generation else { return }
                self.warmInFlight = false
                // Redraw to upload whatever decoded; renderNow re-invokes this for any cells still missing.
                self.requestRender()
            }
        }
    }
}
#endif
