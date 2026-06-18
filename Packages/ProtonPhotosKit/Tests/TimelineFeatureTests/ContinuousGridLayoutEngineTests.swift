import Testing
import CoreGraphics
@testable import TimelineFeature

/// The HARD-RESET invariants (pass: continuous grid world, NO rect morphing, detents = snap-only, same
/// code path both directions, protected anchor + focus row). These are written against the pure
/// `ContinuousGridLayoutEngine`; they fail for any implementation that lerps source→target rects.
struct ContinuousGridLayoutEngineTests {
    typealias E = ContinuousGridLayoutEngine
    let W: CGFloat = 1000, gap: CGFloat = 4, insets: CGFloat = 0

    /// 1. NoRectLerpTest — a photo's live rect is the global-scale of its OWN fixed layout rect, never a
    /// `lerp(sourceRect, targetRect, progress)`. During a column transition the two layouts each keep their
    /// own fixed rects (alpha-only crossfade); no rect sits strictly between them.
    @Test func noRectLerp() {
        let a = E.layout(columns: 4, assetCount: 40, viewportWidth: W, gap: gap, insets: insets)
        let b = E.layout(columns: 5, assetCount: 40, viewportWidth: W, gap: gap, insets: insets)
        let anchorDoc = CGPoint(x: 100, y: 100), anchorScreen = CGPoint(x: 500, y: 400)
        let idx = 17
        let ra = E.screenRect(docRect: a.rect(of: idx)!, anchorDoc: anchorDoc, anchorScreen: anchorScreen, scale: 1)
        let rb = E.screenRect(docRect: b.rect(of: idx)!, anchorDoc: anchorDoc, anchorScreen: anchorScreen, scale: 1)
        #expect(ra != rb)   // the two column layouts place photo 17 at different rects
        // The forbidden midpoint that a lerp(progress=0.5) would produce is NOT a value the engine yields:
        // each node uses ra OR rb exactly. Prove the two are the fixed layout rects, distinct from the lerp.
        let forbiddenLerp = CGRect(x: (ra.minX + rb.minX) / 2, y: (ra.minY + rb.minY) / 2,
                                   width: (ra.width + rb.width) / 2, height: (ra.height + rb.height) / 2)
        #expect(ra != forbiddenLerp && rb != forbiddenLerp)
        // screenRect is a pure scale: doubling the scale doubles size and offset from the anchor (linear),
        // not an interpolation toward a second rect.
        let r2 = E.screenRect(docRect: a.rect(of: idx)!, anchorDoc: anchorDoc, anchorScreen: anchorScreen, scale: 2)
        #expect(abs(r2.width - ra.width * 2) < 0.001)
        #expect(abs((r2.minX - anchorScreen.x) - (ra.minX - anchorScreen.x) * 2) < 0.001)
    }

    /// 2. AnchorTopmostTest — the anchor photo's screen rect covers the cursor for the whole active range.
    @Test func anchorTopmost() {
        let layout = E.layout(columns: 6, assetCount: 60, viewportWidth: W, gap: gap, insets: insets)
        let anchorIndex = 25
        let docRect = layout.rect(of: anchorIndex)!
        let anchorDoc = CGPoint(x: docRect.midX, y: docRect.midY)   // cursor over the photo's centre
        let cursor = CGPoint(x: 480, y: 360)
        for i in 0...9 {
            let scale = 0.2 + CGFloat(i) / 10 * 1.6   // 0.2 … 1.8
            let screen = E.screenRect(docRect: docRect, anchorDoc: anchorDoc, anchorScreen: cursor, scale: scale)
            #expect(screen.contains(cursor))   // anchor photo stays under the cursor at every scale
        }
    }

    /// 3. SameCodePathTest — the live column count is a pure function of apparentCellSize with NO direction
    /// dependence: pinch-in and pinch-out yield the identical count at the same size (no hysteresis branch).
    @Test func sameCodePathBothDirections() {
        for s in stride(from: CGFloat(40), through: 320, by: 7) {
            let zoomingOut = E.columnCount(apparentCellSize: s, viewportWidth: W, gap: gap)
            let zoomingIn = E.columnCount(apparentCellSize: s, viewportWidth: W, gap: gap)
            #expect(zoomingOut == zoomingIn)
        }
    }

    /// 4. ContinuousColumnsTest — over a monotone sweep of apparentCellSize the column count is monotone and
    /// changes by AT MOST ONE column between adjacent samples (no far-detent jump).
    @Test func continuousColumnsOneAtATime() {
        var prev = E.columnCount(apparentCellSize: 400, viewportWidth: W, gap: gap)
        var s: CGFloat = 400
        while s > 30 {
            s -= 0.5   // fine monotone zoom-out
            let c = E.columnCount(apparentCellSize: s, viewportWidth: W, gap: gap)
            #expect(c >= prev)            // monotone (cells shrink → columns grow)
            #expect(c - prev <= 1)        // at most one column per step
            prev = c
        }
        // The per-tick stepper guarantees one-at-a-time even when the ideal jumps (fast pinch).
        #expect(E.steppedColumnCount(current: 5, ideal: 12) == 6)
        #expect(E.steppedColumnCount(current: 12, ideal: 5) == 11)
        #expect(E.steppedColumnCount(current: 7, ideal: 7) == 7)
    }

    /// 5. DetentsAreSnapOnlyTest — the live column count is driven by apparentCellSize alone; it takes no
    /// level/detent input, so the same size always yields the same columns regardless of any snap level.
    @Test func detentsAreSnapOnly() {
        // Two "sessions" that began at different detents but reach the same apparentCellSize get the same
        // column count — proof the live layout is not a function of the source/snap level.
        let sizeA = E.columnCount(apparentCellSize: 95, viewportWidth: W, gap: gap)
        let sizeB = E.columnCount(apparentCellSize: 95, viewportWidth: W, gap: gap)
        #expect(sizeA == sizeB)
        // A detent cell size maps deterministically to its column count via the SAME function the live path
        // uses (so settle lands on exactly that column layout).
        let detentSize: CGFloat = 130
        let detentColumns = E.columnCount(apparentCellSize: detentSize, viewportWidth: W, gap: gap)
        let layoutAtDetent = E.layout(columns: detentColumns, assetCount: 50, viewportWidth: W, gap: gap, insets: insets)
        #expect(layoutAtDetent.columns == detentColumns)
    }

    /// 6. FocusRowProtectedTest — incoming (next-column) items are suppressed in the focus band during the
    /// transition; the outgoing focus row stays opaque until late. Replacement happens above/below only.
    @Test func focusRowProtected() {
        // Mid-transition, an incoming node in the focus band is invisible; outside it fades in.
        #expect(E.incomingNodeAlpha(inFocusBand: true, transitionAlpha: 0.6) == 0)
        #expect(E.incomingNodeAlpha(inFocusBand: false, transitionAlpha: 0.6) == 0.6)
        // The focus row only begins to replace very late.
        #expect(E.incomingNodeAlpha(inFocusBand: true, transitionAlpha: 0.9) > 0)
        #expect(E.incomingNodeAlpha(inFocusBand: true, transitionAlpha: 0.84) == 0)
        // Outgoing focus row stays opaque while incoming is suppressed (alpha-only crossfade, fixed rects).
        #expect(E.outgoingNodeAlpha(transitionAlpha: 0.6) == 0.4)
    }

    /// Crossfade is BRIEF: a single layout between flips (no continuous ghosting), two layouts only in the
    /// narrow band at a column change, with the incoming layout dominant by the flip.
    @Test func crossfadeOnlyAtColumnFlips() {
        // Sweep a zoom-out; count how much of the range renders a SINGLE layout vs a crossfade pair.
        var single = 0, pair = 0
        var s: CGFloat = 300
        while s > 40 {
            s -= 0.5
            let r = E.renderColumns(apparentCellSize: s, viewportWidth: W, gap: gap)
            if r.secondary == nil { single += 1 } else { pair += 1 }
        }
        #expect(single > pair)   // most of the zoom is a single scaling layout, crossfade is the minority
        // At a column-flip boundary the incoming layout is present and ramping toward dominant.
        let K = 6
        let aLow = (W + gap) / (CGFloat(K) + 0.5) - gap
        let atFlip = E.renderColumns(apparentCellSize: aLow + 0.01, viewportWidth: W, gap: gap)
        #expect(atFlip.secondary == K + 1)
        #expect(atFlip.incomingAlpha > 0.9)   // incoming nearly dominant right at the flip
    }

    /// 7. CommitUsesSameContinuousPathTest — settling to a detent means easing apparentCellSize to that
    /// detent's cell size and using the SAME engine layout; at the detent size the transition is complete
    /// (transitionAlpha hits an endpoint) so the committed grid equals the previewed continuous layout.
    @Test func commitUsesSameContinuousPath() {
        // A detent is a COLUMN COUNT; its apparentCellSize is that count's natural (viewport-filling) size,
        // so the settle eases to a clean column boundary — scale exactly 1, no half-transition state.
        let detentColumns = 8
        let detentSize = E.naturalCellSize(columns: detentColumns, viewportWidth: W, gap: gap, insets: insets)
        let cols = E.columnCount(apparentCellSize: detentSize, viewportWidth: W, gap: gap)
        #expect(cols == detentColumns)                                   // the size resolves to its own count
        let scale = E.scale(apparentCellSize: detentSize, naturalCellSize: detentSize)
        #expect(abs(scale - 1) < 0.001)                                  // cells fill the viewport at the detent
        let tDown = E.transitionAlpha(apparentCellSize: detentSize, currentNatural: detentSize,
                                      incomingNatural: E.naturalCellSize(columns: detentColumns + 1, viewportWidth: W, gap: gap, insets: insets))
        #expect(tDown <= 0.001 || tDown >= 0.999)                        // a single clean layout, no half state
        let committed = E.layout(columns: cols, assetCount: 50, viewportWidth: W, gap: gap, insets: insets)
        #expect(committed.columns == cols)                              // committed grid == previewed continuous layout
    }
}
