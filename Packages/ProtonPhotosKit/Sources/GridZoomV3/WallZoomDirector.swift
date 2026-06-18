// WallZoomDirector.swift  —  GridZoomV3 Lab (Phases 3, 5, 6, 7 — pure decision core)
//
// PURE, deterministic. NO AppKit. Takes wall-clock `now` as an explicit parameter so the topology-rebase
// state machine is fully unit-testable. This is the "what should we render this tick" brain; the AppKit
// renderer is a thin driver around it.
//
// Detents are the SIX resting zoom levels. They are SNAP TARGETS ONLY: they never feed live `.changed`
// geometry (that is driven purely by `apparentCellSize` through ContinuousPhotoWallLayoutEngine). On
// release the director picks the nearest detent and the renderer eases `apparentCellSize` to it along the
// exact same continuous layout path (DetentSettleSamePath).

import CoreGraphics

public enum WallZoomDirector {

    // MARK: - Detents (the six resting levels)

    /// A resting level: a column count + the crop mode it rests at. Its resting `apparentCellSize` is the
    /// cell side that makes `columns` columns exactly fill the usable width, using the SAME `liveGap` the
    /// gesture uses — so the live `columnCount` resolves to exactly this detent's column count at rest
    /// (the committed grid matches the gesture). The gap is NOT a detent property: it is a continuous
    /// function of cell size shared by every code path.
    public struct Detent: Equatable, Sendable {
        public let columns: Int
        public let cropSquare: Bool
        public init(columns: Int, cropSquare: Bool) { self.columns = columns; self.cropSquare = cropSquare }
    }

    /// Six Apple-like density levels: four aspect-fit (gapped, large) then two square-fill (near-gapless,
    /// dense). Column counts are illustrative for the prototype; the model is independent of the exact set.
    public static let defaultDetents: [Detent] = [
        Detent(columns: 3,  cropSquare: false),
        Detent(columns: 5,  cropSquare: false),
        Detent(columns: 7,  cropSquare: false),
        Detent(columns: 10, cropSquare: false),
        Detent(columns: 16, cropSquare: true),
        Detent(columns: 26, cropSquare: true),
    ]

    /// The resting `apparentCellSize` of a detent: the cell that makes `columns` columns exactly fill,
    /// solved by fixed-point because the gap itself depends on the cell (`liveGap`). Converges in a few
    /// iterations; the result satisfies `columnCount(detentApparent) == columns`.
    public static func detentApparent(_ d: Detent, viewportWidth: CGFloat, contentInset: CGFloat) -> CGFloat {
        var a = ContinuousPhotoWallLayoutEngine.fillCellSize(columns: d.columns, viewportWidth: viewportWidth,
                                                             gap: 6, contentInset: contentInset)
        for _ in 0..<6 {
            a = ContinuousPhotoWallLayoutEngine.fillCellSize(columns: d.columns, viewportWidth: viewportWidth,
                                                             gap: liveGap(apparentCellSize: a), contentInset: contentInset)
        }
        return max(a, 1)
    }

    /// The clamp range for the live wall: never breathe past the largest detent's cell or below the
    /// smallest, so the gesture stays inside the modelled density band.
    public static func apparentBounds(detents: [Detent], viewportWidth: CGFloat, contentInset: CGFloat) -> ClosedRange<CGFloat> {
        let sizes = detents.map { detentApparent($0, viewportWidth: viewportWidth, contentInset: contentInset) }
        let lo = sizes.min() ?? 1, hi = sizes.max() ?? 1
        return min(lo, hi)...max(lo, hi)
    }

    // MARK: - Live gap & crop (continuous functions of apparentCellSize — NOT detent lookups)

    /// Gap grows with the cell so large levels breathe with air and dense levels are near-gapless.
    /// Continuous in `apparentCellSize` (no per-detent step ⇒ no gap pop while breathing).
    public static func liveGap(apparentCellSize: CGFloat) -> CGFloat {
        min(max(apparentCellSize * 0.045, 1), 14)
    }

    /// Crop mode flips to squareFill once the cell is smaller than the boundary between the last aspect
    /// detent and the first square detent — a single threshold, so the change is a discrete topology/crop
    /// boundary (handled by a rebase), never a gradual morph.
    public static func squareCropThreshold(detents: [Detent], viewportWidth: CGFloat, contentInset: CGFloat) -> CGFloat {
        // boundary = midpoint between the largest squareFill detent's cell and the smallest aspectFit one.
        let squares = detents.filter { $0.cropSquare }
        let aspects = detents.filter { !$0.cropSquare }
        let largestSquare = squares.map { detentApparent($0, viewportWidth: viewportWidth, contentInset: contentInset) }.max()
        let smallestAspect = aspects.map { detentApparent($0, viewportWidth: viewportWidth, contentInset: contentInset) }.min()
        switch (largestSquare, smallestAspect) {
        case let (s?, a?): return (s + a) / 2
        case let (s?, nil): return s
        case let (nil, a?): return a
        default: return 0
        }
    }

    public static func liveCropSquare(apparentCellSize: CGFloat, threshold: CGFloat) -> Bool {
        apparentCellSize < threshold
    }

    public static func liveCropMode(apparentCellSize: CGFloat, threshold: CGFloat) -> WallCropMode {
        liveCropSquare(apparentCellSize: apparentCellSize, threshold: threshold) ? .squareFill : .aspectFit
    }

    // MARK: - Release snap (detents are RELEASE-ONLY)

    /// Pick the detent to settle to. Nearest by cell size (log space, so density steps feel even) with a
    /// velocity bias toward the direction the pinch was still moving. NEVER consulted during `.changed`.
    public static func snapDetentIndex(apparentCellSize a: CGFloat,
                                       velocity: CGFloat,          // d(apparentCellSize)/dt, signed
                                       detents: [Detent],
                                       viewportWidth: CGFloat,
                                       contentInset: CGFloat) -> Int {
        guard !detents.isEmpty else { return 0 }
        let sizes = detents.map { detentApparent($0, viewportWidth: viewportWidth, contentInset: contentInset) }
        // bias the effective size slightly along the velocity so a fast fling carries to the next detent.
        let biased = max(a + velocity * 0.06, 1)
        func logDist(_ x: CGFloat, _ y: CGFloat) -> CGFloat { abs(log(max(x, 1)) - log(max(y, 1))) }
        var best = 0, bestD = CGFloat.greatestFiniteMagnitude
        for (i, s) in sizes.enumerated() {
            let d = logDist(biased, s)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    // MARK: - Topology + rebase state machine (Phase 5)

    /// "Which wall are we on." A change in ANY field is a topology boundary that needs a short alpha rebase.
    public struct Topology: Equatable, Sendable {
        public var columns: Int
        public var cropSquare: Bool
        public init(columns: Int, cropSquare: Bool) { self.columns = columns; self.cropSquare = cropSquare }
    }

    /// An in-flight, time-clocked alpha dissolve from `from`→`to`. `to` is FROZEN at start (a paused finger
    /// still converges); `fromApparent` freezes the outgoing wall's cell so it can't overflow while fading.
    public struct Rebase: Equatable, Sendable {
        public var from: Topology
        public var to: Topology
        public var fromApparent: CGFloat
        public var startTime: Double
        public var duration: Double
    }

    /// What to render this tick.
    public enum Plan: Equatable, Sendable {
        case single(Topology)
        case rebasing(Rebase, progress: CGFloat)   // progress 0→1 (smoothstepped), from fades out, to fades in
    }

    public struct PlanResult: Equatable, Sendable {
        public var plan: Plan
        public var live: Topology      // the topology we are now on (== rebase.to while rebasing)
        public var active: Rebase?
        public var started: Bool       // true only on the tick a NEW rebase begins (caller arms the self-clock)
    }

    /// Step a column count toward the ideal by at most ONE — a fast pinch rebases sequentially, never jumps.
    public static func steppedColumns(current: Int, ideal: Int) -> Int {
        if ideal > current { return current + 1 }
        if ideal < current { return current - 1 }
        return current
    }

    /// The cell sizes at which the CURRENT column count K flips. `a` below `down` ⇒ K+1; above `up` ⇒ K-1.
    /// Symmetric half-integer thresholds — identical for pinch-in and pinch-out (no hysteresis on the count).
    public static func flipThresholds(columns K: Int, viewportWidth W: CGFloat, gap: CGFloat,
                                      contentInset: CGFloat) -> (down: CGFloat, up: CGFloat) {
        let usable = max(W - 2 * contentInset, 1)
        let down = (usable + gap) / (CGFloat(K) + 0.5) - gap
        let up = (usable + gap) / (CGFloat(K) - 0.5) - gap
        return (down, up)
    }

    public static func smoothstep(_ x: CGFloat) -> CGFloat {
        let c = min(1, max(0, x)); return c * c * (3 - 2 * c)
    }

    public static func rebaseProgress(elapsed: Double, duration: Double) -> CGFloat {
        guard duration > 0 else { return 1 }
        return smoothstep(CGFloat(min(1, max(0, elapsed / duration))))
    }

    /// Per-tick decision (pure). Encodes the spec's rebase rules:
    ///   • self-clock convergence — once `now` passes the rebase end it collapses to `single(to)` even with
    ///     no further `apparent` change (the caller drives the tick; the math lives here);
    ///   • no-restart-while-active — a new boundary does NOT start a second rebase until the current ends
    ///     (frozen `to` ⇒ no thrash, always completes);
    ///   • symmetric dead-band — a fresh rebase begins only once `apparent` is past the flip/crop threshold
    ///     by `jitterEpsilon` (kills jitter WITHOUT making the count direction-dependent);
    ///   • one-column-at-a-time, and crop-only ⇒ identical rects ⇒ pure alpha crop dissolve.
    public static func planTick(apparent a: CGFloat,
                                viewportWidth W: CGFloat,
                                contentInset: CGFloat,
                                live: Topology,
                                liveGap: CGFloat,
                                idealColumns: Int,
                                idealCropSquare: Bool,
                                jitterEpsilon: CGFloat,
                                cropThreshold: CGFloat,
                                active: Rebase?,
                                now: Double,
                                duration: Double) -> PlanResult {
        // 1. A rebase is in flight — keep it (frozen target) until wall-clock passes its end. Never re-aim.
        if let r = active {
            let elapsed = now - r.startTime
            if elapsed < r.duration {
                return PlanResult(plan: .rebasing(r, progress: rebaseProgress(elapsed: elapsed, duration: r.duration)),
                                  live: r.to, active: r, started: false)
            }
            return PlanResult(plan: .single(r.to), live: r.to, active: nil, started: false)
        }

        // 2. No rebase. If the ideal topology equals the live one, render the single continuous layout.
        let stepped = steppedColumns(current: live.columns, ideal: idealColumns)
        let columnsChanged = stepped != live.columns
        let cropChanged = idealCropSquare != live.cropSquare
        if !columnsChanged && !cropChanged {
            return PlanResult(plan: .single(live), live: live, active: nil, started: false)
        }

        // 3. A boundary differs — commit only once `apparent` is past it by a symmetric dead-band.
        if columnsChanged {
            let (down, up) = flipThresholds(columns: live.columns, viewportWidth: W, gap: liveGap, contentInset: contentInset)
            let threshold = idealColumns > live.columns ? down : up
            guard abs(a - threshold) > jitterEpsilon else {
                return PlanResult(plan: .single(live), live: live, active: nil, started: false)
            }
        } else {
            guard abs(a - cropThreshold) > jitterEpsilon else {
                return PlanResult(plan: .single(live), live: live, active: nil, started: false)
            }
        }

        // 4. Start ONE rebase. Step columns by ≤1; only flip crop when columns are NOT changing (so a column
        //    rebase and a crop rebase never compound). Crop-only keeps the same columns ⇒ identical rects.
        let to = Topology(columns: stepped,
                          cropSquare: columnsChanged ? live.cropSquare : idealCropSquare)
        let r = Rebase(from: live, to: to, fromApparent: a, startTime: now, duration: duration)
        return PlanResult(plan: .rebasing(r, progress: 0), live: to, active: r, started: true)
    }

    // MARK: - Per-node alpha during a rebase (focus row protected; anchor never replaced early)

    /// Outgoing (from) node alpha: solid until ~0.45, gone by 1.0 — front-loaded so the old wall stays
    /// mostly opaque while the new one is faint (minimises the double-image window).
    public static func outgoingAlpha(progress t: CGFloat) -> CGFloat {
        1 - smoothstep((t - 0.45) / 0.55)
    }

    /// Incoming (to) node alpha. In the focus band it is held at 0 until very late (the focus row is never
    /// replaced mid-pinch); elsewhere it fades in over the back half.
    public static func incomingAlpha(progress t: CGFloat, inFocusBand: Bool, focusHoldUntil: CGFloat = 0.85) -> CGFloat {
        if inFocusBand {
            return t <= focusHoldUntil ? 0 : smoothstep((t - focusHoldUntil) / (1 - focusHoldUntil))
        }
        return smoothstep((t - 0.45) / 0.55)
    }

    /// Half-height of the protected focus band (screen space), centred on the cursor.
    public static func focusBandHalfHeight(viewportHeight: CGFloat, fraction: CGFloat = 0.18) -> CGFloat {
        viewportHeight * fraction
    }

    public static func inFocusBand(screenY: CGFloat, anchorScreenY: CGFloat, viewportHeight: CGFloat) -> Bool {
        abs(screenY - anchorScreenY) <= focusBandHalfHeight(viewportHeight: viewportHeight)
    }

    /// Painter's z so the anchor is always the topmost quad under the cursor and the focus row is never
    /// overdrawn by the other topology (anchor-topmost invariant). Higher = front.
    public static func zKey(isAnchor: Bool, inFocusBand: Bool) -> Int {
        if isAnchor { return 2 }
        return inFocusBand ? 1 : 0
    }
}
