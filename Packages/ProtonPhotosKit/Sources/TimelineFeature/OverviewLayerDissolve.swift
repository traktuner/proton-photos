import CoreGraphics

// MARK: - Overview Layer Dissolve (replaces the rejected V3.10 overview warp)
//
// The overview boundaries (L3↔L4 `.overviewWarp`, L4↔L5 `.denseOverviewZoom`) are a DISSOLVE BETWEEN TWO
// COMPLETE STATIC GRID LAYERS, not a per-cell relocation:
//   • the SOURCE settled grid (its own level, scroll, display mode) and
//   • the TARGET settled grid (the adjacent level, anchored scroll, square display mode)
// are BOTH fully resolved ONCE at gesture start. Rendering blends the two complete rasters by opacity
// (source fades out, target fades in). There is NO `GridTransitionComponentBuilder`, NO relocation lattice,
// NO entry/exit endpoints, NO identity handoff — a source cell and a target cell never need to share identity.
//
// The source keeps its OWN display mode (it must NOT be forced to square just because the target is an overview);
// the target is `squareFillCrop` because the overview levels L4/L5 are square-only.
//
// IMPORTANT — renderer requirement: correctly blending two partially-covered rasters over the shared dark
// background CANNOT be done by the current single-pass premultiplied source-over renderer without a mid-fade
// background-bleed artifact (proof in PHASE_B_OVERVIEW_LAYER_DISSOLVE_REPORT.md). It needs OFFSCREEN
// layer compositing (render each layer to its own texture, then blend the two textures). This type is the
// pure, renderer-independent PLAN + the deterministic guarantees; it does not itself rasterise.

/// Smootherstep easing for the layer crossfade (matches the transition family's curve shape). Pure.
public func overviewDissolveEase(_ q: Double) -> Double {
    let x = min(1, max(0, q))
    return x * x * x * (x * (x * 6 - 15) + 10)
}

/// The EXACT linear cross-dissolve the offscreen composite shader applies per channel: `a·(1−t) + b·t`
/// (`metalGridCompositeFragment`'s `mix(a, b, t)`). Pure mirror — used to prove the mid-fade is a true average
/// with NO `(1−t)²` source under-weighting and NO background term.
public func overviewDissolveMix(_ a: Double, _ b: Double, _ t: Double) -> Double { a * (1 - t) + b * t }

/// What a naive SINGLE-PASS premultiplied source-over dissolve (source then target over a shared bg) would
/// produce in a both-covered region: `b·t + a·(1−t)² + bg·t·(1−t)` — the REJECTED background-bleed formula.
/// Exposed only so tests can assert the offscreen path does NOT behave like this.
public func overviewDissolveSinglePassBleed(_ a: Double, _ b: Double, _ bg: Double, _ t: Double) -> Double {
    b * t + a * (1 - t) * (1 - t) + bg * t * (1 - t)
}

/// The immutable plan for one overview layer dissolve. Both `source` and `target` are SETTLED `GridFramePlan`s
/// (already in their final positions); only `q` (and therefore the per-layer opacity) changes during the gesture.
public struct OverviewLayerDissolvePlan: Equatable, Sendable {
    public let sourceLevel: Int
    public let targetLevel: Int
    /// Source grid exactly as it appears settled at `sourceLevel` (its own scroll + display mode).
    public let source: GridFramePlan
    /// Target grid exactly as it appears settled at `targetLevel`, in FINAL positions (anchored scroll).
    public let target: GridFramePlan
    /// The source's own display mode (NOT forced square).
    public let sourceDisplayMode: TileContentDisplayMode
    /// The target's display mode — `squareFillCrop` for the overview levels.
    public let targetDisplayMode: TileContentDisplayMode
    /// Where the target settles (commit info): the anchored scroll-Y and column phase for `targetLevel`.
    public let targetScrollY: CGFloat
    public let targetColumnPhase: Int?
    /// Dissolve progress: 0 = pure source, 1 = pure target.
    public let q: Double

    public init(sourceLevel: Int, targetLevel: Int, source: GridFramePlan, target: GridFramePlan,
                sourceDisplayMode: TileContentDisplayMode, targetDisplayMode: TileContentDisplayMode,
                targetScrollY: CGFloat, targetColumnPhase: Int?, q: Double) {
        self.sourceLevel = sourceLevel
        self.targetLevel = targetLevel
        self.source = source
        self.target = target
        self.sourceDisplayMode = sourceDisplayMode
        self.targetDisplayMode = targetDisplayMode
        self.targetScrollY = targetScrollY
        self.targetColumnPhase = targetColumnPhase
        self.q = q
    }

    /// Opacity of the SOURCE layer (fades out as q→1).
    public var sourceOpacity: Double { 1 - overviewDissolveEase(q) }
    /// Opacity of the TARGET layer (fades in as q→1).
    public var targetOpacity: Double { overviewDissolveEase(q) }

    /// A copy at a new progress. The two rasters and display modes are unchanged — only the blend moves, so the
    /// target stays in its FINAL positions at every q (the whole point of a layer dissolve).
    public func withProgress(_ newQ: Double) -> OverviewLayerDissolvePlan {
        OverviewLayerDissolvePlan(sourceLevel: sourceLevel, targetLevel: targetLevel, source: source, target: target,
                                  sourceDisplayMode: sourceDisplayMode, targetDisplayMode: targetDisplayMode,
                                  targetScrollY: targetScrollY, targetColumnPhase: targetColumnPhase,
                                  q: min(1, max(0, newQ)))
    }
}

public extension SquareTileGridEngine {
    /// Build an overview layer dissolve from level `s` to adjacent level `t` (must be an overview boundary).
    /// The SOURCE plan is the current settled grid (its own scroll + display mode); the TARGET plan is the
    /// adjacent overview grid, anchored so the item under the cursor stays under the cursor, in square mode.
    /// Pure: it composes settled `framePlan`s + the engine's anchor math — no relocation, no transition builder.
    /// Returns nil if `s↔t` is not an overview boundary or the anchor can't resolve (empty library).
    ///
    /// SCROLL / ANCHOR policy (V3.13, direction-aware). The target layer is rendered at the SAME scroll the
    /// settled grid will commit to — never an un-clamped scroll — so there is no settle jump.
    ///   • The CURSOR anchor always wins: the target scroll keeps the cursor's item under the cursor (the raw
    ///     anchored scroll), then clamped to `[0, targetMaxY]`.
    ///   • The bottom-fill override is applied ONLY on zoom-OUT from a bottom-pinned source (`targetLevel >
    ///     sourceLevel` = toward the denser overview): there the overview is rendered bottom-filled
    ///     (`targetScrollY = targetMaxY`) to avoid the down-jump (V3.12). On pinch-IN (`targetLevel <
    ///     sourceLevel`) it is NEVER applied — a short overview source being bottom-pinned must not drag the
    ///     zoom back to the old origin.
    /// `targetMaxY` is 0 when the target content is shorter than the viewport, so a short target settles at 0
    /// (never stretched/faked). Direction is read from the levels (the ladder is monotonic in density, so
    /// `targetLevel > sourceLevel` ⟺ zooming out).
    func overviewLayerDissolvePlan(from s: Int, to t: Int, viewportSize: CGSize,
                                   sourceScrollY: CGFloat, sourceColumnPhase: Int?,
                                   preferredNormalMode: TileContentDisplayMode,
                                   anchorContentPoint: CGPoint, anchorViewportPoint: CGPoint,
                                   overscan: CGFloat) -> OverviewLayerDissolvePlan? {
        guard isOverviewBoundary(s, t) else { return nil }
        let width = viewportSize.width
        guard let a = anchorItem(nearContentPoint: anchorContentPoint, level: s, width: width,
                                 columnPhase: sourceColumnPhase) else { return nil }
        // Display modes: source keeps its own (square forced ONLY where the level is square-only); target square.
        let sourceMode = effectiveContentMode(preferred: preferredNormalMode, level: s)
        let targetMode = effectiveContentMode(preferred: preferredNormalMode, level: t)   // overview ⇒ squareFillCrop
        // Anchor the target so the cursor's item lands in the cursor's column (no horizontal fly on settle).
        let desiredColumn = cursorColumn(viewportX: anchorViewportPoint.x, level: t, width: width)
        let targetPhase = columnPhase(forItem: a.flatIndex, targetColumn: desiredColumn, level: t, width: width)
        let rawTargetScrollY = anchoredScrollOffset(flatIndex: a.flatIndex, localFraction: a.localFraction,
                                                    viewportPoint: anchorViewportPoint, level: t, width: width,
                                                    columnPhase: targetPhase).y
        // Final target scroll = what the settled grid will commit to (clamped; bottom-filled when at the bottom).
        let viewportH = viewportSize.height
        let sourceMaxY = max(0, contentSize(level: s, width: width, columnPhase: sourceColumnPhase).height - viewportH)
        let targetMaxY = max(0, contentSize(level: t, width: width, columnPhase: targetPhase).height - viewportH)
        let bottomPinEpsilon: CGFloat = 1.0   // ~the settled scroll-clamp tolerance; robust to sub-pixel rounding
        let sourceIsBottomPinned = abs(sourceScrollY - sourceMaxY) <= bottomPinEpsilon
        let isZoomingOut = t > s              // density ladder is monotonic ⇒ t > s ⟺ zooming out toward overview
        // Cursor anchoring wins; the bottom-fill override is a zoom-OUT-from-bottom protection only (V3.13).
        let targetScrollY = (isZoomingOut && sourceIsBottomPinned)
            ? targetMaxY
            : min(max(0, rawTargetScrollY), targetMaxY)
        let sourcePlan = framePlan(level: s, viewportSize: viewportSize, scrollOffset: CGPoint(x: 0, y: sourceScrollY),
                                   overscan: overscan, columnPhase: sourceColumnPhase)
        let targetPlan = framePlan(level: t, viewportSize: viewportSize, scrollOffset: CGPoint(x: 0, y: targetScrollY),
                                   overscan: overscan, columnPhase: targetPhase)
        return OverviewLayerDissolvePlan(sourceLevel: s, targetLevel: t, source: sourcePlan, target: targetPlan,
                                         sourceDisplayMode: sourceMode, targetDisplayMode: targetMode,
                                         targetScrollY: targetScrollY, targetColumnPhase: targetPhase, q: 0)
    }
}
