import Testing
import Foundation
import CoreGraphics
@testable import TimelineFeature

// Performance guards for the resize/render hot path: resize is redraw-only (no texture reload / sync decode),
// the visible query is bounded to the viewport+overscan, the pipeline is built once, diagnostics are throttled,
// and pure-height resize doesn't recompute width-derived metrics/contentSize.
@Suite struct GridResizePerfTests {
    private func engine(_ count: Int = 20000) -> SquareTileGridEngine { SquareTileGridEngine(sectionCounts: [count]) }
    private func repoRoot() -> URL { var u = URL(fileURLWithPath: #filePath); for _ in 0 ..< 5 { u.deleteLastPathComponent() }; return u }
    private func src(_ name: String) -> String {
        (try? String(contentsOf: repoRoot().appendingPathComponent("Packages/ProtonPhotosKit/Sources/TimelineFeature/\(name)"), encoding: .utf8)) ?? ""
    }

    // 1 — pure-height resize: width-derived metrics + contentSize are unchanged (no recompute needed).
    @Test func pureHeightResizeDoesNotRecomputeWidthMetrics() {
        let e = engine()
        let before = e.resolvedMetrics(level: 2, width: 1000)
        let r = e.rebasedScrollOffsetForViewportChange(GridViewportResizeInput(
            oldViewportFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            newViewportFrame: CGRect(x: 0, y: 200, width: 1000, height: 800),
            oldScrollY: 6000, level: 2, committedPhase: nil, itemCount: 20000,
            wasBottomPinned: false, anchorFractionY: 0.5))
        let after = e.resolvedMetrics(level: 2, width: 1000)
        #expect(before == after, "width-derived metrics must be identical on a pure-height resize")
        #expect(r.newContentSize.height == e.contentSize(level: 2, width: 1000).height, "contentSize unchanged when width unchanged")
        // The coordinator's perf signpost reports metricsRecomputed = widthChanged (→ false for pure height).
        #expect(src("MetalGridCoordinator.swift").contains("metricsRecomputed: delta.widthChanged"))
    }

    // 2 — the resize path requests a redraw only; it must not reload textures / touch the cache.
    @Test func resizeDoesNotTriggerTextureReload() {
        let host = src("MetalGridScrollHost.swift")
        guard let range = host.range(of: "private func rebaseForResize") else { Issue.record("rebaseForResize missing"); return }
        let body = String(host[range.lowerBound ..< (host.index(range.lowerBound, offsetBy: 1100, limitedBy: host.endIndex) ?? host.endIndex)])
        #expect(!body.contains("cache") && !body.contains("streamTextures") && !body.contains("reload") && !body.contains("upload"),
                "resize must not reload textures — redraw only")
        // The coordinator's resize rebase likewise does no texture work (it only reads uploadsThisFrame for the signpost).
        let coord = src("MetalGridCoordinator.swift")
        if let cr = coord.range(of: "func rebaseForViewportChange") {
            let cbody = String(coord[cr.lowerBound ..< (coord.index(cr.lowerBound, offsetBy: 1800, limitedBy: coord.endIndex) ?? coord.endIndex)])
            #expect(!cbody.contains("streamTextures") && !cbody.contains("cache.texture") && !cbody.contains("reload"))
        }
    }

    // 3 — the visible-slot query is bounded to viewport+overscan, NOT the whole library.
    @Test func visibleSlotQueryBoundedToViewportOverscan() {
        let e = engine(20000)
        let plan = e.framePlan(level: 2, viewportSize: CGSize(width: 1000, height: 800), scrollOffset: CGPoint(x: 0, y: 50000), overscan: 200, columnPhase: nil)
        #expect(plan.visibleSlots.count < 600, "visible query must be bounded, got \(plan.visibleSlots.count) of 20000")
        #expect(!plan.visibleSlots.isEmpty)
    }

    // 4 — the render pipeline is created ONCE (in init), never per render/resize frame.
    @Test func rendererDoesNotRecreatePipelineOnResize() {
        let r = src("MetalGridRenderer.swift")
        guard let initRange = r.range(of: "init"), let renderRange = r.range(of: "func render") else { Issue.record("renderer shape"); return }
        let pipelineIdx = r.range(of: "makeRenderPipelineState")
        #expect(pipelineIdx != nil, "pipeline must be created")
        #expect(pipelineIdx!.lowerBound > initRange.lowerBound && pipelineIdx!.lowerBound < renderRange.lowerBound,
                "pipeline must be built in init, before/outside render()")
        let renderBody = String(r[renderRange.lowerBound ..< r.endIndex])
        #expect(!renderBody.contains("makeRenderPipelineState"), "render() must NOT recreate the pipeline")
    }

    // 5 — resize/perf diagnostics are throttled (a live drag fires per frame; DEBUG emit prints synchronously).
    @Test func resizeDiagnosticsThrottled() {
        let coord = src("MetalGridCoordinator.swift")
        #expect(coord.contains("lastResizeDiagTime") && coord.contains("> 0.33"), "GridResize logs must be time-throttled")
        #expect(src("GridZoomCommit.swift").contains("throttleSeconds: 0.5"), "MetalGridPerf signposts must be throttled")
    }

    // 6 — no synchronous decode on the resize path: the rebase is pure geometry; texture work stays in the cache.
    @Test func noSynchronousDecodeOnResizePath() {
        let resizeSrc = src("GridViewportResizeRebase.swift")
        #expect(!resizeSrc.contains("decode") && !resizeSrc.contains("NSImage") && !resizeSrc.contains("CGImage")
                && !resizeSrc.contains("texture"), "the resize rebase must be pure geometry — no decode/texture work")
        // It only depends on CoreGraphics geometry (no AppKit / image APIs).
        #expect(resizeSrc.contains("import CoreGraphics") && !resizeSrc.contains("import AppKit") && !resizeSrc.contains("import MetalKit"))
    }
}
