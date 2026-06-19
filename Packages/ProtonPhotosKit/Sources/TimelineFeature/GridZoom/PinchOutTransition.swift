import CoreGraphics

// MARK: - Pinch-OUT replacement transition (pure, testable core)
//
// The live pinch-OUT (zoom toward a denser/wider topology) is a CROSS-DISSOLVE between two FIXED grid
// topologies, derived frame-by-frame from Apple Photos (full-width throughout, existing centre cells are
// replaced by different photos via alpha, nothing slides). The previous bug: the SOURCE grid stayed opaque
// and the TARGET was drawn behind it, so existing cells never participated. This type fixes the *model*:
//
//   • SOURCE topology = the current grid at the start of the topology transition (UID → screen rect).
//   • TARGET topology = the denser grid being moved toward (UID → screen rect).
//   • Every cell is classified (unchanged / replacement / targetOnly) by region, ONCE, and FROZEN for the
//     transition's life so identities never flicker.
//   • Per-cell COMPLEMENTARY alpha: source fades out (1 - p), target fades in (p). The focus row is
//     protected (its progress is delayed) so the photo under the cursor stays calm.
//
// Nothing here is @MainActor or AppKit/Metal-aware: it is a pure value model, unit-tested without a GPU.

/// One cell of a topology snapshot: a photo (by flat library index) at a screen-space rect.
public struct PinchOutCell: Equatable, Sendable {
    public let flatIndex: Int
    public let rect: CGRect
    public init(flatIndex: Int, rect: CGRect) {
        self.flatIndex = flatIndex
        self.rect = rect
    }
    public var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}

/// The frozen replacement plan for one SOURCE → TARGET pinch-out. Classifies every cell and yields the
/// per-cell source/target alpha for a transition progress in 0…1.
public struct PinchOutPlan: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// Same photo, ~same screen region → keep the source, skip the target (no fade, no duplicate).
        case unchanged
        /// A source region whose photo changes in the target → source fades out, target fades in (the key case).
        case replacement
        /// A target cell with no source coverage (newly exposed area) → fade in from nothing.
        case targetOnly
    }

    public struct SourceItem: Equatable, Sendable {
        public let flatIndex: Int
        public let rect: CGRect
        public let focusWeight: CGFloat   // 1 at the cursor row → 0 beyond the focus radius
        public let isUnchanged: Bool      // its photo survives in the target at ~the same spot
    }
    public struct TargetItem: Equatable, Sendable {
        public let flatIndex: Int
        public let rect: CGRect
        public let focusWeight: CGFloat
        public let kind: Kind
    }

    public let source: [SourceItem]
    public let target: [TargetItem]
    public let anchorFlatIndex: Int?
    public let replacementCount: Int
    public let targetOnlyCount: Int
    public let unchangedCount: Int

    /// - Parameters:
    ///   - focusScreenY: the cursor's screen Y (centre of the protected band).
    ///   - focusRadius: half-height of the protected band in points (cells within fade later).
    public init(source sourceCells: [PinchOutCell], target targetCells: [PinchOutCell],
                anchorFlatIndex: Int?, focusScreenY: CGFloat, focusRadius: CGFloat) {
        func focusWeight(_ rect: CGRect) -> CGFloat {
            guard focusRadius > 0 else { return 0 }
            let d = abs(rect.midY - focusScreenY)
            return max(0, min(1, 1 - d / focusRadius))
        }
        // Source photo set (flat index → rect) for the unchanged/replacement test.
        var sourceRectByIndex: [Int: CGRect] = [:]
        sourceRectByIndex.reserveCapacity(sourceCells.count)
        for c in sourceCells { sourceRectByIndex[c.flatIndex] = c.rect }

        var tgt: [TargetItem] = []
        tgt.reserveCapacity(targetCells.count)
        var survives = Set<Int>()   // source photos that are unchanged in the target
        var rep = 0, tonly = 0, unch = 0
        for c in targetCells {
            let kind: Kind
            if let sr = sourceRectByIndex[c.flatIndex], PinchOutPlan.rectsRoughlyEqual(sr, c.rect) {
                kind = .unchanged; unch += 1; survives.insert(c.flatIndex)
            } else if PinchOutPlan.anyContains(point: c.center, cells: sourceCells) {
                kind = .replacement; rep += 1
            } else {
                kind = .targetOnly; tonly += 1
            }
            tgt.append(TargetItem(flatIndex: c.flatIndex, rect: c.rect, focusWeight: focusWeight(c.rect), kind: kind))
        }
        var src: [SourceItem] = []
        src.reserveCapacity(sourceCells.count)
        for c in sourceCells {
            src.append(SourceItem(flatIndex: c.flatIndex, rect: c.rect,
                                  focusWeight: focusWeight(c.rect), isUnchanged: survives.contains(c.flatIndex)))
        }
        self.source = src
        self.target = tgt
        self.anchorFlatIndex = anchorFlatIndex
        self.replacementCount = rep
        self.targetOnlyCount = tonly
        self.unchangedCount = unch
    }

    /// The protected local progress for a cell: the focus row (weight→1) doesn't begin until `focusDelay`
    /// of the way through, so the photo under the cursor stays calm while the periphery replaces first.
    public func localProgress(focusWeight w: CGFloat, progress p: CGFloat, focusDelay: CGFloat = 0.5) -> CGFloat {
        let delay = focusDelay * max(0, min(1, w))
        return max(0, min(1, (p - delay) / max(1 - delay, 0.0001)))
    }

    /// SOURCE cell alpha: fades out as its local progress rises. An unchanged photo stays fully opaque (the
    /// target skips it), so it never dips/ghosts.
    public func sourceAlpha(_ item: SourceItem, progress p: CGFloat) -> CGFloat {
        if item.isUnchanged { return 1 }
        return 1 - localProgress(focusWeight: item.focusWeight, progress: p)
    }
    /// TARGET cell alpha: fades in (complementary to the source it replaces). Unchanged → 0 (source shows it).
    public func targetAlpha(_ item: TargetItem, progress p: CGFloat) -> CGFloat {
        if item.kind == .unchanged { return 0 }
        return localProgress(focusWeight: item.focusWeight, progress: p)
    }

    static func rectsRoughlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.midX - b.midX) <= a.width * 0.5
            && abs(a.midY - b.midY) <= a.height * 0.5
            && abs(a.width - b.width) <= a.width * 0.5
            && abs(a.height - b.height) <= a.height * 0.5
    }
    static func anyContains(point: CGPoint, cells: [PinchOutCell]) -> Bool {
        for c in cells where c.rect.contains(point) { return true }
        return false
    }
}

/// Autonomous (time-based) progress clock for the pinch-out cross-dissolve. The duration shrinks with the
/// pinch velocity so a fast pinch is near-instant and a slow / paused pinch runs the full ~1s; the progress
/// keeps advancing on the clock even if the fingers stop, so it never freezes at half opacity.
public enum PinchOutTiming {
    public static let slowDuration: CFTimeInterval = 1.0
    public static let fastDuration: CFTimeInterval = 0.12

    /// Map |velocity| (detent-levels/sec) → duration, clamped to [fast, slow].
    public static func duration(velocity: CGFloat) -> CFTimeInterval {
        let v = Double(min(max(abs(velocity), 0), 6)) / 6   // 0 (still) … 1 (fast)
        return slowDuration + (fastDuration - slowDuration) * v
    }

    /// Eased progress 0→1 over `duration` (smoothstep — calm in/out, no spring).
    public static func progress(elapsed: CFTimeInterval, duration: CFTimeInterval) -> CGFloat {
        guard duration > 0 else { return 1 }
        let x = CGFloat(max(0, min(1, elapsed / duration)))
        return x * x * (3 - 2 * x)
    }
}
