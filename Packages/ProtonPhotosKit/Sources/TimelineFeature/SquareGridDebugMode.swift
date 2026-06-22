import CoreGraphics
import Foundation
import simd

// MARK: - Synthetic square-grid debug mode
//
// Renders the grid WITHOUT real thumbnails — one colored square per visible render slot, straight from
// `GridRenderSlot.rect`. The current problem class is grid GEOMETRY, not photos, so this mode lets the
// grid be validated visually (square slots, consistent gaps, both edges filled, dynamic gap) before any
// texture/aspect logic is involved. No texture cache, no media aspect, no black areas where slots exist.

/// One synthetic draw command: a solid colored square for a single visible slot (viewport coords).
public struct GridDebugSlotCommand: Equatable, Sendable {
    public let index: Int
    public let row: Int
    public let column: Int
    public let rect: CGRect           // viewport-space; ALWAYS square (== GridRenderSlot.rect)
    public let color: SIMD4<Float>    // premultiply-friendly straight RGBA

    public init(index: Int, row: Int, column: Int, rect: CGRect, color: SIMD4<Float>) {
        self.index = index
        self.row = row
        self.column = column
        self.rect = rect
        self.color = color
    }
}

public enum SquareGridDebugMode {
    /// Exactly ONE command per visible slot, in plan order (GridDebugModeEmitsOneCommandPerVisibleSlotTest).
    /// Colors are a deterministic function of (row, column) so the grid structure reads at a glance and the
    /// gaps between squares are obvious. Maps the engine's content-space `GridSlot` to viewport-space render
    /// slots first (`viewportRect`), then emits one command each.
    public static func commands(for plan: GridFramePlan) -> [GridDebugSlotCommand] {
        commands(forSlots: plan.visibleSlots.map {
            GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect)
        })
    }

    /// One command per render slot (used by the live zoom transaction, which emits `GridRenderSlot` directly).
    public static func commands(forSlots slots: [GridRenderSlot]) -> [GridDebugSlotCommand] {
        slots.map { slot in
            GridDebugSlotCommand(index: slot.index, row: slot.row, column: slot.column,
                                 rect: slot.rect, color: color(row: slot.row, column: slot.column))
        }
    }

    /// A stable, high-contrast color per (row, column): hue cycles by column, brightness alternates by row,
    /// so adjacent squares are visually distinct and the gap grid is unmistakable.
    public static func color(row: Int, column: Int) -> SIMD4<Float> {
        let hue = Float((column * 47 + row * 13) % 360) / 360
        let brightness: Float = (row & 1 == 0) ? 0.92 : 0.72
        return hsv(h: hue, s: 0.62, v: brightness)
    }

    /// A stable color keyed ONLY by GLOBAL INDEX (identity) — used by the synthetic transition path so a given
    /// photo keeps its colour as it fades. If an identity ever flew across the grid, its colour would visibly
    /// translate; with the crossfade it fades in/out in place instead.
    public static func color(forIndex index: Int) -> SIMD4<Float> {
        let hue = Float((index &* 137) % 360) / 360          // golden-ish stride for well-spread hues
        let brightness: Float = (index & 1 == 0) ? 0.90 : 0.74
        return hsv(h: hue, s: 0.66, v: brightness)
    }

    private static func hsv(h: Float, s: Float, v: Float) -> SIMD4<Float> {
        let i = Int(h * 6) % 6
        let f = h * 6 - Float(Int(h * 6))
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)
        let rgb: (Float, Float, Float)
        switch i {
        case 0: rgb = (v, t, p)
        case 1: rgb = (q, v, p)
        case 2: rgb = (p, v, t)
        case 3: rgb = (p, q, v)
        case 4: rgb = (t, p, v)
        default: rgb = (v, p, q)
        }
        return SIMD4(rgb.0, rgb.1, rgb.2, 1)
    }
}

/// Flag for the synthetic square-grid debug render. Default OFF. Toggle via the `MetalGrid.debugGrid`
/// UserDefaults key or `-MetalGrid.debugGrid YES` at launch — so the canonical geometry can be validated
/// on real-data builds without touching thumbnails.
public enum MetalGridDebugGridFlag {
    public static let userDefaultsKey = "MetalGrid.debugGrid"

    public static var isEnabled: Bool {
        guard UserDefaults.standard.object(forKey: userDefaultsKey) != nil else { return false } // default OFF
        return UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: userDefaultsKey)
    }
}
