import Testing
import Foundation
import CoreGraphics
import Metal
import PhotosCore
@testable import TimelineFeature

/// Pure-piece tests for the Phase-1 Metal Grid Lab. They run headlessly (no Metal device, no window) so
/// "build succeeded" is never the only evidence — the layout parity, visible-range query, coordinate
/// transforms, hit testing, LRU policy, placeholder handling, upload dedup/budget, late-arrival
/// stability, and diagnostics counting are all proven in isolation.

private func uid(_ s: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: s) }

private func pureLayout(_ counts: [Int], level: Int, width: CGFloat) -> MetalGridLayout {
    // Mirror JustifiedCollectionLayout's level table without the @MainActor hop (values used here match
    // the production levels; parity vs the real table is proven separately in MetalGridLayoutParityTests).
    let table: [(CGFloat, CGFloat, GridCropMode)] = [
        (330, 12, .aspectFit), (185, 8, .aspectFit), (130, 6, .aspectFit),
        (95, 4, .aspectFit), (70, 1, .squareFill), (44, 1, .squareFill),
    ]
    let cfg = table[min(max(level, 0), table.count - 1)]
    return MetalGridLayout(sectionCounts: counts, level: level, size: cfg.0, gap: cfg.1, cropMode: cfg.2, width: width)
}

// MARK: 1 — Layout parity vs the production JustifiedCollectionLayout

@MainActor
@Suite struct MetalGridLayoutParityTests {
    @Test func metalLayoutMatchesJustifiedLayout() {
        let counts = [1, 7, 23, 100, 5, 64, 2]
        let jl = JustifiedCollectionLayout()
        jl.sectionAspects = counts.map { Array(repeating: CGFloat(1), count: $0) }

        for width in [600, 900, 1440] as [CGFloat] {
            for level in 0 ..< JustifiedCollectionLayout.levels.count {
                let mg = MetalGridLayout.forLevel(level, sectionCounts: counts, width: width)

                // Content size parity.
                let jSize = jl.projectedContentSize(level: level, width: width)
                #expect(abs(mg.contentSize.height - jSize.height) < 0.5)
                #expect(abs(mg.contentSize.width - jSize.width) < 0.5)

                // Per-item frame parity (sample a spread of items in each section).
                for (section, count) in counts.enumerated() {
                    let stepCount = max(1, count / 5)
                    for item in stride(from: 0, to: count, by: stepCount) {
                        let jr = jl.projectedFrameForItem(at: IndexPath(item: item, section: section), level: level, width: width)
                        let mr = mg.frame(section: section, item: item)
                        #expect(jr != nil)
                        #expect(mr != nil)
                        if let jr, let mr {
                            #expect(abs(jr.minX - mr.minX) < 0.5)
                            #expect(abs(jr.minY - mr.minY) < 0.5)
                            #expect(abs(jr.width - mr.width) < 0.5)
                            #expect(abs(jr.height - mr.height) < 0.5)
                        }
                    }
                }
            }
        }
    }
}

// MARK: 2 — Visible range query

@Suite struct MetalGridVisibleRangeTests {
    @Test func visibleRectReturnsExactlyTheIntersectingItems() {
        let layout = pureLayout([200], level: 2, width: 800)   // single section, 200 items
        let rect = CGRect(x: 0, y: 1500, width: 800, height: 600)
        let visible = Set(layout.visibleCells(in: rect).map(\.flatIndex))

        // Ground truth: brute-force every item and check rect intersection.
        var expected = Set<Int>()
        for i in 0 ..< layout.totalItems where layout.frame(flatIndex: i)!.intersects(rect) {
            expected.insert(i)
        }
        #expect(visible == expected)
        #expect(!visible.isEmpty)
        // Every returned cell genuinely intersects.
        for cell in layout.visibleCells(in: rect) { #expect(cell.rect.intersects(rect)) }
    }

    @Test func visibleQueryCostIsBoundedNotWholeLibrary() {
        let layout = pureLayout([50_000], level: 3, width: 1000)   // 20k+ requirement
        let rect = CGRect(x: 0, y: 20_000, width: 1000, height: 800)
        let visible = layout.visibleCells(in: rect)
        // A viewport-sized query must touch only a few rows of items, never the whole 50k library.
        #expect(visible.count < 400)
        #expect(layout.totalItems == 50_000)
    }
}

// MARK: 3 — Coordinate transform

@Suite struct MetalGridCoordinateTransformTests {
    @Test func contentRectConvertsToViewportRect() {
        let content = CGRect(x: 100, y: 5000, width: 130, height: 130)
        let origin = CGPoint(x: 0, y: 4800)
        let vp = MetalGridGeometry.viewportRect(contentRect: content, visibleOrigin: origin)
        #expect(vp == CGRect(x: 100, y: 200, width: 130, height: 130))
    }

    @Test func viewportPointRoundTripsToContent() {
        let origin = CGPoint(x: 0, y: 4800)
        let content = MetalGridGeometry.contentPoint(viewportPoint: CGPoint(x: 50, y: 200), visibleOrigin: origin)
        #expect(content == CGPoint(x: 50, y: 5000))
    }

    @Test func overscanExpandsAndClampsToContent() {
        let mid = MetalGridGeometry.overscanRect(visibleRect: CGRect(x: 0, y: 1000, width: 800, height: 600), overscan: 300, contentHeight: 5000)
        #expect(mid.minY == 700)
        #expect(mid.maxY == 1900)
        let top = MetalGridGeometry.overscanRect(visibleRect: CGRect(x: 0, y: 100, width: 800, height: 600), overscan: 300, contentHeight: 5000)
        #expect(top.minY == 0)            // clamped at the content top
        #expect(top.maxY == 1000)
    }
}

// MARK: 4 — Hit testing

@Suite struct MetalGridHitTestTests {
    @Test func pointInsideItemReturnsIt_gapReturnsNil() {
        let layout = pureLayout([100], level: 0, width: 1000)   // level 0: gap 12 → clear gaps
        let (cols, side) = layout.metrics
        #expect(cols >= 2)
        // Center of the item in (some interior) row 5, col 1.
        let target = layout.visibleCells(in: CGRect(x: 0, y: 0, width: 1000, height: 100_000))
            .first { $0.rect.minY > 1000 && $0.rect.minX > 0 }!
        let center = CGPoint(x: target.rect.midX, y: target.rect.midY)
        #expect(layout.hitTest(center)?.flatIndex == target.flatIndex)

        // A point in the horizontal gap to the right of col 0 (x in (side, side+gap)) → no item.
        let gapPoint = CGPoint(x: side + layout.gap * 0.5, y: target.rect.midY)
        #expect(layout.hitTest(gapPoint) == nil)
    }
}

// MARK: 5 — Texture LRU eviction / pinning

@Suite struct MetalGridTextureLRUTests {
    @Test func pinnedVisibleSurvivesEviction_offscreenEvicts() {
        var lru = MetalGridTextureLRU(capacity: 2, uploadBudgetPerFrame: 10)
        let (a, b, c) = (uid("a"), uid("b"), uid("c"))
        // Make a the OLDEST, then b, then c (one per frame).
        for u in [a, b, c] {
            lru.beginFrame(pinned: [])
            _ = lru.selectUploads(wanted: [u])
            lru.completeUpload(u)
        }
        #expect(lru.residentCount == 3)
        // New frame: a is visible (pinned) but NOT freshly used, so it's the LRU — pinning must save it.
        lru.beginFrame(pinned: [a])
        let evicted = lru.evictToBudget()
        #expect(lru.isResident(a))         // pinned visible survives despite being least-recently-used
        #expect(!lru.isResident(b))        // oldest non-pinned evicted
        #expect(lru.isResident(c))
        #expect(evicted == [b])
        #expect(lru.residentCount == 2)
    }
}

// MARK: 6 — Placeholder always available

@Suite struct MetalGridPlaceholderTests {
    @Test func missingImageDrawsPlaceholderUntilResident() {
        var lru = MetalGridTextureLRU(capacity: 10, uploadBudgetPerFrame: 10)
        let a = uid("a")
        #expect(lru.drawState(a) == .placeholder)   // never a hole — always a placeholder
        lru.beginFrame(pinned: [])
        _ = lru.selectUploads(wanted: [a])
        lru.completeUpload(a)
        #expect(lru.drawState(a) == .real)
    }
}

// MARK: 7 — No duplicate concurrent uploads

@Suite struct MetalGridUploadDedupTests {
    @Test func sameUIDNotUploadedTwiceConcurrently() {
        var lru = MetalGridTextureLRU(capacity: 10, uploadBudgetPerFrame: 10)
        let (a, b, c) = (uid("a"), uid("b"), uid("c"))
        lru.beginFrame(pinned: [])
        #expect(lru.selectUploads(wanted: [a, b]) == [a, b])     // a,b now in flight
        #expect(lru.selectUploads(wanted: [a, b, c]) == [c])     // a,b deduped → only c
        lru.completeUpload(a)
        #expect(lru.selectUploads(wanted: [a, b, c]) == [])      // a resident, b & c in flight → none
    }
}

// MARK: 8 — Per-frame upload budget

@Suite struct MetalGridUploadBudgetTests {
    @Test func perFrameUploadBudgetIsEnforced() {
        var lru = MetalGridTextureLRU(capacity: 100, uploadBudgetPerFrame: 3)
        let wanted = (0 ..< 10).map { uid("\($0)") }
        let chosen = lru.selectUploads(wanted: wanted)
        #expect(chosen.count == 3)                  // capped at the budget
        #expect(chosen == Array(wanted.prefix(3)))  // visible-first priority order preserved
    }
}

// MARK: 9 — Late thumbnail arrival keeps the same rect

@Suite struct MetalGridLateArrivalTests {
    @Test func placeholderToRealKeepsSameRect() {
        let layout = pureLayout([120], level: 2, width: 800)
        let before = layout.frame(section: 0, item: 37)
        var lru = MetalGridTextureLRU(capacity: 50, uploadBudgetPerFrame: 10)
        let a = uid("37")
        #expect(lru.drawState(a) == .placeholder)
        // Thumbnail arrives.
        lru.beginFrame(pinned: [a])
        _ = lru.selectUploads(wanted: [a])
        lru.completeUpload(a)
        #expect(lru.drawState(a) == .real)
        // Geometry is computed by the layout alone — texture arrival must not move the cell.
        let after = layout.frame(section: 0, item: 37)
        #expect(before == after)
    }
}

// MARK: Metal smoke — the renderer's runtime shader actually compiles

@Suite struct MetalGridRendererSmokeTests {
    /// Catches MSL compile failures (e.g. reserved-keyword collisions) that otherwise only surface as the
    /// lab's "Metal unavailable" fallback at runtime. Skipped on hosts with no Metal device.
    @Test func rendererBuildsAndShaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }   // no GPU (CI) → skip
        #expect(MetalGridRenderer(device: device) != nil)
    }
}

// MARK: 10 — Diagnostics counters

@Suite struct MetalGridDiagnosticsTests {
    @Test func statsReflectRealVsPlaceholderCounts() {
        let drawn = [uid("a"), uid("b"), uid("c"), uid("d")]
        let resident: Set<PhotoUID> = [uid("a"), uid("c")]
        let counts = MetalGridStats.counts(visibleCount: 4, overscanCount: 0, drawnUIDs: drawn) { resident.contains($0) }
        #expect(counts.real == 2)
        #expect(counts.placeholder == 2)
    }
}
