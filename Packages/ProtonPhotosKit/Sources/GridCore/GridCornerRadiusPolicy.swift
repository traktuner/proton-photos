import CoreGraphics

/// Slot-size-derived thumbnail corner radius - the single shared policy for every platform grid host.
///
/// Dense square levels must draw SHARP 90° corners: at tiny slot sides a rounded corner both looks wrong
/// (the old behavior clamped the radius UP to half the slot, turning dense cells into blobs) and forces the
/// renderer to alpha-blend an anti-aliased SDF edge on thousands of tiny quads. Large settled tiles keep the
/// polished reference radius (`GridVisualConstants.thumbnailCornerRadius`).
///
/// The curve is CONTINUOUS in the slot side so a live pinch never pops:
/// - `side ≤ sharpMaxSidePoints` (tiny/dense): radius 0 - sharp corners, and the renderer's radius-0 fast
///   path skips the rounded-rect SDF entirely.
/// - above that, the radius ramps linearly (`radiusPerPointAboveCutoff` per point of side) until it reaches
///   `base`, so medium tiles get a reduced radius and large tiles the full one. With the production base of
///   11 pt the ramp reaches full radius at a 119 pt slot.
///
/// Pure geometry policy: no platform framework, no per-level or per-device special cases - iPhone, iPad,
/// macOS, and future profiles all inherit the behavior from their slot sizes alone.
package enum GridCornerRadiusPolicy {
    /// Slot sides at or below this draw perfectly sharp corners (radius 0).
    package static let sharpMaxSidePoints: CGFloat = 64
    /// Radius gained per point of slot side above `sharpMaxSidePoints` (the continuous ramp slope).
    package static let radiusPerPointAboveCutoff: CGFloat = 0.2

    /// Corner radius (points) for a square slot with the given side, ramping 0 → `base`.
    /// Monotonic non-decreasing in `side`, never exceeds `base`, and never exceeds `side / 2`.
    package static func radius(
        forSlotSidePoints side: CGFloat,
        base: CGFloat = GridVisualConstants.thumbnailCornerRadius
    ) -> CGFloat {
        guard base > 0, side > sharpMaxSidePoints else { return 0 }
        let ramped = (side - sharpMaxSidePoints) * radiusPerPointAboveCutoff
        return min(min(base, ramped), side * 0.5)
    }
}
