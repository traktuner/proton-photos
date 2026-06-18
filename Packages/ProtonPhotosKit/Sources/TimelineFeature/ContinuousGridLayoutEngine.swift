// ContinuousGridLayoutEngine.swift
//
// PURE, deterministic layout engine for the pinch-zoom (hard reset). NO AppKit, NO Metal.
//
// THE MODEL: there is ONE continuous grid world driven by a single `apparentCellSize`. The discrete zoom
// levels are SNAP/RESTING detents only — they are NOT the live rendering model. During an active pinch:
//   • column count is derived CONTINUOUSLY from apparentCellSize and changes ONE column at a time;
//   • the grid for a column count has FIXED doc-space rects (a uniform grid in stable asset order);
//   • a photo's screen rect is its fixed doc rect put through the GLOBAL zoom transform about the anchor
//     (`screenRect`) — a pure scale, NEVER `lerp(sourceRect, targetRect, progress)`;
//   • pinch-in and pinch-out are the identical computation (only which way apparentCellSize moves differs).
//
// At a column-count transition the two adjacent column layouts are alpha-crossfaded, each photo drawn at
// ITS OWN fixed layout rect — no photo frame ever travels from an old rect to a new rect.

import CoreGraphics

enum ContinuousGridLayoutEngine {

    /// A photo's fixed placement in a column-count layout (doc space).
    struct Cell: Equatable { let index: Int; let rect: CGRect }

    /// A full column-count layout: deterministic, fixed rects (no progress / no interpolation).
    struct Layout: Equatable {
        let columns: Int
        let cellSize: CGFloat
        let gap: CGFloat
        let rectByIndex: [Int: CGRect]
        let contentSize: CGSize
        func rect(of index: Int) -> CGRect? { rectByIndex[index] }
    }

    // MARK: - Continuous column count (detents are NOT used here)

    /// The IDEAL column count for a cell size — continuous in `apparentCellSize`, monotonically increasing
    /// as the cell shrinks, and (because it is a rounding of a monotone function) it changes by at most ONE
    /// column per threshold crossing. Driven ONLY by apparentCellSize, never by a snap level.
    static func columnCount(apparentCellSize: CGFloat, viewportWidth: CGFloat, gap: CGFloat,
                            minColumns: Int = 1, maxColumns: Int = 64) -> Int {
        let usable = max(viewportWidth + gap, 1)
        let c = Int((usable / max(apparentCellSize + gap, 1)).rounded())
        return min(max(c, minColumns), maxColumns)
    }

    /// Clamp a column-count change to ONE column per tick, so a fast pinch can never jump 5→12 columns in a
    /// single frame (the live path steps the rendered column count toward the ideal).
    static func steppedColumnCount(current: Int, ideal: Int) -> Int {
        if ideal > current { return current + 1 }
        if ideal < current { return current - 1 }
        return current
    }

    /// The cell size at which exactly `columns` columns fill the viewport (scale 1).
    static func naturalCellSize(columns: Int, viewportWidth: CGFloat, gap: CGFloat, insets: CGFloat) -> CGFloat {
        let cols = max(columns, 1)
        return max((viewportWidth - insets * 2 - gap * CGFloat(cols - 1)) / CGFloat(cols), 1)
    }

    // MARK: - Fixed layout for a column count

    /// A uniform grid for `assetCount` photos in stable order at `columns` columns. Doc space, fixed rects.
    static func layout(columns: Int, assetCount: Int, viewportWidth: CGFloat, gap: CGFloat, insets: CGFloat) -> Layout {
        let cols = max(columns, 1)
        let cell = naturalCellSize(columns: cols, viewportWidth: viewportWidth, gap: gap, insets: insets)
        var rects: [Int: CGRect] = [:]
        rects.reserveCapacity(assetCount)
        for i in 0..<max(assetCount, 0) {
            let col = i % cols, row = i / cols
            rects[i] = CGRect(x: insets + CGFloat(col) * (cell + gap),
                              y: CGFloat(row) * (cell + gap),
                              width: cell, height: cell)
        }
        let rows = cols > 0 ? (max(assetCount, 0) + cols - 1) / cols : 0
        let height = CGFloat(rows) * (cell + gap)
        return Layout(columns: cols, cellSize: cell, gap: gap, rectByIndex: rects, contentSize: CGSize(width: viewportWidth, height: height))
    }

    // MARK: - Global zoom transform about the anchor (NO rect interpolation)

    /// A photo's SCREEN rect: its fixed doc rect mapped by the global zoom transform that pins the anchor's
    /// doc point to the anchor's screen (cursor) point and scales by `scale`. This is a pure linear scale —
    /// it is NOT `lerp(sourceRect, targetRect, progress)`; the rect's identity is the one fixed layout rect.
    static func screenRect(docRect: CGRect, anchorDoc: CGPoint, anchorScreen: CGPoint, scale: CGFloat) -> CGRect {
        CGRect(x: anchorScreen.x + (docRect.minX - anchorDoc.x) * scale,
               y: anchorScreen.y + (docRect.minY - anchorDoc.y) * scale,
               width: docRect.width * scale, height: docRect.height * scale)
    }

    /// The live scale for a column count: how much its natural (scale-1) cells are stretched to show at the
    /// current `apparentCellSize`. scale 1 when apparentCellSize == that column count's natural cell size.
    static func scale(apparentCellSize: CGFloat, naturalCellSize: CGFloat) -> CGFloat {
        apparentCellSize / max(naturalCellSize, 1)
    }

    // MARK: - Column-transition crossfade (alpha only, fixed rects)

    /// During a column-count change, how visible the OUTGOING (current) vs INCOMING (stepped) layout is,
    /// as a function of where `apparentCellSize` sits between the two column counts' natural cell sizes.
    /// 0 = fully the current layout, 1 = fully the incoming layout. Each layout is drawn at ITS OWN fixed
    /// rects; only the alpha changes — no rect ever travels between them.
    static func transitionAlpha(apparentCellSize: CGFloat, currentNatural: CGFloat, incomingNatural: CGFloat) -> CGFloat {
        let span = currentNatural - incomingNatural
        guard abs(span) > 0.001 else { return 0 }
        let t = (currentNatural - apparentCellSize) / span
        return min(1, max(0, t))
    }

    /// Alpha for an INCOMING (next column count) node during a transition. Suppressed to 0 inside the focus
    /// band until late, so the focus row is never replaced by incoming items mid-pinch; outside the band it
    /// fades in with the transition.
    static func incomingNodeAlpha(inFocusBand: Bool, transitionAlpha t: CGFloat, focusHoldUntil: CGFloat = 0.85) -> CGFloat {
        if inFocusBand { return t <= focusHoldUntil ? 0 : (t - focusHoldUntil) / max(1 - focusHoldUntil, 0.0001) }
        return t
    }

    /// Alpha for an OUTGOING (current column count) node during a transition: the source layout fades out
    /// at its OWN fixed rects (focus row stays opaque until late via the incoming suppression above).
    static func outgoingNodeAlpha(transitionAlpha t: CGFloat) -> CGFloat { 1 - t }

    /// Which column layout(s) to render for the current `apparentCellSize`. BETWEEN column flips a SINGLE
    /// layout is rendered (it scales with the global transform — no second layer, no ghosting). Only inside
    /// a NARROW band around a column-flip threshold is the adjacent layout crossfaded in (alpha only, fixed
    /// rects). This keeps the wall coherent and the per-photo replacement brief, exactly at the column change.
    /// `incomingAlpha` reaches 1 right at the flip so the new layout is already dominant when the count flips.
    static func renderColumns(apparentCellSize a: CGFloat, viewportWidth W: CGFloat, gap: CGFloat,
                              bandFraction: CGFloat = 0.18, minColumns: Int = 1, maxColumns: Int = 64)
        -> (primary: Int, secondary: Int?, incomingAlpha: CGFloat) {
        let K = columnCount(apparentCellSize: a, viewportWidth: W, gap: gap, minColumns: minColumns, maxColumns: maxColumns)
        let aLow = (W + gap) / (CGFloat(K) + 0.5) - gap    // `a` dropping below this flips K → K+1
        let aHigh = (W + gap) / (CGFloat(K) - 0.5) - gap   // `a` rising above this flips K → K-1
        // Band is a fraction of THIS count's inter-flip RANGE (not the cell size), so the crossfade is a
        // fixed slice of every transition regardless of density — single layout for the middle ~64%.
        let band = max((aHigh - aLow) * bandFraction, 0.25)
        if K < maxColumns, a - aLow < band {               // near the zoom-out flip → crossfade K with K+1
            return (K, K + 1, min(1, max(0, (band - (a - aLow)) / band)))
        }
        if K > minColumns, aHigh - a < band {              // near the zoom-in flip → crossfade K with K-1
            return (K, K - 1, min(1, max(0, (band - (aHigh - a)) / band)))
        }
        return (K, nil, 0)                                 // between flips: ONE layout, just scaling
    }

    // ════════════════════════════════════════════════════════════════════════════════════════════════════
    // MARK: - V2: Continuous day-sectioned wall + TIME-BASED topology rebase (replaces the position-band model)
    //
    // The position-band `renderColumns` above is the rejected "bracket" model: near a flip it rests at a
    // PERSISTENT blend of two layouts (a ghost wall) as a function of where `apparent` sits. V2 instead holds
    // ONE topology (one continuous, cursor-anchored, day-sectioned layout) and fires a SHORT, time-clocked
    // rebase EVENT only when the column count / crop actually steps — then collapses back to one layout.
    // This decision core is pure and deterministic (time is an explicit `now` parameter) so it is fully unit
    // testable and identical for pinch-in and pinch-out.
    // ════════════════════════════════════════════════════════════════════════════════════════════════════

    /// The identity of "which wall are we on". A change in ANY field is a topology boundary requiring a rebase.
    struct Topology: Equatable {
        var columns: Int
        var gap: CGFloat
        var cropSquare: Bool
    }

    /// An in-flight topology rebase: a time-clocked alpha dissolve from `from`→`to`. `to` is FROZEN at start
    /// (a paused finger still converges to it); it is never re-aimed mid-flight (no thrash, no never-complete).
    struct Rebase: Equatable {
        var from: Topology
        var to: Topology
        var startTime: Double
        var duration: Double
    }

    /// What to render THIS tick.
    enum RebasePlan: Equatable {
        case single(Topology)                       // one cursor-anchored layout, alpha 1 (the common case)
        case rebasing(Rebase, alpha: CGFloat)       // two layouts: `from` fading out, `to` fading in (alpha = t)
    }

    /// Full result of the per-tick decision: what to draw + the updated state machine.
    struct PlanResult: Equatable {
        var plan: RebasePlan
        var live: Topology          // the topology we are now "on" (== rebase.to while rebasing)
        var active: Rebase?         // nil unless a rebase is in flight
        var started: Bool           // true ONLY on the tick a NEW rebase begins (caller arms the self-clock)
    }

    /// The `apparent` values at which the CURRENT column count K flips. `a` below `flipDown` → K+1 (more,
    /// smaller cells); `a` above `flipUp` → K-1 (fewer, larger cells). Symmetric half-integer thresholds — the
    /// SAME for pinch-in and pinch-out (no hysteresis), so the column count stays a pure function of apparent.
    static func flipThresholds(columns K: Int, viewportWidth W: CGFloat, gap: CGFloat) -> (down: CGFloat, up: CGFloat) {
        let down = (W + gap) / (CGFloat(K) + 0.5) - gap
        let up = (W + gap) / (CGFloat(K) - 0.5) - gap
        return (down, up)
    }

    /// Time→alpha for a rebase: smoothstep over [0,1]. `t` is the FROM→TO progress; the from layer shows
    /// `rebaseOutgoingAlpha`, the to layer `rebaseIncomingAlpha`. The two curves overlap only briefly so a
    /// non-focus column dissolve reads as a whoosh, not a long double-image.
    static func rebaseProgress(elapsed: Double, duration: Double) -> CGFloat {
        guard duration > 0 else { return 1 }
        let raw = CGFloat(min(1, max(0, elapsed / duration)))
        return raw * raw * (3 - 2 * raw)
    }

    private static func smooth01(_ x: CGFloat) -> CGFloat {
        let c = min(1, max(0, x)); return c * c * (3 - 2 * c)
    }

    /// FROM (outgoing) layer alpha: full until 0.55, gone by 1.0 — front-loaded so the old wall is mostly
    /// solid while the new one is still faint (minimises the overlapping-double-image window).
    static func rebaseOutgoingAlpha(_ t: CGFloat) -> CGFloat { 1 - smooth01((t - 0.45) / 0.55) }

    /// TO (incoming) layer alpha: suppressed in the focus band until very late (focus row never replaced
    /// early), otherwise fades in over the back half.
    static func rebaseIncomingAlpha(inFocusBand: Bool, t: CGFloat, focusHoldUntil: CGFloat = 0.85) -> CGFloat {
        if inFocusBand { return t <= focusHoldUntil ? 0 : smooth01((t - focusHoldUntil) / (1 - focusHoldUntil)) }
        return smooth01((t - 0.45) / 0.55)
    }

    /// Painter's z-key for the flat slot page (array order == z; later == front). Non-focus rows draw first,
    /// then the focus row, then the anchor LAST — so the anchor photo is always the topmost quad under the
    /// cursor and the focus row is never overdrawn by the other topology's cells (the anchor-topmost invariant).
    static func zKey(isAnchor: Bool, inFocusBand: Bool) -> Int {
        if isAnchor { return 2 }
        return inFocusBand ? 1 : 0
    }

    /// THE per-tick V2 decision (pure). Given the live topology, any in-flight rebase, and the ideal topology
    /// for the current `apparent`, decide what to render and how the state machine advances. Encodes every
    /// blocker from the design attack:
    ///   • self-clock convergence — when `now` passes the rebase end the rebase CLEARS to `single(to)` even
    ///     with no change in `apparent` (the caller drives this via its own tick; the math lives here);
    ///   • no-restart-while-active — a new boundary crossing does NOT start a second rebase until the current
    ///     one finishes (the `to` is frozen → no thrash, always completes);
    ///   • symmetric dead-band trigger — a fresh rebase starts only once `apparent` is past the flip (or crop)
    ///     threshold by `jitterEpsilon`, killing threshold jitter WITHOUT making the count direction-dependent;
    ///   • one-column-at-a-time — `to.columns` steps by at most one (a fast pinch rebases sequentially);
    ///   • crop-only rebase — when only the crop flips (same column count) the rects are identical, so it is a
    ///     pure alpha crop dissolve (no movement at all).
    static func planTick(apparent a: CGFloat,
                         viewportWidth W: CGFloat,
                         live: Topology,
                         idealColumns: Int,
                         idealCropSquare: Bool,
                         steppedGap: CGFloat,
                         cropThreshold: CGFloat,
                         jitterEpsilon: CGFloat,
                         active: Rebase?,
                         now: Double,
                         duration: Double) -> PlanResult {
        // 1. A rebase is in flight: keep it (frozen target) until wall-clock passes its end. NEVER re-aim it.
        if let r = active {
            let elapsed = now - r.startTime
            if elapsed < r.duration {
                return PlanResult(plan: .rebasing(r, alpha: rebaseProgress(elapsed: elapsed, duration: r.duration)),
                                  live: r.to, active: r, started: false)
            }
            // Converged: collapse to the single destination topology (this fires even with no `apparent` change).
            return PlanResult(plan: .single(r.to), live: r.to, active: nil, started: false)
        }

        // 2. No rebase. If the ideal topology equals the live one, just render the single continuous layout.
        let stepped = steppedColumnCount(current: live.columns, ideal: idealColumns)
        let cropChanged = idealCropSquare != live.cropSquare
        let columnsChanged = stepped != live.columns
        if !columnsChanged && !cropChanged {
            return PlanResult(plan: .single(live), live: live, active: nil, started: false)
        }

        // 3. A boundary differs — but only COMMIT past a symmetric dead-band (kills jitter; no hysteresis on
        //    the count itself, only on WHEN a transition is allowed to begin).
        if columnsChanged {
            let (down, up) = flipThresholds(columns: live.columns, viewportWidth: W, gap: live.gap)
            let threshold = idealColumns > live.columns ? down : up   // crossing toward more / fewer columns
            guard abs(a - threshold) > jitterEpsilon else {
                return PlanResult(plan: .single(live), live: live, active: nil, started: false)
            }
        } else { // crop-only boundary
            guard abs(a - cropThreshold) > jitterEpsilon else {
                return PlanResult(plan: .single(live), live: live, active: nil, started: false)
            }
        }

        // 4. Start ONE rebase. Step columns by ≤1; only change crop when columns are NOT changing (so a column
        //    rebase and a crop rebase never compound — the crop follows on a later tick). The crop-only case
        //    keeps the same column count and gap → identical rects → pure alpha dissolve.
        let to = Topology(columns: stepped,
                          gap: columnsChanged ? steppedGap : live.gap,
                          cropSquare: columnsChanged ? live.cropSquare : idealCropSquare)
        let r = Rebase(from: live, to: to, startTime: now, duration: duration)
        return PlanResult(plan: .rebasing(r, alpha: 0), live: to, active: r, started: true)
    }
}

/// The spec's name for the shared pure engine (overlay AND committed layout resolve geometry through it).
typealias ContinuousDaySectionedGridLayoutEngine = ContinuousGridLayoutEngine
