import CoreGraphics

// MARK: - GridSizePolicy — platform-neutral level → reference photo size (SIZE-BASED SCAFFOLDING, NOT adopted)
//
// NOTE: this maps a level to a per-level REFERENCE photo size for a SIZE-BASED / ADAPTIVE-COLUMNS model that was
// explored but is NOT the adopted runtime rule. The shipping grid is FIXED-COLUMNS: the settled resolve HOLDS
// each level's `nominalColumns` and fills the width (`SquareTileGridEngine.resolvedForLevel` passes
// `fixedColumns: nominalColumns`), so a window resize SCALES the tile and the column count changes only on a
// zoom. `referenceSlotSide` (which this policy computes) is passed to the resolve as `targetSide` but is
// OVERRIDDEN by the fixed-columns branch, so this policy does NOT currently drive the settled column count.
// Retained as calibration + the seam for a possible future responsive size-class pass (the same pure core could
// later drive an iPad/iPhone layout via `.compact`). Pure value type (CoreGraphics only, no AppKit/UIKit).
//
// The round column rule (`columnsForFixedSide`) referenced below is used in production ONLY by the live pinch
// over-zoom lattice, never by the settled grid. `nominalColumns` seeds the `.regular` size at the reference
// width and is the spec-guard literal.
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
