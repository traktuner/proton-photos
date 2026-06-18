import Testing
import CoreGraphics
@testable import GridZoomV3

/// The 12 prototype invariants from the GridZoomV3 spec (Phase 8). All target the PURE model
/// (ContinuousPhotoWallLayoutEngine + WallZoomDirector + WallZoomSession) — no window required. The
/// AppKit renderer is a thin driver around exactly this code, so a green suite is a real proof of the
/// model, and the on-screen behaviour is the same computation.
struct GridZoomV3EngineTests {
    typealias Engine = ContinuousPhotoWallLayoutEngine
    typealias Director = WallZoomDirector
    let W: CGFloat = 1000, H: CGFloat = 700, inset: CGFloat = 12

    func uids(_ n: Int) -> [String] { (0..<n).map { String(format: "T%05d", $0) } }
    func aspectMap(_ u: [String]) -> [String: CGFloat] {
        let set: [CGFloat] = [1.0, 1.5, 0.6667, 0.75, 1.3333, 1.0, 0.8]
        var a: [String: CGFloat] = [:]
        for (i, uid) in u.enumerated() { a[uid] = set[i % set.count] }
        return a
    }
    func makeSession(initialDetent: Int = 2, tiles: Int = 2000) -> WallZoomSession {
        let u = uids(tiles)
        return WallZoomSession(orderedUIDs: u, aspectByUID: aspectMap(u),
                               viewportSize: CGSize(width: W, height: H),
                               contentInset: inset, topInset: inset, initialDetent: initialDetent)
    }

    /// Begin a pinch and drive it past the K→K+1 flip so a single rebase (7→8) is in flight. We lower
    /// `apparent` until the natural column count is 8 (the live gap shrinks with the cell, so the exact
    /// flip size isn't a fixed offset from `down`), then advance once to start the rebase.
    func makeRebasingSession() -> (WallZoomSession, cursor: CGPoint) {
        var s = makeSession(initialDetent: 2)   // 7 columns
        let cursor = CGPoint(x: 500, y: 350)
        s.beginPinch(atCursor: cursor, now: 0)
        var a = s.apparentCellSize
        while Engine.columnCount(apparentCellSize: a, viewportWidth: W, gap: Director.liveGap(apparentCellSize: a), contentInset: inset) < 8 {
            a -= 1
        }
        s.setApparent(a, now: 0)
        _ = s.advance(now: 0)
        return (s, cursor)
    }

    // 1 ───────────────────────────────────────────────────────────────────── SamePathInOutTest
    @Test func samePathInOut() {
        // The live column count is a PURE function of apparentCellSize — identical sweeping up or down
        // (no hysteresis, no direction term). Pinch-in and pinch-out share this one computation.
        var up: [Int: Int] = [:]
        var a = 30
        while a <= 360 {
            up[a] = Engine.columnCount(apparentCellSize: CGFloat(a), viewportWidth: W, gap: Director.liveGap(apparentCellSize: CGFloat(a)), contentInset: inset)
            a += 1
        }
        a = 360
        while a >= 30 {
            let down = Engine.columnCount(apparentCellSize: CGFloat(a), viewportWidth: W, gap: Director.liveGap(apparentCellSize: CGFloat(a)), contentInset: inset)
            #expect(down == up[a])
            a -= 1
        }
        // planTick has no direction parameter: same args ⇒ same plan, whichever way the size was reached.
        let live = Director.Topology(columns: 7, cropSquare: false)
        let mid = Director.detentApparent(Director.defaultDetents[2], viewportWidth: W, contentInset: inset)
        let p1 = Director.planTick(apparent: mid, viewportWidth: W, contentInset: inset, live: live,
                                   liveGap: Director.liveGap(apparentCellSize: mid), idealColumns: 7, idealCropSquare: false,
                                   jitterEpsilon: 1.5, cropThreshold: 80, active: nil, now: 1, duration: 0.22)
        let p2 = Director.planTick(apparent: mid, viewportWidth: W, contentInset: inset, live: live,
                                   liveGap: Director.liveGap(apparentCellSize: mid), idealColumns: 7, idealCropSquare: false,
                                   jitterEpsilon: 1.5, cropThreshold: 80, active: nil, now: 1, duration: 0.22)
        #expect(p1 == p2)
    }

    // 2 ──────────────────────────────────────────────────────────── DetentsAreReleaseOnlyTest
    @Test func detentsAreReleaseOnly() {
        // The live geometry takes NO detent/snap input — only apparentCellSize. Two sessions begun at
        // DIFFERENT detents but driven to the SAME apparent converge to the SAME live topology.
        var a = makeSession(initialDetent: 0)   // 3 columns
        var b = makeSession(initialDetent: 5)   // 26 columns
        let target = Director.detentApparent(Director.defaultDetents[2], viewportWidth: W, contentInset: inset) // 7-col size
        a.beginPinch(atCursor: CGPoint(x: 500, y: 350), now: 0)
        b.beginPinch(atCursor: CGPoint(x: 500, y: 350), now: 0)
        a.setApparent(target, now: 0); b.setApparent(target, now: 0)
        var now = 0.0
        for _ in 0..<400 { now += 0.05; _ = a.advance(now: now); _ = b.advance(now: now) }
        #expect(a.liveTopology == b.liveTopology)
        #expect(a.liveTopology.columns == Engine.columnCount(apparentCellSize: target, viewportWidth: W, gap: Director.liveGap(apparentCellSize: target), contentInset: inset))
        // The engine layout is a pure function of apparent (and forced columns) — no detent argument exists.
        let la = Engine.layout(.init(orderedUIDs: uids(50), viewportWidth: W, apparentCellSize: target, gap: Director.liveGap(apparentCellSize: target), cropMode: .aspectFit, contentInset: inset))
        #expect(la.columnCount == 7)
    }

    // 3 ───────────────────────────────────────────────────────────────────── AnchorTopmostTest
    @Test func anchorTopmost() {
        // Across an entire pinch (many rebases), the topmost RENDERED node under the cursor stays the
        // anchor UID — checked against the rendered nodes, not just layout math.
        var s = makeSession(initialDetent: 2)
        let cursor = CGPoint(x: 520, y: 330)
        s.beginPinch(atCursor: cursor, now: 0)
        let anchorUID = s.orderedUIDs[s.anchor!.index]
        var now = 0.0
        // zoom out (cells shrink) then back in, finely.
        for a in stride(from: s.apparentCellSize, through: 50, by: -3) { now += 0.02; s.setApparent(a, now: now); _ = s.advance(now: now)
            let f = s.renderFrame(now: now); #expect(f.topMostUID(at: f.anchorScreenPoint) == anchorUID) }
        for a in stride(from: CGFloat(50), through: 300, by: 3) { now += 0.02; s.setApparent(a, now: now); _ = s.advance(now: now)
            let f = s.renderFrame(now: now); #expect(f.topMostUID(at: f.anchorScreenPoint) == anchorUID) }
    }

    // 4 ──────────────────────────────────────────────────────────────────── FocusRowStableTest
    @Test func focusRowStable() {
        let (s, _) = makeRebasingSession()
        let f = s.renderFrame(now: 0.10)   // mid rebase, progress < focusHoldUntil
        #expect(f.isRebasing)
        // The OUTGOING focus row is the protected pivot: fully opaque.
        let fromFocus = f.nodes.filter { $0.layer == .from && $0.isFocusRow }
        #expect(!fromFocus.isEmpty)
        #expect(fromFocus.allSatisfy { abs($0.alpha - 1) < 1e-6 })
        // No INCOMING node may be visible inside the focus band yet (focus row never replaced early).
        let half = Director.focusBandHalfHeight(viewportHeight: H)
        let incomingInBand = f.nodes.filter { $0.layer == .to && abs($0.cellScreenRect.midY - f.anchorScreenPoint.y) <= half && $0.alpha > 0.05 }
        #expect(incomingInBand.isEmpty)
        // And the anchor is still topmost.
        #expect(f.topMostUID(at: f.anchorScreenPoint) == f.anchorUID)
    }

    // 5 ───────────────────────────────────────────────────────────────────────── NoRectLerpTest
    @Test func noRectLerp() {
        // A lerp(oldRect,newRect,progress) would MOVE a node's rect as progress advances. Hold apparent
        // fixed and advance the rebase clock: every node that exists at two progress points keeps the
        // EXACT same rect (only alpha changes). No frame travels old→new.
        let (s, _) = makeRebasingSession()
        let f1 = s.renderFrame(now: 0.04)
        let f2 = s.renderFrame(now: 0.12)
        #expect(f1.isRebasing && f2.isRebasing)
        func key(_ n: WallRenderNode) -> String { "\(n.layer)#\(n.uid)" }
        var r1: [String: CGRect] = [:]; for n in f1.nodes { r1[key(n)] = n.cellScreenRect }
        var changedAlpha = false
        var a1: [String: CGFloat] = [:]; for n in f1.nodes { a1[key(n)] = n.alpha }
        for n in f2.nodes {
            if let prev = r1[key(n)] { #expect(rectsEqual(prev, n.cellScreenRect)) }   // no travel
            if let pa = a1[key(n)], abs(pa - n.alpha) > 1e-4 { changedAlpha = true }
        }
        #expect(changedAlpha)   // it IS a dissolve (alpha moved), just not a rect lerp
        // The two topologies are genuinely two fixed layouts, not one blended one: some uid has distinct
        // from/to rects. Sample at mid-progress where BOTH layers have visible nodes.
        let mid = s.renderFrame(now: 0.13)
        var fromR: [String: CGRect] = [:], toR: [String: CGRect] = [:]
        for n in mid.nodes { if n.layer == .from { fromR[n.uid] = n.cellScreenRect } else if n.layer == .to { toR[n.uid] = n.cellScreenRect } }
        let shared = Set(fromR.keys).intersection(toR.keys)
        #expect(!shared.isEmpty)
        #expect(shared.contains { !rectsEqual(fromR[$0]!, toR[$0]!) })
    }

    // 6 ─────────────────────────────────────────────────────────────── ContinuousApparentSizeTest
    @Test func continuousApparentSize() {
        // A small change in apparentCellSize changes the layout continuously (cell side moves by exactly
        // the delta) and LOCALLY (no column change well inside a band).
        let a: CGFloat = 150   // mid-band for this viewport
        let cols0 = Engine.columnCount(apparentCellSize: a, viewportWidth: W, gap: Director.liveGap(apparentCellSize: a), contentInset: inset)
        let cols1 = Engine.columnCount(apparentCellSize: a + 0.5, viewportWidth: W, gap: Director.liveGap(apparentCellSize: a + 0.5), contentInset: inset)
        #expect(cols0 == cols1)
        let l0 = Engine.layout(.init(orderedUIDs: uids(100), viewportWidth: W, apparentCellSize: a, gap: 6, cropMode: .aspectFit, contentInset: inset))
        let l1 = Engine.layout(.init(orderedUIDs: uids(100), viewportWidth: W, apparentCellSize: a + 0.5, gap: 6, cropMode: .aspectFit, contentInset: inset))
        #expect(abs((l1.cellSize - l0.cellSize) - 0.5) < 1e-6)
        // a sample tile moves only slightly for a slight size change (continuity).
        #expect(abs(l1.cellRect(forIndex: 30).minY - l0.cellRect(forIndex: 30).minY) < 5)
    }

    // 7 ──────────────────────────────────────────────────────────────────── ColumnLocalityTest
    @Test func columnLocality() {
        // Sweeping apparentCellSize finely, the column count never jumps more than one — it changes only
        // by local threshold crossings, never a far-detent jump.
        var prev = Engine.columnCount(apparentCellSize: 40, viewportWidth: W, gap: Director.liveGap(apparentCellSize: 40), contentInset: inset)
        var a: CGFloat = 40
        while a <= 360 {
            let c = Engine.columnCount(apparentCellSize: a, viewportWidth: W, gap: Director.liveGap(apparentCellSize: a), contentInset: inset)
            #expect(abs(c - prev) <= 1)
            prev = c; a += 0.25
        }
        // The rebase state machine also steps columns by at most one.
        #expect(Director.steppedColumns(current: 7, ideal: 20) == 8)
        #expect(Director.steppedColumns(current: 20, ideal: 7) == 19)
    }

    // 8 ──────────────────────────────────────────────────────────── TopologyRebaseAlphaOnlyTest
    @Test func topologyRebaseAlphaOnly() {
        // At a topology boundary: the old tiles stay at their old rects while fading OUT, the new tiles
        // stay at their new rects while fading IN, neither travels. (Rect stability is proven in
        // noRectLerp; here we prove the alpha-only crossfade direction.)
        let (s, _) = makeRebasingSession()
        let early = s.renderFrame(now: 0.03)   // progress ~0
        let late = s.renderFrame(now: 0.20)    // progress ~1
        let fromEarly = early.nodes.filter { $0.layer == .from }.reduce(0) { $0 + $1.alpha }
        let fromLate = late.nodes.filter { $0.layer == .from }.reduce(0) { $0 + $1.alpha }
        let toEarly = early.nodes.filter { $0.layer == .to }.reduce(0) { $0 + $1.alpha }
        let toLate = late.nodes.filter { $0.layer == .to }.reduce(0) { $0 + $1.alpha }
        #expect(fromLate < fromEarly)   // outgoing fades out
        #expect(toLate > toEarly)       // incoming fades in
        // Every from node belongs to the OLD column count, every to node to the NEW one (two topologies).
        #expect(early.nodes.filter { $0.layer == .from }.allSatisfy { $0.topologyColumns == 7 })
        #expect(early.nodes.filter { $0.layer == .to }.allSatisfy { $0.topologyColumns == 8 })
    }

    // 9 ────────────────────────────────────────────────────────────────────── NoViewportPatchTest
    @Test func noViewportPatch() {
        // There is no captured viewport rectangle. Tiles come purely from the global layout translated by
        // the camera: a tile visible at two scroll offsets has rects differing by EXACTLY the scroll delta.
        var s = makeSession(initialDetent: 1)
        s.setScroll(y: 200)
        let f1 = s.renderFrame(now: 0)
        s.setScroll(y: 320)
        let f2 = s.renderFrame(now: 0)
        let d = f2.cameraOffset.y - f1.cameraOffset.y
        #expect(abs(d - 120) < 1e-6)
        var r1: [String: CGRect] = [:]; for n in f1.nodes { r1[n.uid] = n.cellScreenRect }
        var checked = 0
        for n in f2.nodes {
            if let prev = r1[n.uid] {
                #expect(rectsEqual(prev.offsetBy(dx: 0, dy: -120), n.cellScreenRect))
                checked += 1
            }
        }
        #expect(checked > 0)
    }

    // 10 ───────────────────────────────────────────────────────────── DetentSettleSamePathTest
    @Test func detentSettleSamePath() {
        // Release settle eases apparentCellSize to the detent through the SAME continuous layout path and
        // lands EXACTLY on the detent (its column count fills the width).
        var s = makeSession(initialDetent: 2)
        s.beginPinch(atCursor: CGPoint(x: 500, y: 350), now: 0)
        s.setApparent(95, now: 0)   // between detents
        let target = s.detentApparent(3)   // 10-col detent
        var now = 0.0
        var prevCols = s.renderFrame(now: now).liveTopology.columns
        for i in 0..<60 {
            now += 0.02
            s.stepSettle(toward: target, fraction: 0.12, now: now)
            _ = s.advance(now: now)
            let cols = s.renderFrame(now: now).liveTopology.columns
            #expect(abs(cols - prevCols) <= 1)   // continuous, never a far jump
            prevCols = cols
            _ = i
        }
        #expect(abs(s.apparentCellSize - target) < 0.5)
        #expect(Engine.columnCount(apparentCellSize: target, viewportWidth: W, gap: Director.liveGap(apparentCellSize: target), contentInset: inset) == 10)
    }

    // 11 ──────────────────────────────────────────────────────────────────── CropModeRebaseTest
    @Test func cropModeRebase() {
        // aspectFit ↔ squareFill at the same column count keeps the CELL rects byte-identical (so the
        // transition is a pure alpha crop dissolve, no movement) — only the IMAGE rect inside differs.
        let u = uids(120)
        let a: CGFloat = 60, gap: CGFloat = 2
        let fit = Engine.layout(.init(orderedUIDs: u, aspectByUID: aspectMap(u), viewportWidth: W, apparentCellSize: a, gap: gap, cropMode: .aspectFit, contentInset: inset, columnsOverride: 16))
        let fill = Engine.layout(.init(orderedUIDs: u, aspectByUID: aspectMap(u), viewportWidth: W, apparentCellSize: a, gap: gap, cropMode: .squareFill, contentInset: inset, columnsOverride: 16))
        let rf = fit.rectByUID, rl = fill.rectByUID
        #expect(rf.count == rl.count)
        for (k, v) in rf { #expect(rectsEqual(v, rl[k]!)) }   // cells identical ⇒ nothing moves
        // a non-square tile's IMAGE rect differs (letterboxed vs filled).
        let portrait = u.first { (aspectMap(u)[$0] ?? 1) != 1 }!
        #expect(!rectsEqual(fit.imageRectByUID[portrait]!, fill.imageRectByUID[portrait]!))
        #expect(rectsEqual(fill.imageRectByUID[portrait]!, fill.rectByUID[portrait]!))   // fill == whole cell
    }

    // 12 ───────────────────────────────────────────────────────────────────────── AnchorOriginTest
    @Test func anchorOrigin() {
        // The anchor's local point inside its displayed image stays under the cursor as apparentCellSize
        // changes — the camera pins it exactly.
        var s = makeSession(initialDetent: 2)
        let cursor = CGPoint(x: 540, y: 300)
        s.beginPinch(atCursor: cursor, now: 0)
        let unit = s.anchor!.localUnit
        var now = 0.0
        for a in stride(from: s.apparentCellSize, through: 70, by: -4) {
            now += 0.02; s.setApparent(a, now: now); _ = s.advance(now: now)
            let f = s.renderFrame(now: now)
            guard let anchorNode = f.nodes.first(where: { $0.isAnchor && $0.layer != .to || ($0.isAnchor && f.nodes.allSatisfy { !$0.isAnchor || $0.layer != .from }) }) ?? f.nodes.first(where: { $0.isAnchor }) else {
                Issue.record("no anchor node"); continue
            }
            let rect = anchorNode.imageScreenRect
            let recovered = CGPoint(x: (cursor.x - rect.minX) / rect.width, y: (cursor.y - rect.minY) / rect.height)
            #expect(abs(recovered.x - unit.x) < 0.02)
            #expect(abs(recovered.y - unit.y) < 0.02)
        }
    }

    // MARK: helpers
    func rectsEqual(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 1e-5) -> Bool {
        abs(a.minX - b.minX) < eps && abs(a.minY - b.minY) < eps && abs(a.width - b.width) < eps && abs(a.height - b.height) < eps
    }
}
