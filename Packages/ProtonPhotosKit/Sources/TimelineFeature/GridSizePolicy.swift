import CoreGraphics

// MARK: - GridSizePolicy — platform-neutral level → fixed photo size
//
// The size-based grid model: a zoom LEVEL fixes the on-screen PHOTO SIZE (points); the column count adapts to
// width (`SquareTileGridEngine.columnsForFixedSide`). The photo size is CONSTANT during any live resize within
// a viewport size class and changes only in DISCRETE steps at class breakpoints — so the grid never "breathes"
// (no continuous tile rescale tracking the drag). This policy is the single seam that maps a level to its fixed
// size; it is a pure value type (CoreGraphics only, no AppKit/UIKit) so the geometry engine stays
// platform-neutral and the same core can drive a future iPad/iPhone layout (which would select `.compact`).
//
// `nominalColumns` is retained ONLY as the density key that seeds the `.regular` size at the reference width
// (and as the spec-guard literal); it is never a runtime column source under this model.
public enum GridSizePolicy {

    /// Discrete viewport size classes. Desktop ships `.regular`; iOS can later select `.compact` by idiom.
    /// Crossing a breakpoint is ONE discrete size step (allowed) — never a continuous rescale.
    public enum SizeClass: String, Equatable, Sendable, CaseIterable {
        case compact, regular, wide, ultra
    }

    /// The density-anchor width at which the `.regular` class reproduces today's column-derived sizes. A
    /// CALIBRATION SEED (tunable), NOT product law — the responsive policy may override per class.
    public static let referenceWidth: CGFloat = 1280

    /// Sub-pixel nudge so the exact-fill side does not FP-floor-truncate to `nominalColumns − 1` at the
    /// reference width (proven for L2 → 6 and L5 → 29 without it). With it, every level round-trips to its
    /// `nominalColumns` at `referenceWidth` (see `columnsForFixedSide`).
    public static let epsilon: CGFloat = 0.5

    /// Discrete per-class scale on the `.regular` size.
    public static func scale(_ sizeClass: SizeClass) -> CGFloat {
        switch sizeClass {
        case .compact: return 0.62
        case .regular: return 1.0
        case .wide:    return 1.15
        case .ultra:   return 1.30
        }
    }

    /// The FIXED photo side (points) for a level keyed by its density (`nominalColumns`) + `gap`, at a size
    /// class. `.regular` reproduces the legacy size at `referenceWidth`; other classes scale it discretely.
    public static func slotSide(nominalColumns: Int, gap: CGFloat, sizeClass: SizeClass = .regular) -> CGFloat {
        let nc = CGFloat(max(1, nominalColumns))
        let base = (referenceWidth + gap) / nc - gap - epsilon     // exact-fill at W_ref, minus the FP nudge
        return max(1, base * scale(sizeClass))
    }

    /// The size class for a desktop viewport width. Desktop ships `.regular` ONLY for now — responsive
    /// breakpoints are reserved so that enabling them is a deliberate, isolated change, never a silent jump.
    public static func sizeClass(forWidth width: CGFloat) -> SizeClass { .regular }

    /// Optional per-level hard column cap. When it binds the surplus width becomes margin (clip/reveal) — NEVER
    /// a tile stretch. `nil` by default: the largest level shows MORE big photos on a wide display (the chosen
    /// responsive product behavior); the cap seam exists to bound ultra-wide spread later if wanted.
    public static func maxColumns(forLevelID levelID: Int) -> Int? { nil }
}
