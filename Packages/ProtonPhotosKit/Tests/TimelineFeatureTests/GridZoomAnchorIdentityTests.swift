import Testing
import Foundation
import CoreGraphics
@testable import TimelineFeature

/// THE acceptance metric: `hitTest(cursorViewportPoint)` must return the SAME item before the gesture, in the
/// transaction, and after commit + first settled frame. For a trackpad pinch the anchor is the item under the
/// CURSOR; for toolbar/keyboard +/- it is the item at the GRID VIEWPORT CENTRE. The root cause fixed here:
/// `beginZoomTransaction` now resolves the anchor WITH the committed column phase (the displayed grid), so it no
/// longer reads a different item from the canonical layout (the 24→18 swap on the 2nd+ gesture).
@Suite struct GridZoomAnchorIdentityTests {
    private let viewport = CGSize(width: 900, height: 700)
    private let width: CGFloat = 900
    private let count = 4000

    private func engine() -> SquareTileGridEngine { SquareTileGridEngine(sectionCounts: [count]) }

    private func itemUnderCursor(_ e: SquareTileGridEngine, vp: CGPoint, level: Int, phase: Int?, scrollY: CGFloat) -> Int? {
        e.hitTest(contentPoint: CGPoint(x: vp.x, y: vp.y + scrollY), level: level, width: width, columnPhase: phase)?.index
    }

    /// Simulate the host/coordinator pinch flow exactly: begin (anchor resolved WITH the committed phase),
    /// commit (cursor-aligned phase + anchor-rebased scrollY), settled hitTest at the same cursor point.
    private func simulatePinch(sourceLevel: Int, sourcePhase: Int?, targetLevel: Int, cursorVP: CGPoint, sourceScrollY: CGFloat)
        -> (displayed: Int, txAnchor: Int, after: Int?, phase: Int, scrollY: CGFloat, tx: GridZoomTransaction, e: SquareTileGridEngine) {
        let e = engine()
        let cursorContent = CGPoint(x: cursorVP.x, y: cursorVP.y + sourceScrollY)
        let displayed = itemUnderCursor(e, vp: cursorVP, level: sourceLevel, phase: sourcePhase, scrollY: sourceScrollY)!
        let tx = e.beginZoomTransaction(cursorContentPoint: cursorContent, viewportPoint: cursorVP,
                                        level: sourceLevel, width: width, columnPhase: sourcePhase)!
        let desiredCol = e.cursorColumn(viewportX: cursorVP.x, level: targetLevel, width: width)
        let phase = e.columnPhase(forItem: tx.anchorGlobalIndex, targetColumn: desiredCol, level: targetLevel, width: width)
        let scrollY = e.anchoredScrollOffset(flatIndex: tx.anchorGlobalIndex, localFraction: tx.anchorLocalFraction,
                                             viewportPoint: cursorVP, level: targetLevel, width: width, columnPhase: phase).y
        let after = itemUnderCursor(e, vp: cursorVP, level: targetLevel, phase: phase, scrollY: scrollY)
        return (displayed, tx.anchorGlobalIndex, after, phase, scrollY, tx, e)
    }

    private func hostSource() -> String {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent(); url.deleteLastPathComponent(); url.deleteLastPathComponent()
        return (try? String(contentsOf: url.appendingPathComponent("Sources/TimelineFeature/MetalGridScrollHost.swift"), encoding: .utf8)) ?? ""
    }

    private let cursorVP = CGPoint(x: 430, y: 360)
    private let scenarios: [Int?] = [.none, .some(1), .some(3), .some(5)]   // canonical + several committed phases

    // MARK: 1 — CursorAnchorIdentitySurvivesCommitTest
    @Test func cursorAnchorIdentitySurvivesCommit() {
        for sourcePhase in scenarios {
            for (s, t) in [(2, 4), (3, 1), (4, 5), (1, 5)] {
                let r = simulatePinch(sourceLevel: s, sourcePhase: sourcePhase, targetLevel: t, cursorVP: cursorVP, sourceScrollY: 5000)
                #expect(r.txAnchor == r.displayed, "begin anchored \(r.txAnchor) ≠ displayed \(r.displayed) (phase \(String(describing: sourcePhase)))")
                #expect(r.after == r.displayed, "after commit \(String(describing: r.after)) ≠ displayed \(r.displayed) (s\(s)→t\(t), phase \(String(describing: sourcePhase)))")
            }
        }
    }

    // MARK: 2 — LiveZoomKeepsAnchorUnderCursorTest
    @Test func liveZoomKeepsAnchorUnderCursor() {
        let r = simulatePinch(sourceLevel: 3, sourcePhase: 3, targetLevel: 5, cursorVP: cursorVP, sourceScrollY: 5000)
        for lp in stride(from: CGFloat(3), through: 5, by: 0.25) {
            let frame = r.tx.frame(continuousLevel: lp, viewportSize: viewport, overscan: 0)
            let anchorSlot = frame.visibleSlots.first { $0.index == r.txAnchor }!
            #expect(anchorSlot.rect.insetBy(dx: -0.5, dy: -0.5).contains(cursorVP),
                    "live: cursor not inside the anchor cell at levelPosition \(lp)")
        }
    }

    // MARK: 3 — CommitBridgeKeepsAnchorUnderCursorTest
    @Test func commitBridgeKeepsAnchorUnderCursor() {
        let r = simulatePinch(sourceLevel: 3, sourcePhase: 3, targetLevel: 5, cursorVP: cursorVP, sourceScrollY: 5000)
        let pitch = r.e.resolvedMetrics(level: 5, width: width).pitch
        for prog in stride(from: CGFloat(0), through: 1, by: 0.1) {
            let slots = GridZoomCommitBridge.frame(transaction: r.tx, engine: r.e, targetLevel: 5, viewportSize: viewport,
                                                   scrollY: r.scrollY, overscan: 0, progress: prog, columnPhase: r.phase)
            let anchor = slots.first { $0.index == r.txAnchor }!
            #expect(abs(anchor.rect.midX - cursorVP.x) < pitch, "bridge: anchor left the cursor cell at progress \(prog)")
        }
    }

    // MARK: 4 — FirstSettledFrameKeepsAnchorUnderCursorTest
    @Test func firstSettledFrameKeepsAnchorUnderCursor() {
        let r = simulatePinch(sourceLevel: 2, sourcePhase: 3, targetLevel: 4, cursorVP: cursorVP, sourceScrollY: 5000)
        let plan = r.e.framePlan(level: 4, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: r.scrollY), overscan: 0, columnPhase: r.phase)
        let underCursor = plan.visibleSlots.first { $0.viewportRect.contains(cursorVP) }?.index
        #expect(underCursor == r.txAnchor, "first settled frame: \(String(describing: underCursor)) ≠ anchor \(r.txAnchor)")
    }

    // MARK: 5 — ScrollLockDoesNotUndoCommitScrollTest
    @Test func scrollLockDoesNotUndoCommitScroll() {
        // The committed scrollY differs from the pre-zoom origin (so the lock MUST use the new value, not restore the old).
        let r = simulatePinch(sourceLevel: 2, sourcePhase: nil, targetLevel: 5, cursorVP: cursorVP, sourceScrollY: 5000)
        #expect(abs(r.scrollY - 5000) > 1, "the commit computed a new anchor-preserving scrollY")
        // The host sets the scroll lock to the committed target BEFORE scrolling (so the grace can't restore the old origin).
        let host = hostSource()
        #expect(host.contains("scrollLockOrigin = CGPoint(x: 0, y: targetY)"), "scrollLock must be set to the committed targetY")
    }

    // MARK: 6 — CommitUsesSameCursorPointAsBeginTest
    @Test func commitUsesSameCursorPointAsBegin() {
        let r = simulatePinch(sourceLevel: 3, sourcePhase: 3, targetLevel: 5, cursorVP: cursorVP, sourceScrollY: 5000)
        #expect(r.tx.anchorViewportPoint == cursorVP, "the transaction must carry the begin cursor point")
        // The coordinator commit rebases from `tx.anchorViewportPoint` (the begin point), not a fresh/stale point.
        let coord = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TimelineFeature/MetalGridCoordinator.swift"), encoding: .utf8)) ?? ""
        #expect(coord.contains("viewportPoint: tx.anchorViewportPoint, level: lv"), "commit must rebase from the begin cursor point")
    }

    // MARK: 7 — Problematic24To18RegressionTest
    @Test func problematic24To18Regression() {
        // The exact failure shape: a 2nd gesture (committed phase ≠ canonical). The item under the cursor before
        // the gesture must equal the item after commit — NOT the item the canonical layout would have resolved.
        let e = engine()
        let cursorContent = CGPoint(x: cursorVP.x, y: cursorVP.y + 5000)
        let displayed = itemUnderCursor(e, vp: cursorVP, level: 2, phase: 3, scrollY: 5000)!
        let canonical = e.anchorItem(nearContentPoint: cursorContent, level: 2, width: width)!.flatIndex   // the OLD bug target
        #expect(displayed != canonical, "scenario must actually have displayed ≠ canonical (the swap source)")
        let r = simulatePinch(sourceLevel: 2, sourcePhase: 3, targetLevel: 4, cursorVP: cursorVP, sourceScrollY: 5000)
        #expect(r.after == displayed, "regression: cursor settled on \(String(describing: r.after)) ≠ displayed \(displayed)")
        #expect(r.after != canonical, "regression: cursor must NOT settle on the canonical (wrong) item \(canonical)")
    }

    // MARK: 8 — Working84CaseStillWorksTest
    @Test func working84CaseStillWorks() {
        // A gesture starting from the canonical phase (e.g. right after bottom-pin reset) keeps working.
        for (s, t) in [(2, 4), (4, 2), (3, 5)] {
            let r = simulatePinch(sourceLevel: s, sourcePhase: nil, targetLevel: t, cursorVP: cursorVP, sourceScrollY: 5000)
            #expect(r.after == r.displayed, "canonical-phase gesture broke: s\(s)→t\(t)")
        }
    }

    // MARK: 9/11/12 — +/- uses VIEWPORT CENTER (not mouse / toolbar button / top / stale hover)
    @Test func plusMinusZoomUsesViewportCenterAnchor() {
        let host = hostSource()
        // setLevel(+/-) anchors at the grid viewport centre.
        #expect(host.contains("anchorContentPoint ?? CGPoint(x: bounds.width / 2, y: origin.y + vh / 2)"),
                "+/- must anchor at the grid viewport centre")
        // It must NOT use a stale mouse/hover content point (that field was removed; the toolbar button location is never read).
        #expect(!host.contains("lastMouseContentPoint"), "+/- must not reuse a stale mouse/hover point")
    }

    // MARK: 10/13 — center item survives +/- commit AND the phase persists
    @Test func plusMinusCenterItemSurvivesCommit() {
        let e = engine()
        let scrollY: CGFloat = 5000
        let center = CGPoint(x: width / 2, y: viewport.height / 2)             // viewport-centre viewport point
        let centerContent = CGPoint(x: center.x, y: center.y + scrollY)
        for sourcePhase in scenarios {
            // The displayed item nearest the viewport centre (anchorItem has a nearest fallback → never nil).
            let a = e.anchorItem(nearContentPoint: centerContent, level: 3, width: width, columnPhase: sourcePhase)!
            let before = a.flatIndex
            let target = 5
            let desiredCol = e.cursorColumn(viewportX: center.x, level: target, width: width)
            let phase = e.columnPhase(forItem: before, targetColumn: desiredCol, level: target, width: width)
            let newScrollY = e.anchoredScrollOffset(flatIndex: before, localFraction: a.localFraction,
                                                    viewportPoint: center, level: target, width: width, columnPhase: phase).y
            // After the +/- zoom, the item nearest the viewport centre is still the SAME item.
            let afterContent = CGPoint(x: center.x, y: center.y + newScrollY)
            let after = e.anchorItem(nearContentPoint: afterContent, level: target, width: width, columnPhase: phase)!.flatIndex
            #expect(after == before, "+/- centre item changed: \(after) ≠ \(before) (phase \(String(describing: sourcePhase)))")
            // The committed phase persists: a later scroll keeps the same column mapping (no snap-back to canonical).
            let cols = e.resolvedMetrics(level: target, width: width).columns
            let plan = e.framePlan(level: target, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: newScrollY + 1234), overscan: 0, columnPhase: phase)
            for s in plan.visibleSlots { #expect(s.column == ((phase + s.index) % cols + cols) % cols, "phase did not persist on scroll") }
        }
    }

    // MARK: 15 — DiagnosticsEmitWithoutTrap (regression: postCommit had a duplicate `phase` key → runtime trap)
    @MainActor @Test func diagnosticsEmitWithoutDuplicateKeys() {
        let p = CGPoint(x: 430, y: 360)
        GridZoomAnchorLog.begin(trigger: .pinch, cursorViewportPoint: p, cursorContentPoint: p,
                                hoveredIndexAtBegin: 5, transactionAnchorIndex: 5, level: 2)
        GridZoomAnchorLog.live(levelPosition: 3.5, cursorViewportPoint: p, indexUnderCursor: 5,
                               transactionAnchorIndex: 5, focusRow: [4, 5, 6])
        GridZoomAnchorLog.release(targetLevel: 4, cursorViewportPoint: p, indexUnderCursorBeforeCommit: 5,
                                  transactionAnchorIndex: 5, committedPhase: 3, targetScrollY: 100, bridgeWillRun: true)
        GridZoomAnchorLog.postCommit(cursorViewportPoint: p, indexUnderCursorAfterCommit: 5,
                                     transactionAnchorIndex: 5, scrollY: 100, phase: 3)
        GridZoomAnchorLog.postCommit(cursorViewportPoint: p, indexUnderCursorAfterCommit: nil,
                                     transactionAnchorIndex: 5, scrollY: 100, phase: nil)
        #expect(Bool(true))   // reaching here ⇒ no dictionary-literal duplicate-key trap on any emit path
    }

    // MARK: 14 — TriggerAnchorModeDiagnosticTest
    @Test func triggerAnchorModeDiagnostic() {
        #expect(GridZoomTrigger.pinch.anchorMode == .cursor)
        #expect(GridZoomTrigger.toolbarPlus.anchorMode == .viewportCenter)
        #expect(GridZoomTrigger.toolbarMinus.anchorMode == .viewportCenter)
        #expect(GridZoomTrigger.keyboardPlus.anchorMode == .viewportCenter)
        #expect(GridZoomTrigger.keyboardMinus.anchorMode == .viewportCenter)
        #expect(GridZoomTrigger.pinch.isPlusMinus == false)
        #expect(GridZoomTrigger.keyboardMinus.isPlusMinus == true)
    }
}
