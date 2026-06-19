import CoreGraphics

// MARK: - Grid Zoom Detent Model
//
// The SINGLE, data-driven source of truth for the Apple-Photos-style grid zoom. Derived frame-by-frame
// from two Apple Photos recordings (see docs/grid-zoom-apple-model.md): a small set of fixed DETENTS, a
// pinch that glides between them, and a snap to the nearest one on release.
//
// Two LAYOUT FAMILIES, exactly as observed in Apple Photos:
//   • justifiedAspectRows — the near/large levels: uniform row height, variable cell widths = the photo's
//     aspect ratio, a visible gap, NO crop and NO letterbox bars. Adjacent detents are ~1 column apart, so
//     the per-slot crossfade between them is calm.
//   • squareGrid — the dense/far "overview" levels: a uniform square mosaic, near-gapless, center-cropped,
//     with month/year labels.
//
// Nothing here is @MainActor or AppKit/Metal-aware: it is a pure, Sendable value model so the whole zoom
// behavior (detents, snap, transition family, anchor math) is unit-testable without a GPU or a run loop.

/// How a detent arranges its cells. The transition family between two detents is derived from this pair.
public enum GridLayoutFamily: String, Equatable, Sendable {
    /// Apple's near/large levels — justified rows of variable-aspect cells, no crop, no letterbox bars.
    case justifiedAspectRows
    /// Apple's dense/far levels — a uniform square mosaic, center-cropped, near-gapless.
    case squareGrid
}

/// One fixed zoom detent. `id == 0` is the most zoomed-IN level (largest thumbnails); the last id is the
/// most zoomed-OUT (densest overview).
public struct GridZoomDetent: Equatable, Sendable {
    public let id: Int
    public let family: GridLayoutFamily
    /// justifiedAspectRows → target ROW HEIGHT. squareGrid → target CELL SIDE. (Both: nominal thumb extent.)
    public let size: CGFloat
    /// Inter-cell gap (points).
    public let gap: CGFloat
    /// Whether this detent shows month/year section labels (Apple shows them only on the dense overview).
    public let monthLabels: Bool

    public init(id: Int, family: GridLayoutFamily, size: CGFloat, gap: CGFloat, monthLabels: Bool) {
        self.id = id
        self.family = family
        self.size = size
        self.gap = gap
        self.monthLabels = monthLabels
    }

    /// Approximate column count at a width. For the square grid this is exact; for justified rows it is the
    /// *average* (cell widths vary with photo aspect) assuming a typical mean aspect ratio.
    public func approximateColumns(width: CGFloat, meanAspect: CGFloat = 1.1) -> Int {
        guard width > 1, size > 0 else { return 1 }
        switch family {
        case .squareGrid:
            return max(1, Int((width + gap) / (size + gap)))
        case .justifiedAspectRows:
            let cellWidth = meanAspect * size
            return max(1, Int((width + gap) / (cellWidth + gap)))
        }
    }
}

/// Tunables for the pinch → detent behavior. Centralized so the feel can be adjusted in one place after
/// live testing (the user explicitly asked for the ladder + feel to be data-driven, not buried in code).
public struct GridZoomTuning: Equatable, Sendable {
    /// A pinch that moves the continuous level position less than this (and isn't a flick) snaps back to the
    /// source detent — so a tiny accidental pinch is a no-op.
    public var snapDeadzone: CGFloat = 0.22
    /// |velocity| (levels/sec) above which a release is treated as a flick and biased one detent further in
    /// the direction of motion.
    public var flickVelocity: CGFloat = 2.2
    /// Seconds for the post-release settle animation (ease the apparent scale onto the snapped detent).
    public var settleDuration: Double = 0.22
    /// Magnification (cumulative trackpad `event.magnification`) that equals one whole detent step. Smaller
    /// = more sensitive pinch.
    public var magnificationPerDetent: CGFloat = 0.42

    public init() {}
    public static let `default` = GridZoomTuning()
}

/// The fixed ladder of detents + neighbor/snap logic. `GridZoomDetentModel.apple` is the Apple-matched
/// default; it is the only place the densities live, so retuning is a one-file edit.
public struct GridZoomDetentModel: Equatable, Sendable {
    public let detents: [GridZoomDetent]
    public let defaultIndex: Int
    public var tuning: GridZoomTuning

    public init(detents: [GridZoomDetent], defaultIndex: Int, tuning: GridZoomTuning = .default) {
        precondition(!detents.isEmpty, "detent ladder must not be empty")
        self.detents = detents
        self.defaultIndex = min(max(defaultIndex, 0), detents.count - 1)
        self.tuning = tuning
    }

    public var count: Int { detents.count }

    public func clampIndex(_ i: Int) -> Int { min(max(i, 0), detents.count - 1) }

    public func detent(_ i: Int) -> GridZoomDetent { detents[clampIndex(i)] }

    /// The neighbor detent index in a zoom direction. Zooming IN = bigger thumbnails = a LOWER index.
    public func neighborIndex(of i: Int, zoomingIn: Bool) -> Int {
        clampIndex(zoomingIn ? i - 1 : i + 1)
    }

    /// Snap a continuous level position to a detent index on release.
    ///
    /// `position` is the fractional level (e.g. 2.3 = 30 % from detent 2 toward detent 3, i.e. zooming out).
    /// `velocity` is in levels/sec; positive = moving toward a higher index (zooming out). `source` is the
    /// detent the gesture started on.
    ///
    /// Rules (pinned by DetentSnapTests):
    ///  • tiny move from source + no flick → stay on `source` (no accidental zoom);
    ///  • otherwise snap to the NEAREST detent;
    ///  • a flick biases one detent further in the velocity direction (momentum), never against it.
    public func snapIndex(position: CGFloat, velocity: CGFloat, source: Int) -> Int {
        let delta = position - CGFloat(source)
        let isFlick = abs(velocity) >= tuning.flickVelocity
        if abs(delta) < tuning.snapDeadzone && !isFlick {
            return clampIndex(source)
        }
        var target = Int(position.rounded())
        if isFlick {
            // Momentum: continue at least to the next detent in the direction of travel.
            if velocity > 0 {
                target = max(target, Int(position.rounded(.up)))
            } else {
                target = min(target, Int(position.rounded(.down)))
            }
        }
        return clampIndex(target)
    }

    /// Map a cumulative pinch magnification (trackpad `event.magnification`, positive = zoom in) onto a
    /// continuous level position relative to the gesture's starting detent (clamped to the ladder).
    public func levelPosition(source: Int, cumulativeMagnification: CGFloat) -> CGFloat {
        min(max(rawLevelPosition(source: source, cumulativeMagnification: cumulativeMagnification), 0), CGFloat(detents.count - 1))
    }

    /// The UNclamped continuous level position (can go past the ends — used for the rubber-band).
    public func rawLevelPosition(source: Int, cumulativeMagnification: CGFloat) -> CGFloat {
        CGFloat(source) - cumulativeMagnification / max(tuning.magnificationPerDetent, 0.0001)
    }

    /// Soft RUBBER-BAND clamp: inside the ladder it's identity; past either end the over-travel has
    /// diminishing returns (asymptotes to ~0.5 a level), so the largest level over-zooms a little and the
    /// release snap (which clamps to a real detent) springs it back. Matches Apple's grid rubber-band.
    public func rubberBanded(_ raw: CGFloat) -> CGFloat {
        let maxIndex = CGFloat(detents.count - 1)
        if raw < 0 { return -softOver(-raw) }
        if raw > maxIndex { return maxIndex + softOver(raw - maxIndex) }
        return raw
    }

    private func softOver(_ over: CGFloat) -> CGFloat { 0.5 * (1 - 1 / (1 + max(over, 0))) }

    // MARK: - The Apple-matched default ladder
    //
    // Densities derived from the videos (see docs/grid-zoom-apple-model.md). The three justified levels are
    // ~1–2 columns apart (calm per-slot crossfade); the three square levels are the dense overview (whoosh).
    // Sizes are ROW HEIGHT (justified) / CELL SIDE (square) in points; tune here after live testing.
    // Calibrated against a direct Apple-vs-Proton comparison on the same screen (2026-06-19): Apple's aspect
    // grid runs ~4–8 columns of BIG thumbnails; the previous ladder was ~1.6× too dense ("viel zu eng"). The
    // aspect detents are spaced ~1 column apart so a step reflows only a little (smooth, few cell-wraps).
    // Sizes = justified ROW HEIGHT / square CELL SIDE in points; retune here after live testing.
    // VERIFIED 2026-06-19 against `apple zoom out.mov` (frame-by-frame + a 3-reader cross-check): Apple
    // Photos macOS keeps JUSTIFIED variable-aspect rows at EVERY zoom level in the pinch range — wide
    // panoramas stay wide, portraits stay narrow, the full photo is shown (no square center-crop), the grid
    // is edge-to-edge with no black at any density. So the whole ladder is one continuous justified
    // densification (no aspect→square family change). The square family/policy is retained in the codebase
    // (not yet deleted, per the visual-sign-off rule) but is no longer used by the default ladder.
    public static let apple = GridZoomDetentModel(
        detents: [
            // id 0 — most zoomed IN (largest thumbnails). Gaps are GENEROUS like Apple (~6–7% of row height).
            GridZoomDetent(id: 0, family: .justifiedAspectRows, size: 470, gap: 30, monthLabels: false), // ~3–4 cols
            GridZoomDetent(id: 1, family: .justifiedAspectRows, size: 360, gap: 24, monthLabels: false), // ~5 cols
            GridZoomDetent(id: 2, family: .justifiedAspectRows, size: 292, gap: 20, monthLabels: false), // ~6 cols (default)
            GridZoomDetent(id: 3, family: .justifiedAspectRows, size: 242, gap: 16, monthLabels: false), // ~7–8 cols
            // Dense overview — STILL justified (verified), just a smaller row height. Was square-crop; corrected.
            GridZoomDetent(id: 4, family: .justifiedAspectRows, size: 185, gap: 12, monthLabels: false), // ~9–10 cols
            GridZoomDetent(id: 5, family: .justifiedAspectRows, size: 128, gap: 8,  monthLabels: false), // ~13–14 cols (densest)
        ],
        defaultIndex: 2
    )
}
