import CoreGraphics

// MARK: - Grid Zoom Transition (pure planner)
//
// Renders the move between two FIXED detents (never an arbitrary per-frame topology). The Apple-matched
// model (see docs/grid-zoom-apple-model.md):
//
//   Two surfaces — the SOURCE detent layout and the TARGET detent layout — are both anchored at the SAME
//   screen point and geometrically scaled to one shared "apparent" cell size, so they live in one shared
//   world (never "old window pasted over new grid"). The source is the full backdrop (alpha 1); the target
//   is composited on top with a per-cell crossfade alpha. The transition FAMILY is just how that alpha is
//   weighted:
//     • focusPreservingReplacement (adjacent same-family levels): focus-distance-weighted — cells near the
//       cursor row keep the source until late (the focus row reads as static); far cells cross early
//       (in-place replacement to the chronologically-correct photo). No tile ever travels between slots.
//     • fullGridCrossfade / squareToAspectWhoosh (family change / big column jump): a global crossfade —
//       the whole grid dissolves together (a calm whoosh), exactly as Apple does at aspect↔square.
//
// Endpoints are exact: progress 0 → only the source layout; progress 1 → only the target layout. So a
// release that settles to a detent lands on the real grid with no topology pop.

public enum GridZoomTransitionFamily: String, Equatable, Sendable {
    /// Same family, same column count — pure geometric scale (degenerate; content barely changes).
    case geometricScaleOnly
    /// Adjacent same-family levels (justified↔justified or square↔square at small Δcols): focus-protected
    /// per-cell crossfade. The cursor row stays; far rows replace in place.
    case focusPreservingReplacement
    /// Same family but a large column jump (dense square↔square): global crossfade / whoosh.
    case fullGridCrossfade
    /// Crop family changes (justified aspect rows ↔ square mosaic): global crossfade / whoosh.
    case squareToAspectWhoosh

    /// True when the per-cell alpha is focus-distance-weighted (only the near family). The others are global.
    public var isFocusWeighted: Bool { self == .focusPreservingReplacement }
}

/// Selects the transition family for a pair of detents (order-independent).
public enum GridZoomTransitionPolicy {
    public static func family(_ a: GridZoomDetent, _ b: GridZoomDetent, width: CGFloat = 1200) -> GridZoomTransitionFamily {
        if a.family != b.family { return .squareToAspectWhoosh }
        let ca = a.approximateColumns(width: width)
        let cb = b.approximateColumns(width: width)
        let dCols = abs(ca - cb)
        if dCols == 0 { return .geometricScaleOnly }
        switch a.family {
        case .justifiedAspectRows:
            return .focusPreservingReplacement
        case .squareGrid:
            // The square overview detents jump many columns each step → a global whoosh reads better than a
            // per-cell crossfade (every cell changes content anyway).
            return dCols >= 4 ? .fullGridCrossfade : .focusPreservingReplacement
        }
    }
}

public enum GridZoomEasing {
    public static func clamp01(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }
    public static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    /// Smoothstep (C¹, flat at both ends) — calm acceleration/deceleration.
    public static func smoothstep(_ x: CGFloat) -> CGFloat {
        let t = clamp01(x)
        return t * t * (3 - 2 * t)
    }
}

/// Anchored geometric transform for ONE surface: scales content around a fixed screen anchor so the anchor
/// content point always lands on the same screen point. `screen = anchor + (content - anchorContent) * scale`.
public struct GridZoomSurfaceTransform: Equatable, Sendable {
    public let anchorScreen: CGPoint
    public let anchorContent: CGPoint
    public let scale: CGFloat

    public init(anchorScreen: CGPoint, anchorContent: CGPoint, scale: CGFloat) {
        self.anchorScreen = anchorScreen
        self.anchorContent = anchorContent
        self.scale = max(scale, 0.0001)
    }

    public func screenPoint(_ c: CGPoint) -> CGPoint {
        CGPoint(x: anchorScreen.x + (c.x - anchorContent.x) * scale,
                y: anchorScreen.y + (c.y - anchorContent.y) * scale)
    }

    public func contentPoint(_ s: CGPoint) -> CGPoint {
        CGPoint(x: anchorContent.x + (s.x - anchorScreen.x) / scale,
                y: anchorContent.y + (s.y - anchorScreen.y) / scale)
    }

    /// A content-space rect → its scaled screen rect.
    public func screenRect(_ r: CGRect) -> CGRect {
        let o = screenPoint(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale)
    }

    /// The content-space rect that covers a viewport rect (for the visibility query of this surface).
    public func contentRect(forViewport v: CGRect) -> CGRect {
        let tl = contentPoint(CGPoint(x: v.minX, y: v.minY))
        let br = contentPoint(CGPoint(x: v.maxX, y: v.maxY))
        return CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
    }
}

/// The immutable plan for one transition frame. Pure: given source/target detents, progress, the two
/// transforms and the focus center, it yields per-cell crossfade alpha and the focus weighting. The
/// coordinator queries the two `GridDetentLayout`s and uses these to place + blend quads.
public struct GridZoomTransitionPlan: Equatable, Sendable {
    public let source: GridZoomDetent
    public let target: GridZoomDetent
    /// 0 = fully source, 1 = fully target.
    public let progress: CGFloat
    public let family: GridZoomTransitionFamily
    public let apparentSize: CGFloat
    public let sourceTransform: GridZoomSurfaceTransform
    public let targetTransform: GridZoomSurfaceTransform
    /// Screen-space Y under the cursor (the focus row center) and the protected radius (screen points).
    public let focusScreenY: CGFloat
    public let focusRadius: CGFloat

    /// Focus weight (1 at the cursor row, 0 beyond `focusRadius`) for a cell centered at screen Y.
    public func focusWeight(screenY: CGFloat) -> CGFloat {
        guard family.isFocusWeighted, focusRadius > 0 else { return family.isFocusWeighted ? 1 : 0 }
        let d = abs(screenY - focusScreenY)
        return GridZoomEasing.smoothstep(1 - d / focusRadius)
    }

    /// The TARGET cell's composite alpha (the source is the full backdrop beneath it).
    ///  • global families: `smoothstep(progress)` for every cell (a synchronized whoosh).
    ///  • focus-preserving: a progress window that opens LATE for focus cells (≈[0.5,1]) and EARLY for far
    ///    cells (≈[0,0.5]) — so the focus row holds the source until late while far rows replace first.
    public func targetAlpha(focusWeight w: CGFloat) -> CGFloat {
        switch family {
        case .geometricScaleOnly, .fullGridCrossfade, .squareToAspectWhoosh:
            return GridZoomEasing.smoothstep(progress)
        case .focusPreservingReplacement:
            let lo = 0.5 * w                // focus (w=1) starts at 0.5; far (w=0) starts at 0
            let hi = 0.5 + 0.5 * w          // focus ends at 1.0; far ends at 0.5
            return GridZoomEasing.smoothstep((progress - lo) / max(hi - lo, 0.0001))
        }
    }

    /// Convenience: target alpha for a cell, deriving its focus weight from its screen-Y center.
    public func targetAlpha(cellScreenMidY y: CGFloat) -> CGFloat {
        targetAlpha(focusWeight: focusWeight(screenY: y))
    }
}

/// Builds a `GridZoomTransitionPlan` for the current gesture state. Pure — no AppKit / layout queries; the
/// caller supplies the anchor item's content position in each detent layout (or the raw content point as a
/// fallback when the cursor is over a gap).
public enum GridZoomTransitionPlanner {
    /// - Parameters:
    ///   - levelPosition: continuous fractional level (e.g. 2.3). Source = floor, target = floor+1.
    ///   - anchorScreen: viewport point held fixed under the cursor.
    ///   - anchorContentSource/Target: the anchor location in each layout's content space (the same photo).
    ///   - focusRows: how many apparent rows around the cursor are "protected" in the near family.
    public static func plan(
        model: GridZoomDetentModel,
        levelPosition x: CGFloat,
        width: CGFloat,
        anchorScreen: CGPoint,
        anchorContentSource: CGPoint,
        anchorContentTarget: CGPoint,
        focusRows: CGFloat = 2.0
    ) -> GridZoomTransitionPlan {
        let clampedX = min(max(x, 0), CGFloat(model.count - 1))
        let lo = Int(clampedX.rounded(.down))
        let sIndex = model.clampIndex(lo)
        let tIndex = model.clampIndex(lo + 1)
        let progress = GridZoomEasing.clamp01(clampedX - CGFloat(lo))
        let s = model.detent(sIndex)
        let t = model.detent(tIndex)

        let eased = GridZoomEasing.smoothstep(progress)
        let apparent = GridZoomEasing.lerp(s.size, t.size, eased)
        let sourceScale = apparent / max(s.size, 0.0001)
        let targetScale = apparent / max(t.size, 0.0001)

        let family = GridZoomTransitionPolicy.family(s, t, width: width)

        return GridZoomTransitionPlan(
            source: s,
            target: t,
            progress: progress,
            family: family,
            apparentSize: apparent,
            sourceTransform: GridZoomSurfaceTransform(anchorScreen: anchorScreen, anchorContent: anchorContentSource, scale: sourceScale),
            targetTransform: GridZoomSurfaceTransform(anchorScreen: anchorScreen, anchorContent: anchorContentTarget, scale: targetScale),
            focusScreenY: anchorScreen.y,
            focusRadius: max(apparent * focusRows, 1)
        )
    }
}
