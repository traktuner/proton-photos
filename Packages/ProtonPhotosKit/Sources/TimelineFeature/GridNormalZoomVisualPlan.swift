import CoreGraphics
import Foundation

// MARK: - GridNormalZoomVisualPlan — the FIRST Apple-like visual transition layer (NORMAL levels only)
//
// Scope: the `focusRowRelayout` transitions between the NORMAL photo levels L0↔L1, L1↔L2, L2↔L3.
// NOT the overview transitions (`overviewWarp` L3→L4, `denseOverviewZoom` L4→L5) — those are a future pass
// and this planner deliberately refuses them (see `plan(_:)`).
//
// THE ONE VISUAL RULE (verified against Apple Photos macOS, see the comparison clips):
//   A thumbnail IDENTITY must never visibly FLY from its old slot to a new slot. Apple does NOT translate a
//   tile along a path from oldRect→newRect; it anchor-scales the grid about the focus item and crossfades the
//   reflow at the edges. So this planner NEVER computes `rect = lerp(oldRect, newRect)` for any identity.
//   Every tile's `rect` is taken VERBATIM from one of the engine-produced inputs:
//     • the live `GridZoomTransactionFrame` (the focus band — anchored under the cursor, scales in place), or
//     • the source `GridFramePlan` (a fading-out occupant, at its source rect), or
//     • the target `GridFramePlan` (a fading-in occupant, at its target rect).
//   During a crossfade the SAME globalIndex may appear in two places at once (its source rect fading out AND
//   its target rect fading in) — that is allowed. What is forbidden is one tile sliding between the two.
//
// GEOMETRY OWNERSHIP (frozen MetalGrid contract): this is a PURE consumer. It reads viewport-space rects that
// `SquareTileGridEngine` / `GridZoomTransaction` already produced. It computes NO slotSide / gap / pitch /
// columns / contentSize, does NO hit testing, and never derives an outer rect from media aspect. It never
// calls `TileContentFitter` — content fitting stays downstream in the renderer, so the aspect/square toggle
// CANNOT change a single transition rect, alpha, role, or the focus band (proved by the tests). It is an
// AppKit-free value-type kernel: fully unit-testable without a GPU.

/// The role a tile plays in a `focusRowRelayout` visual transition. The renderer uses only `rect`/`alpha`/
/// `zIndex`; the role is a semantic tag for diagnostics + tests (and for the caller to reason about fades).
public enum GridTransitionVisualTileRole: String, Equatable, Sendable {
    /// In the focus band of BOTH the source and target level (the neighbourhood that survives the zoom).
    /// Held identity-stable at the live transaction rect (anchored under the cursor); alpha 1.
    case focusRowStable
    /// A source-only occupant of a region the target no longer fills — fades out at its SOURCE rect.
    case sourceFadeOut
    /// A target-only occupant of a newly-exposed region — fades in at its TARGET rect.
    case targetFadeIn
    /// The OLD occupant of a region whose occupant changes — fades out at its source rect (paired with a
    /// `replacementTarget` at the same region).
    case replacementSource
    /// The NEW occupant of a region whose occupant changes — fades in at its target rect.
    case replacementTarget
    /// Present in both source and target at the same region with the SAME occupant — drawn once, alpha 1.
    case unchanged
}

/// One tile in the visual transition plan. `rect` is VIEWPORT-space (y-down, origin at the viewport top-left)
/// and ALWAYS the engine's square slot rect — NEVER a content/aspect rect, NEVER a fresh source→target lerp.
public struct GridTransitionVisualTile: Equatable, Sendable {
    /// Global (flat) library-order index — the identity key (→ UID lookup in the coordinator).
    public let globalIndex: Int
    /// Viewport-space square rect, taken verbatim from the transaction / source / target plan.
    public let rect: CGRect
    /// Opacity 0…1 for this progress step.
    public let alpha: CGFloat
    /// Back→front draw order (lower drawn first). Fading-out behind fading-in behind the focus band.
    public let zIndex: Int
    public let role: GridTransitionVisualTileRole
    /// Grid column/row for the matched slot (best-effort, for the synthetic debug path + render slot mapping).
    public let column: Int
    public let row: Int

    public init(globalIndex: Int, rect: CGRect, alpha: CGFloat, zIndex: Int,
                role: GridTransitionVisualTileRole, column: Int, row: Int) {
        self.globalIndex = globalIndex
        self.rect = rect
        self.alpha = alpha
        self.zIndex = zIndex
        self.role = role
        self.column = column
        self.row = row
    }
}

/// What the planner consumes. All rects inside the plans/frame are already viewport-space and engine-produced;
/// the caller is responsible for handing in a source plan and a target plan that share ONE viewport frame
/// (the anchor item at the same viewport point in both — exactly what the cursor-anchored commit guarantees).
public struct GridTransitionVisualInput: Equatable, Sendable {
    /// The settled `GridFramePlan` at the SOURCE level (what is on screen as the gesture begins).
    public let sourcePlan: GridFramePlan
    /// The settled `GridFramePlan` at the TARGET level (the cursor-anchored, phased destination).
    public let targetPlan: GridFramePlan
    /// The live transaction frame at the current eased continuous level — the focus band's source of truth
    /// (anchor pinned under the cursor, focus row scales in place).
    public let transactionFrame: GridZoomTransactionFrame
    /// Which transition this is. The planner ONLY handles `.focusRowRelayout`; anything else yields an empty,
    /// `handled == false` plan so the overview transitions can never accidentally use this normal planner.
    public let transitionKind: GridTransitionKind
    /// The anchor item's global index (the photo held under the cursor / viewport centre).
    public let anchorGlobalIndex: Int
    /// Where the anchor is held in viewport space.
    public let cursorViewportPoint: CGPoint
    /// Transition progress 0→1 (linear; the planner eases it internally with smoothstep).
    public let progress: CGFloat
    /// The aspect/square content mode. Carried for the renderer/diagnostics ONLY — it NEVER affects a tile's
    /// rect, alpha, role, zIndex, the focus band, or the anchor (content fitting is downstream).
    public let contentMode: TileContentDisplayMode

    public init(sourcePlan: GridFramePlan, targetPlan: GridFramePlan,
                transactionFrame: GridZoomTransactionFrame, transitionKind: GridTransitionKind,
                anchorGlobalIndex: Int, cursorViewportPoint: CGPoint, progress: CGFloat,
                contentMode: TileContentDisplayMode) {
        self.sourcePlan = sourcePlan
        self.targetPlan = targetPlan
        self.transactionFrame = transactionFrame
        self.transitionKind = transitionKind
        self.anchorGlobalIndex = anchorGlobalIndex
        self.cursorViewportPoint = cursorViewportPoint
        self.progress = progress
        self.contentMode = contentMode
    }
}

/// Per-frame transition diagnostics — pure data the coordinator forwards to `[GridTransition]` logging. Makes
/// it obvious if an identity is ever being moved as a rect: `flyingIdentityDetected` / `maxIdentityMovementPx`.
public struct GridTransitionDiagnostics: Equatable, Sendable {
    /// False when the planner refused the transition (a non-`focusRowRelayout` kind) → empty tiles.
    public let handled: Bool
    public let kind: GridTransitionKind
    public let sourceLevel: Int
    public let targetLevel: Int
    public let anchorGlobalIndex: Int
    public let progress: CGFloat
    public let easedProgress: CGFloat
    public let focusRowIndices: [Int]
    public let sourceVisibleCount: Int
    public let targetVisibleCount: Int
    public let focusAnchorStable: Bool
    public let targetOnlyCount: Int
    public let sourceOnlyCount: Int
    public let replacementCount: Int
    /// True if ANY single-instance identity tile sits on a rect that is not one of its engine-produced
    /// source/target/transaction rects (i.e. a forbidden lerp slipped in). Always false by construction.
    public let flyingIdentityDetected: Bool
    /// The max distance (px) from any tile's centre to the NEAREST of its source/target/transaction rect
    /// centres. 0 means every tile sits exactly on an engine rect (no lerp). Drives the no-fly assertion.
    public let maxIdentityMovementPx: CGFloat
}

/// The complete transition plan for one progress step: the tiles to draw (with alpha + draw order) + the
/// diagnostics. Pure value type.
public struct GridTransitionVisualPlan: Equatable, Sendable {
    public let tiles: [GridTransitionVisualTile]
    public let diagnostics: GridTransitionDiagnostics

    public init(tiles: [GridTransitionVisualTile], diagnostics: GridTransitionDiagnostics) {
        self.tiles = tiles
        self.diagnostics = diagnostics
    }
}

// MARK: - The planner

public enum GridNormalZoomVisualPlanner {
    // Draw order (back → front). Fading-out occupants behind, fading-in occupants in front, the focus band on
    // top so the anchored neighbourhood always reads crisply.
    private static let zSource = 0       // sourceFadeOut / replacementSource
    private static let zUnchanged = 1
    private static let zTarget = 2       // targetFadeIn / replacementTarget
    private static let zFocus = 3        // focusRowStable + entering/leaving focus neighbours

    /// IoU above which two viewport rects are "the same visual region" (same place).
    private static let sameRegionIoU: CGFloat = 0.5
    /// IoU above which a source/target rect is considered to OVERLAP a region (occupant-change detection).
    private static let overlapIoU: CGFloat = 0.15

    /// Build the visual transition plan for one progress step. PURE: no engine calls, no AppKit, no fitter.
    public static func plan(_ input: GridTransitionVisualInput) -> GridTransitionVisualPlan {
        let sourceLevel = input.sourcePlan.levelID
        let targetLevel = input.targetPlan.levelID

        // Overview transitions are NOT handled here — return an empty, explicitly-unhandled plan so the caller
        // (and the guard tests) can prove the normal planner never drives an overview transition.
        guard input.transitionKind == .focusRowRelayout else {
            let diag = GridTransitionDiagnostics(
                handled: false, kind: input.transitionKind, sourceLevel: sourceLevel, targetLevel: targetLevel,
                anchorGlobalIndex: input.anchorGlobalIndex, progress: input.progress,
                easedProgress: smoothstep(clamp01(input.progress)), focusRowIndices: [],
                sourceVisibleCount: input.sourcePlan.visibleSlots.count,
                targetVisibleCount: input.targetPlan.visibleSlots.count,
                focusAnchorStable: false, targetOnlyCount: 0, sourceOnlyCount: 0, replacementCount: 0,
                flyingIdentityDetected: false, maxIdentityMovementPx: 0)
            return GridTransitionVisualPlan(tiles: [], diagnostics: diag)
        }

        let eased = smoothstep(clamp01(input.progress))

        // Index → viewport rect for every visible slot in each input (full maps, including focus indices).
        var sourceRect: [Int: CGRect] = [:]
        var sourceColRow: [Int: (col: Int, row: Int)] = [:]
        for s in input.sourcePlan.visibleSlots { sourceRect[s.index] = s.viewportRect; sourceColRow[s.index] = (s.column, s.row) }
        var targetRect: [Int: CGRect] = [:]
        var targetColRow: [Int: (col: Int, row: Int)] = [:]
        for s in input.targetPlan.visibleSlots { targetRect[s.index] = s.viewportRect; targetColRow[s.index] = (s.column, s.row) }
        var txRect: [Int: CGRect] = [:]
        var txColRow: [Int: (col: Int, row: Int)] = [:]
        for s in input.transactionFrame.visibleSlots { txRect[s.index] = s.rect; txColRow[s.index] = (s.column, s.row) }

        // The focus band at each end: the row that contains the anchor in each settled plan (the cursor-aligned
        // phase makes the anchor's row the focus row — the same contiguous run the transaction owns). Derived
        // from the plans (never recomputed geometry), so source-of-truth stays the engine output.
        let sourceFocusRow = focusRow(of: input.sourcePlan, anchor: input.anchorGlobalIndex)
        let targetFocusRow = focusRow(of: input.targetPlan, anchor: input.anchorGlobalIndex)
        let focusCore = sourceFocusRow.intersection(targetFocusRow)
        let allFocus = sourceFocusRow.union(targetFocusRow)

        var tiles: [GridTransitionVisualTile] = []
        var targetOnly = 0, sourceOnly = 0, replacements = 0

        // 1) FOCUS BAND — anchored, identity-stable. Rects come from the live transaction frame (so the band
        //    scales smoothly about the cursor), falling back to the target/source rect if the index is not in
        //    the current frame. Core neighbours hold at alpha 1; entering neighbours (zoom-out) fade IN,
        //    leaving neighbours (zoom-in) fade OUT — never replaced early by an unrelated row.
        for idx in allFocus.sorted() {
            guard let rect = txRect[idx] ?? targetRect[idx] ?? sourceRect[idx] else { continue }
            let cr = txColRow[idx] ?? targetColRow[idx] ?? sourceColRow[idx] ?? (0, 0)
            let role: GridTransitionVisualTileRole
            let alpha: CGFloat
            if focusCore.contains(idx) {
                role = .focusRowStable; alpha = 1
            } else if targetFocusRow.contains(idx) {
                role = .targetFadeIn; alpha = eased; targetOnly += 1
            } else {
                role = .sourceFadeOut; alpha = 1 - eased; sourceOnly += 1
            }
            tiles.append(GridTransitionVisualTile(globalIndex: idx, rect: rect, alpha: alpha,
                                                  zIndex: zFocus, role: role, column: cr.col, row: cr.row))
        }

        // Non-focus slots only (the focus band is fully handled above).
        let nonFocusSource = input.sourcePlan.visibleSlots.filter { !allFocus.contains($0.index) }
        let nonFocusTarget = input.targetPlan.visibleSlots.filter { !allFocus.contains($0.index) }

        // 2) TARGET regions. For each target slot, find whether the source already filled this region with the
        //    SAME occupant (→ unchanged), a DIFFERENT occupant (→ replacementTarget), or nothing (→ targetFadeIn).
        var matchedInPlace: Set<Int> = []
        for t in nonFocusTarget {
            let rt = t.viewportRect
            let cr = (t.column, t.row)
            if let rs = sourceRect[t.index], iou(rs, rt) > sameRegionIoU {
                // Same photo, same place: present throughout — draw once, fully opaque, no fade.
                tiles.append(GridTransitionVisualTile(globalIndex: t.index, rect: rt, alpha: 1,
                                                      zIndex: zUnchanged, role: .unchanged, column: cr.0, row: cr.1))
                matchedInPlace.insert(t.index)
            } else if overlapsOtherOccupant(rt, in: nonFocusSource, excludingIndex: t.index) {
                tiles.append(GridTransitionVisualTile(globalIndex: t.index, rect: rt, alpha: eased,
                                                      zIndex: zTarget, role: .replacementTarget, column: cr.0, row: cr.1))
                replacements += 1
            } else {
                tiles.append(GridTransitionVisualTile(globalIndex: t.index, rect: rt, alpha: eased,
                                                      zIndex: zTarget, role: .targetFadeIn, column: cr.0, row: cr.1))
                targetOnly += 1
            }
        }

        // 3) SOURCE regions. Anything not matched-in-place fades out: as a replacementSource if the target
        //    fills its region with a different occupant, else a plain sourceFadeOut (the region is vacated).
        for s in nonFocusSource {
            if matchedInPlace.contains(s.index) { continue }
            let rs = s.viewportRect
            let cr = (s.column, s.row)
            if let rt = targetRect[s.index], iou(rt, rs) > sameRegionIoU { continue }   // matched elsewhere already drawn
            if overlapsOtherOccupant(rs, in: nonFocusTarget, excludingIndex: s.index) {
                tiles.append(GridTransitionVisualTile(globalIndex: s.index, rect: rs, alpha: 1 - eased,
                                                      zIndex: zSource, role: .replacementSource, column: cr.0, row: cr.1))
                replacements += 1
            } else {
                tiles.append(GridTransitionVisualTile(globalIndex: s.index, rect: rs, alpha: 1 - eased,
                                                      zIndex: zSource, role: .sourceFadeOut, column: cr.0, row: cr.1))
                sourceOnly += 1
            }
        }

        // No-fly self-check: every tile must sit on one of its engine-produced rects (source/target/tx),
        // never a fresh lerp. maxIdentityMovementPx is the worst centre distance to the nearest such rect.
        var maxMove: CGFloat = 0
        for tile in tiles {
            let c = center(tile.rect)
            var best = CGFloat.greatestFiniteMagnitude
            for candidate in [sourceRect[tile.globalIndex], targetRect[tile.globalIndex], txRect[tile.globalIndex]] {
                if let r = candidate { best = min(best, distance(c, center(r))) }
            }
            if best != .greatestFiniteMagnitude { maxMove = max(maxMove, best) }
        }

        let anchorTile = tiles.first { $0.globalIndex == input.anchorGlobalIndex && $0.role == .focusRowStable }
        let anchorStable = anchorTile.map { distance(center($0.rect), input.cursorViewportPoint) < max(2, input.transactionFrame.slotSide) } ?? false

        let diag = GridTransitionDiagnostics(
            handled: true, kind: .focusRowRelayout, sourceLevel: sourceLevel, targetLevel: targetLevel,
            anchorGlobalIndex: input.anchorGlobalIndex, progress: input.progress, easedProgress: eased,
            focusRowIndices: input.transactionFrame.focusRow,
            sourceVisibleCount: input.sourcePlan.visibleSlots.count,
            targetVisibleCount: input.targetPlan.visibleSlots.count,
            focusAnchorStable: anchorStable, targetOnlyCount: targetOnly, sourceOnlyCount: sourceOnly,
            replacementCount: replacements, flyingIdentityDetected: maxMove > 0.5, maxIdentityMovementPx: maxMove)

        return GridTransitionVisualPlan(tiles: tiles, diagnostics: diag)
    }

    /// The focus band of a settled plan: the indices sharing the anchor's row (the cursor-aligned focus run).
    /// Empty if the anchor is not visible in the plan.
    private static func focusRow(of plan: GridFramePlan, anchor: Int) -> Set<Int> {
        guard let anchorRow = plan.visibleSlots.first(where: { $0.index == anchor })?.row else { return [] }
        return Set(plan.visibleSlots.filter { $0.row == anchorRow }.map(\.index))
    }

    /// Whether any slot in `slots` (other than `excludingIndex`) overlaps `rect` enough to count as occupying
    /// the same visual region — i.e. the region's occupant differs between source and target (a replacement).
    private static func overlapsOtherOccupant(_ rect: CGRect, in slots: [GridSlot], excludingIndex: Int) -> Bool {
        for s in slots where s.index != excludingIndex {
            if iou(s.viewportRect, rect) > overlapIoU { return true }
        }
        return false
    }
}

// MARK: - Pure geometry helpers (free functions so the planner stays a pure value type)

private func clamp01(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }
private func smoothstep(_ x: CGFloat) -> CGFloat { let t = clamp01(x); return t * t * (3 - 2 * t) }
private func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { let dx = a.x - b.x, dy = a.y - b.y; return (dx * dx + dy * dy).squareRoot() }

/// Intersection-over-union of two rects (0 = disjoint, 1 = identical). Used only to classify which visual
/// region a tile occupies — never to produce geometry.
private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let inter = a.intersection(b)
    guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
    let interArea = inter.width * inter.height
    let union = a.width * a.height + b.width * b.height - interArea
    return union > 0 ? interArea / union : 0
}

// MARK: - Feature flag
//
// Gates the discrete (+/- / keyboard) NORMAL-level crossfade transition in production. Default ON (the
// accepted behaviour for L0–L3 focusRowRelayout). Flip OFF via the `MetalGrid.focusRowTransition`
// UserDefaults key (or `-MetalGrid.focusRowTransition NO` at launch) for an instant revert to the prior
// snap-on-`+/-` behaviour. The continuous trackpad pinch is unaffected either way.

public enum MetalGridFocusRowTransitionFlag {
    public static let userDefaultsKey = "MetalGrid.focusRowTransition"

    /// Default ON: a missing key means enabled.
    public static var isEnabled: Bool {
        guard UserDefaults.standard.object(forKey: userDefaultsKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: userDefaultsKey)
    }
}
