import CoreGraphics
import PhotosCore

// MARK: - Zoom anchor mode / trigger

/// Where a zoom is anchored. A trackpad pinch anchors at the CURSOR; toolbar/keyboard +/- anchor at the
/// CENTRE of the MetalGrid viewport (never the toolbar-button mouse point, a stale hover, or the viewport top).
public enum GridZoomAnchorMode: String, Sendable { case cursor, viewportCenter }

public enum GridZoomTrigger: String, Sendable {
    case pinch, toolbarPlus, toolbarMinus, keyboardPlus, keyboardMinus
    public var anchorMode: GridZoomAnchorMode { self == .pinch ? .cursor : .viewportCenter }
    public var isPlusMinus: Bool { self != .pinch }
}

// MARK: - Zoom anchor-identity diagnostics
//
// `[GridZoomAnchor]` traces the item under the gesture anchor at every stage, so a 24→18 swap is impossible to
// miss: `anchorStillUnderCursor=false` flags it directly.
@MainActor
enum GridZoomAnchorLog {
    static func begin(trigger: GridZoomTrigger, cursorViewportPoint: CGPoint, cursorContentPoint: CGPoint,
                      hoveredIndexAtBegin: Int?, transactionAnchorIndex: Int?, level: Int) {
        PhotoDiagnostics.shared.emit("GridZoomAnchor", [
            "phase": "begin", "trigger": trigger.rawValue, "anchorMode": trigger.anchorMode.rawValue,
            "cursorViewportPoint": pt(cursorViewportPoint), "cursorContentPoint": pt(cursorContentPoint),
            "hoveredIndexAtBegin": idx(hoveredIndexAtBegin), "transactionAnchorIndex": idx(transactionAnchorIndex),
            "level": "\(level)",
        ])
    }

    static func live(levelPosition: CGFloat, cursorViewportPoint: CGPoint, indexUnderCursor: Int?,
                     transactionAnchorIndex: Int, focusRow: [Int]) {
        PhotoDiagnostics.shared.emit("GridZoomAnchor", [
            "phase": "live", "levelPosition": String(format: "%.2f", levelPosition),
            "cursorViewportPoint": pt(cursorViewportPoint), "indexUnderCursor": idx(indexUnderCursor),
            "transactionAnchorIndex": "\(transactionAnchorIndex)",
            "anchorStillUnderCursor": "\(indexUnderCursor == transactionAnchorIndex)", "focusRow": "\(focusRow)",
        ])
    }

    static func release(targetLevel: Int, cursorViewportPoint: CGPoint, indexUnderCursorBeforeCommit: Int?,
                        transactionAnchorIndex: Int, committedPhase: Int, targetScrollY: CGFloat, bridgeWillRun: Bool) {
        PhotoDiagnostics.shared.emit("GridZoomAnchor", [
            "phase": "release", "targetLevel": "\(targetLevel)", "cursorViewportPoint": pt(cursorViewportPoint),
            "indexUnderCursorBeforeCommit": idx(indexUnderCursorBeforeCommit),
            "transactionAnchorIndex": "\(transactionAnchorIndex)", "committedPhase": "\(committedPhase)",
            "targetScrollY": "\(Int(targetScrollY))", "bridgeWillRun": "\(bridgeWillRun)",
        ])
    }

    static func postCommit(cursorViewportPoint: CGPoint, indexUnderCursorAfterCommit: Int?,
                           transactionAnchorIndex: Int, scrollY: CGFloat, phase: Int?) {
        PhotoDiagnostics.shared.emit("GridZoomAnchor", [
            "phase": "postCommit", "cursorViewportPoint": pt(cursorViewportPoint),
            "indexUnderCursorAfterCommit": idx(indexUnderCursorAfterCommit),
            "transactionAnchorIndex": "\(transactionAnchorIndex)",
            "anchorStillUnderCursor": "\(indexUnderCursorAfterCommit == transactionAnchorIndex)",
            "scrollY": "\(Int(scrollY))", "committedPhase": phase.map { "\($0)" } ?? "canonical",
        ])
    }

    private static func pt(_ p: CGPoint) -> String { "(\(Int(p.x)),\(Int(p.y)))" }
    private static func idx(_ i: Int?) -> String { i.map { "\($0)" } ?? "nil" }
}

// MARK: - Level-binding sync diagnostics
//
// `[GridLevelSync]` traces the `updateNSView` level reconciliation — logged ONLY for the meaningful outcomes (a
// genuine external re-drive, or a SUPPRESSED stale post-commit echo), so the trace is silent in steady state
// but makes a post-commit binding echo (the suspected commit-jump trigger) impossible to miss. If, after a
// pinch commit, a `suppressStaleEcho` line appears, the stale `@Binding level` echo DID arrive and the guard
// caught it — proving the mechanism live. See `LevelBindingReconciler`.
@MainActor
enum GridLevelSyncLog {
    static func decision(binding: Int, hostLevel: Int, staleEcho: Int?, action: String) {
        PhotoDiagnostics.shared.emit("GridLevelSync", [
            "binding": "\(binding)", "hostLevel": "\(hostLevel)",
            "pendingEcho": staleEcho.map { "\($0)" } ?? "nil", "action": action,
        ])
    }
}

// MARK: - Viewport-resize diagnostics
//
// `[GridResize]` traces the resize/sidebar rebase so a jump is observable: the validation line's
// `visibleOverlap` near `visibleBefore`/`visibleAfter` (and unchanged columns when width is unchanged)
// confirms the SAME logical region stayed visible.
@MainActor
enum GridResizeLog {
    static func begin(reason: String, oldFrame: CGRect, newFrame: CGRect, delta: GridViewportResizeDelta,
                      level: Int, phase: Int?, wasBottomPinned: Bool, result: GridViewportResizeResult,
                      anchorViewportY: CGFloat, oldScrollY: CGFloat, oldContentSize: CGSize) {
        PhotoDiagnostics.shared.emit("GridResize", [
            "phase": "begin", "reason": reason, "oldViewportFrame": rc(oldFrame), "newViewportFrame": rc(newFrame),
            "widthChanged": "\(delta.widthChanged)", "heightChanged": "\(delta.heightChanged)",
            "movedTopEdge": "\(delta.movedTopEdge)", "movedBottomEdge": "\(delta.movedBottomEdge)",
            "movedLeftEdge": "\(delta.movedLeftEdge)", "movedRightEdge": "\(delta.movedRightEdge)",
            "level": "\(level)", "committedPhase": phase.map { "\($0)" } ?? "canonical",
            "wasBottomPinned": "\(wasBottomPinned)", "anchorFractionY": String(format: "%.2f", result.anchorFractionY),
            "anchorGlobalIndex": result.anchorGlobalIndex.map { "\($0)" } ?? "nil",
            "anchorViewportY": "\(Int(anchorViewportY))",
            "anchorLocalFractionY": result.anchorLocalFractionY.map { String(format: "%.3f", $0) } ?? "nil",
            "oldScrollY": "\(Int(oldScrollY))", "oldContentSize": sz(oldContentSize),
        ])
    }
    static func end(result: GridViewportResizeResult, anchorViewportYAfter: CGFloat) {
        PhotoDiagnostics.shared.emit("GridResize", [
            "phase": "end", "newContentSize": sz(result.newContentSize), "newScrollY": "\(Int(result.newScrollY))",
            "anchorViewportYAfter": "\(Int(anchorViewportYAfter))",
            "bottomPinned": "\(result.bottomPinned)", "clamped": "\(result.clamped)",
        ])
    }
    static func validation(visibleBefore: Int, visibleAfter: Int, visibleOverlap: Int, columnsBefore: Int,
                           columnsAfter: Int, slotSideBefore: CGFloat, slotSideAfter: CGFloat, gapBefore: CGFloat, gapAfter: CGFloat) {
        PhotoDiagnostics.shared.emit("GridResize", [
            "phase": "validation", "visibleBefore": "\(visibleBefore)", "visibleAfter": "\(visibleAfter)",
            "visibleOverlap": "\(visibleOverlap)", "nominalColumnsBefore": "\(columnsBefore)", "nominalColumnsAfter": "\(columnsAfter)",
            "slotSideBefore": String(format: "%.1f", slotSideBefore), "slotSideAfter": String(format: "%.1f", slotSideAfter),
            "gapBefore": String(format: "%.1f", gapBefore), "gapAfter": String(format: "%.1f", gapAfter),
        ])
    }
    private static func sz(_ s: CGSize) -> String { "\(Int(s.width))x\(Int(s.height))" }
    private static func rc(_ r: CGRect) -> String { "(\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height)))" }
}

// MARK: - MetalGrid performance signposts
//
// Lightweight, THROTTLED counters for the resize/render hot path so stutter is measurable without spamming
// stdout (a live drag fires per frame; `emit` prints synchronously in DEBUG). Off the critical path by default.
@MainActor
enum MetalGridPerfLog {
    static func resizeFrame(layoutMs: Double, visibleSlotCount: Int, renderQuadCount: Int, textureUploadCount: Int,
                            widthChanged: Bool, heightChanged: Bool, metricsRecomputed: Bool, contentSizeRecomputed: Bool) {
        PhotoDiagnostics.shared.emit("MetalGridPerf", [
            "phase": "resizeFrame", "layoutMs": String(format: "%.2f", layoutMs),
            "visibleSlotCount": "\(visibleSlotCount)", "renderQuadCount": "\(renderQuadCount)",
            "textureUploadCount": "\(textureUploadCount)", "widthChanged": "\(widthChanged)",
            "heightChanged": "\(heightChanged)", "metricsRecomputed": "\(metricsRecomputed)",
            "contentSizeRecomputed": "\(contentSizeRecomputed)",
        ], throttleSeconds: 0.5)
    }
}

// MARK: - Commit seam diagnostics
//
// `[GridZoomCommit]` traces exactly what moves at the live→settled commit, so the seam is observable in the
// logs (begin → per-frame focus-row → release measurement → end).
@MainActor
enum GridZoomCommitLog {
    static func begin(sourceLevel: Int, anchorGlobalIndex: Int, anchorViewportPoint: CGPoint, focusRow: [Int]) {
        PhotoDiagnostics.shared.emit("GridZoomCommit", [
            "phase": "begin", "sourceLevel": "\(sourceLevel)",
            "anchorGlobalIndex": "\(anchorGlobalIndex)",
            "anchorViewportPoint": "(\(Int(anchorViewportPoint.x)),\(Int(anchorViewportPoint.y)))",
            "focusRowIndices": "\(focusRow)",
        ])
    }

    static func frame(progress: CGFloat, anchorViewportRect: CGRect, focusRow: [Int], focusRowStable: Bool) {
        PhotoDiagnostics.shared.emit("GridZoomCommit", [
            "phase": "frame", "progress": String(format: "%.2f", progress),
            "anchorViewportRect": rect(anchorViewportRect),
            "focusRowVisibleIndices": "\(focusRow)", "focusRowStable": "\(focusRowStable)",
        ])
    }

    static func release(anchorGlobalIndex: Int, hoveredGlobalIndex: Int, selectedGlobalIndex: Int?,
                        targetLevel: Int, targetColumns: Int, desiredCursorColumn: Int, computedColumnPhase: Int,
                        delta: GridZoomCommitDelta, anchorDeltaColumns: Int) {
        PhotoDiagnostics.shared.emit("GridZoomCommit", [
            "phase": "release", "anchorGlobalIndex": "\(anchorGlobalIndex)",
            "hoveredGlobalIndex": "\(hoveredGlobalIndex)",
            "selectedGlobalIndex": selectedGlobalIndex.map { "\($0)" } ?? "none",
            "anchorIsHovered": "\(anchorGlobalIndex == hoveredGlobalIndex)",
            "targetLevel": "\(targetLevel)", "targetColumns": "\(targetColumns)",
            "desiredCursorColumn": "\(desiredCursorColumn)", "computedColumnPhase": "\(computedColumnPhase)",
            "transactionAnchorX": "\(Int(delta.transactionAnchorRect.midX))",
            "settledAnchorX": "\(Int(delta.settledAnchorRect.midX))",
            "anchorDeltaX": "\(Int(delta.anchorDelta.width))", "anchorDeltaColumns": "\(anchorDeltaColumns)",
        ])
    }

    static func bridge(maxMatchedIndexMovePx: CGFloat, maxMatchedIndexMoveColumns: Double, largeMoveRejected: Bool) {
        PhotoDiagnostics.shared.emit("GridZoomCommit", [
            "phase": "bridge", "maxMatchedIndexMovePx": "\(Int(maxMatchedIndexMovePx))",
            "maxMatchedIndexMoveColumns": String(format: "%.2f", maxMatchedIndexMoveColumns),
            "largeMoveRejected": "\(largeMoveRejected)",
        ])
    }

    static func end(settledUsesCommittedPhase: Bool) {
        PhotoDiagnostics.shared.emit("GridZoomCommit", [
            "phase": "end", "settledUsesCommittedPhase": "\(settledUsesCommittedPhase)",
        ])
    }

    private static func rect(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height)))"
    }
}

// MARK: - Commit bridge (pure geometry-only release settle)
//
// The release bridge from the `GridZoomTransaction` final frame → the settled `GridFramePlan`. GEOMETRY ONLY:
// every visible item is matched by GLOBAL INDEX (never by screen position) and its viewport rect is eased from
// its transaction-final position to its settled position. No crossfade, no photo/identity replacement, and
// none of the old two-surface overlay machinery. The settled layout + transaction focus-row are untouched.
public enum GridZoomCommitBridge {
    /// Bridge duration in seconds. Bounded to 120–180 ms; 160 ms default.
    public static let duration: CFTimeInterval = 0.16

    /// easeOutCubic — monotonic on [0,1], no overshoot (so no spring / no bounce).
    public static func easedProgress(_ t: CGFloat) -> CGFloat {
        let c = min(max(t, 0), 1)
        return 1 - pow(1 - c, 3)
    }

    /// The bridge is allowed to SMOOTH a residual only up to this — a small sub-cell delta. Above it, the
    /// commit must NOT animate (the phase/anchor model is wrong); the coordinator commits instantly instead.
    public static func tolerance(targetPitch: CGFloat) -> CGFloat { max(24, 0.25 * targetPitch) }

    /// The maximum horizontal CENTRE movement (px) any MATCHED globalIndex would undergo from the transaction-
    /// final frame to the settled (phased) plan. With the cursor-aligned phase this is the uniform sub-cell
    /// origin residual; without a compatible phase it is a multi-column distance (the bug). Drives the gate +
    /// the diagnostics + the tests.
    public static func maxMatchedIndexMoveX(transaction tx: GridZoomTransaction, engine: SquareTileGridEngine,
                                            targetLevel: Int, viewportSize: CGSize, scrollY: CGFloat,
                                            overscan: CGFloat, columnPhase: Int? = nil) -> CGFloat {
        let lv = engine.clampLevel(targetLevel)
        let settled = engine.framePlan(level: lv, viewportSize: viewportSize, scrollOffset: CGPoint(x: 0, y: scrollY), overscan: overscan, columnPhase: columnPhase)
        let fromFrame = tx.frame(continuousLevel: CGFloat(lv), viewportSize: viewportSize, overscan: overscan)
        var fromMid: [Int: CGFloat] = [:]
        for s in fromFrame.visibleSlots { fromMid[s.index] = s.rect.midX }
        var maxMove: CGFloat = 0
        for s in settled.visibleSlots { if let m = fromMid[s.index] { maxMove = max(maxMove, abs(s.viewportRect.midX - m)) } }
        return maxMove
    }

    /// The bridge's render slots at LINEAR progress `t` (0→1). Each visible global index's viewport rect is
    /// lerped (eased) from its transaction-final rect to its settled rect, matched STRICTLY by globalIndex.
    /// Items visible in only one end use the other lattice's analytic position, so an item slides in/out
    /// instead of popping — and each index appears EXACTLY ONCE (no duplicate chaos).
    ///
    /// HARD GUARANTEE: if any matched index would move more than ONE COLUMN (a phase mismatch slipped through),
    /// the bridge does NOT lerp — it snaps straight to the settled frame, so a thumbnail can never be displayed
    /// flying across columns. Pure + headless; the coordinator renders exactly this and the tests assert it.
    public static func frame(transaction tx: GridZoomTransaction, engine: SquareTileGridEngine,
                             targetLevel: Int, viewportSize: CGSize, scrollY: CGFloat,
                             overscan: CGFloat, progress t: CGFloat, columnPhase: Int? = nil) -> [GridRenderSlot] {
        let lv = engine.clampLevel(targetLevel)
        let scrollOffset = CGPoint(x: 0, y: scrollY)
        // Settle toward the PHASED plan (the cursor-aligned committed phase).
        let settled = engine.framePlan(level: lv, viewportSize: viewportSize, scrollOffset: scrollOffset, overscan: overscan, columnPhase: columnPhase)
        let fromFrame = tx.frame(continuousLevel: CGFloat(lv), viewportSize: viewportSize, overscan: overscan)

        var toRect: [Int: CGRect] = [:]
        var rowCol: [Int: (row: Int, col: Int)] = [:]
        for s in settled.visibleSlots { toRect[s.index] = s.viewportRect; rowCol[s.index] = (s.row, s.column) }
        var fromRect: [Int: CGRect] = [:]
        for s in fromFrame.visibleSlots { fromRect[s.index] = s.rect; if rowCol[s.index] == nil { rowCol[s.index] = (s.row, s.column) } }

        // HARD GUARANTEE: never display a matched index flying across a column.
        let pitch = settled.slotSide + settled.gap
        var maxMatchedMove: CGFloat = 0
        for (idx, fr) in fromRect { if let tr = toRect[idx] { maxMatchedMove = max(maxMatchedMove, abs(tr.midX - fr.midX)) } }
        let snapToSettled = maxMatchedMove > pitch        // > one column ⇒ a phase mismatch slipped through
        let p = snapToSettled ? 1 : easedProgress(t)

        let width = viewportSize.width
        var slots: [GridRenderSlot] = []
        for idx in Set(toRect.keys).union(fromRect.keys).sorted() {
            let from = fromRect[idx] ?? tx.rect(forGlobalIndex: idx, continuousLevel: CGFloat(lv), viewportSize: viewportSize)
            let to = toRect[idx] ?? engine.slotRect(flatIndex: idx, level: lv, width: width, columnPhase: columnPhase).map {
                CGRect(x: $0.minX - scrollOffset.x, y: $0.minY - scrollOffset.y, width: $0.width, height: $0.height)
            }
            guard let f = from, let tr = to else { continue }
            let r = CGRect(x: f.minX + (tr.minX - f.minX) * p, y: f.minY + (tr.minY - f.minY) * p,
                           width: f.width + (tr.width - f.width) * p, height: f.height + (tr.height - f.height) * p)
            let rc = rowCol[idx] ?? (0, 0)
            slots.append(GridRenderSlot(index: idx, column: rc.col, row: rc.row, rect: r))
        }
        return slots
    }
}

// MARK: - Commit seam measurement
//
// The live pinch renders a `GridZoomTransaction` frame (anchor pinned at the cursor column → focus-row stable).
// On release the grid commits to a settled `GridFramePlan` (bottom-right anchored). Those two topologies share
// the same metrics at the committed integer level, but differ in COLUMN PHASE: the transaction puts the anchor
// at the cursor's column, the settled grid at its bottom-right-wrapped column. `GridZoomCommitDelta` measures
// exactly how far the anchor + focus band move between the two — so the commit seam is quantified, logged, and
// bounded (not hidden).

/// What moves at the transaction-final → settled-plan commit, with the scroll offset rebased from the anchor.
public struct GridZoomCommitDelta: Equatable, Sendable {
    /// settled anchor viewport origin − transaction anchor viewport origin (≈0 vertical, the phase shift is x).
    public let anchorDelta: CGSize
    public let transactionAnchorRect: CGRect    // viewport
    public let settledAnchorRect: CGRect        // viewport
    /// The scroll Y the commit rebases to (from the anchor item + local fraction at the target metrics).
    public let settledScrollOffsetY: CGFloat
    public let transactionFocusRow: [Int]
    public let settledFocusRow: [Int]
    /// |transactionFocusRow ∩ settledFocusRow| / |transactionFocusRow| (1 if the transaction row is empty).
    public let focusRowOverlap: Double
    /// |visible∩| / |visible∪| over the whole visible index sets (local-neighborhood continuity).
    public let neighborhoodOverlap: Double

    public var anchorDeltaDistance: CGFloat { (anchorDelta.width * anchorDelta.width + anchorDelta.height * anchorDelta.height).squareRoot() }
    /// Horizontal shift in whole columns (rounded) — the dominant component of the phase seam.
    public func anchorColumnShift(pitch: CGFloat) -> Int { pitch > 0 ? Int((anchorDelta.width / pitch).rounded()) : 0 }
}

public extension SquareTileGridEngine {
    /// Measure the commit seam: the transaction's final frame at `targetLevel` vs the settled `GridFramePlan`
    /// after the scroll offset is rebased from the anchor (exactly the commit path's vertical rebase). Pure +
    /// headless — drives the commit diagnostics and the seam tests.
    func commitDelta(transaction tx: GridZoomTransaction, targetLevel: Int, viewportSize: CGSize, columnPhase: Int? = nil) -> GridZoomCommitDelta {
        let width = viewportSize.width
        let lv = clampLevel(targetLevel)
        let txFrame = tx.frame(continuousLevel: CGFloat(lv), viewportSize: viewportSize, overscan: 0)
        // The commit rebases the scroll offset from the anchor item + local fraction (vertical pin), with the
        // committed column phase (so the measured delta reflects the cursor-aligned settled plan).
        let scrollY = anchoredScrollOffset(flatIndex: tx.anchorGlobalIndex, localFraction: tx.anchorLocalFraction,
                                           viewportPoint: tx.anchorViewportPoint, level: lv, width: width, columnPhase: columnPhase).y
        let plan = framePlan(level: lv, viewportSize: viewportSize, scrollOffset: CGPoint(x: 0, y: scrollY), overscan: 0, columnPhase: columnPhase)

        let txAnchorRect = txFrame.visibleSlots.first { $0.index == tx.anchorGlobalIndex }?.rect
            ?? tx.rect(forGlobalIndex: tx.anchorGlobalIndex, continuousLevel: CGFloat(lv), viewportSize: viewportSize)
            ?? .zero
        let settledAnchorRect = plan.visibleSlots.first { $0.index == tx.anchorGlobalIndex }?.viewportRect ?? .zero
        let anchorDelta = CGSize(width: settledAnchorRect.minX - txAnchorRect.minX,
                                 height: settledAnchorRect.minY - txAnchorRect.minY)

        let txFocus = txFrame.focusRow
        let anchorRow = plan.visibleSlots.first { $0.index == tx.anchorGlobalIndex }?.row
        let settledFocus = plan.visibleSlots.filter { $0.row == anchorRow }.map(\.index).sorted()
        let focusInter = Set(txFocus).intersection(settledFocus).count
        let focusRowOverlap = txFocus.isEmpty ? 1 : Double(focusInter) / Double(txFocus.count)

        let txVisible = Set(txFrame.visibleSlots.map(\.index))
        let settledVisible = Set(plan.visibleSlots.map(\.index))
        let union = txVisible.union(settledVisible).count
        let neighborhoodOverlap = union == 0 ? 1 : Double(txVisible.intersection(settledVisible).count) / Double(union)

        return GridZoomCommitDelta(anchorDelta: anchorDelta, transactionAnchorRect: txAnchorRect,
                                   settledAnchorRect: settledAnchorRect, settledScrollOffsetY: scrollY,
                                   transactionFocusRow: txFocus, settledFocusRow: settledFocus,
                                   focusRowOverlap: focusRowOverlap, neighborhoodOverlap: neighborhoodOverlap)
    }
}
