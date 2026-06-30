// PinchLiveZoomDriver.swift
//
// V3.9 CONTINUOUS MULTI-LEVEL live-pinch driver for the single-presentation-lattice transition. PURE +
// headless: no clock, no engine, no GPU, no UserDefaults — every time step is passed in as `dt`, so the
// whole state machine is unit-testable in isolation.
//
// Apple Photos lets the user pinch continuously through MANY levels in one uninterrupted gesture (smallest
// → largest) without lifting. V3.8 handled only ONE adjacent pair per gesture (capture latched, then you had
// to lift and re-pinch). V3.9 makes the grid one continuous scrub surface across detents:
//
//   • The physical pinch position (`continuousLevel`, level units across the ladder) is AUTHORITATIVE.
//   • The active SEGMENT is the adjacent detent interval the position is in: `[floor(x), floor(x)+1]`,
//     source = the denser (higher-index) end, target = the larger-tile (lower-index) end.
//   • `segmentQ = (floor(x)+1) − x` ∈ [0,1] is the scrub position INSIDE that interval (1:1 with the finger).
//   • Crossing an integer detent swaps the active interval; a small hysteresis prevents thrash at a detent.
//     The previous interval at q=1 and the next at q=0 are the SAME detent ⇒ the host's per-detent plan frames
//     are identical there ⇒ a continuous seam (no blank frame, no commit bridge, no snap between segments).
//   • There is NO mid-gesture capture/latch that ends the gesture (that was V3.8's "settle + re-pinch"); the
//     grid follows the finger until release, then settles the ACTIVE segment to its nearest detent.
//
// The driver chains only within the eligible band `[chainLo, chainHi]` (the contiguous focusRowRelayout run
// the gesture started in — the normal levels L0–L3); the host decides lattice-vs-reflow up front and clamps
// the position into the band, so an out-of-band (overview) excursion holds at the boundary detent.

import CoreGraphics

struct PinchLiveZoomDriver: Equatable, Sendable {

    struct Tunables: Equatable, Sendable {
        /// Release decision (fingers up): the active segment settles to its target if `segmentQ ≥` this, else
        /// back to its source — i.e. the nearest detent to the global position.
        var releaseCommitQ: Double = 0.50
        /// Settle ramp speed floor / cap (q per second) — never stalls, never an instant snap.
        var autoCompleteMinQPerSecond: Double = 1.8
        var autoCompleteMaxQPerSecond: Double = 8.0
        /// A very short directional pinch that never clears the live-scrub dead-band should still behave like
        /// a discrete +/- step: complete one adjacent segment at the accepted click duration.
        var shortStepQPerSecond: Double = 1000.0 / 420.0
        /// EMA weight for the recent pinch velocity (drives the settle speed). 0…1.
        var velocityEmaAlpha: Double = 0.25
        /// |continuousLevel − startLevel| (level units) needed before the first segment engages (rest dead-band).
        var directionResolveQ: Double = 0.02
        /// Hysteresis (level units) around an integer detent before the active interval switches — prevents
        /// rebuild thrash when the finger holds right on a detent.
        var detentHysteresisQ: Double = 0.02
        /// Low-pass on `segmentQ`. 1.0 = pass-through (DEFAULT — exact 1:1, no lag); < 1 = light filter.
        var displayQLowPassAlpha: Double = 1.0

        init() {}
        init(from t: GridTransitionTuning) {
            releaseCommitQ = t.pinchReleaseCommitQ
            autoCompleteMinQPerSecond = t.pinchAutoCompleteMinQPerSecond
            autoCompleteMaxQPerSecond = t.pinchAutoCompleteMaxQPerSecond
            shortStepQPerSecond = 1000.0 / max(1.0, t.clickDurationMs)
            velocityEmaAlpha = t.pinchVelocityEmaAlpha
            directionResolveQ = t.pinchDirectionResolveQ
            detentHysteresisQ = t.pinchDetentHysteresisQ
            displayQLowPassAlpha = t.pinchDisplayLowPassAlpha
        }
    }

    enum Phase: Equatable, Sendable {
        case idle
        case scrub          // fingers down, segmentQ follows the finger 1:1 across detents
        case settling       // fingers up, velocity-aware ramp of the active segment to its nearest detent
        case committed      // terminal: landed on `finalLevel`
    }

    /// What the host needs after a live sample: the active adjacent segment + its scrub position.
    struct Update: Equatable {
        var segmentSource: Int     // denser (higher index) interval end ⇒ shown at segmentQ = 0
        var segmentTarget: Int     // larger-tile (lower index) end     ⇒ shown at segmentQ = 1
        var segmentQ: Double
        var hasSegment: Bool       // false before the first move clears the rest dead-band
    }

    private(set) var phase: Phase = .idle
    private(set) var startLevel = 0
    private(set) var chainLo = 0
    private(set) var chainHi = 0
    private(set) var seg = 0                // current interval index: active interval = [seg, seg+1]
    private(set) var segmentQ: Double = 0
    private(set) var directionResolved = false
    private(set) var velocityQPerSecond: Double = 0
    private(set) var settleTargetQ: Double = 1
    private(set) var finalLevel = 0        // the detent the gesture lands on (set on commit)
    private(set) var chainable = false     // false for a degenerate band (lo == hi) ⇒ driver stays inert

    private var lastX: Double = 0

    var tuning = Tunables()

    init(tuning: Tunables = Tunables()) { self.tuning = tuning }

    var segmentSource: Int { seg + 1 }
    var segmentTarget: Int { seg }
    var isActive: Bool { phase == .scrub || phase == .settling }
    var isSelfAdvancing: Bool { phase == .settling }   // only the post-release settle self-advances (no capture)
    var isCommitted: Bool { phase == .committed }

    /// Begin a chaining gesture on `startLevel`, bounded to the eligible band `[chainLo, chainHi]` (the host's
    /// contiguous focusRowRelayout run). The first interval brackets `startLevel`; the start detent is shown
    /// until the finger clears the rest dead-band.
    mutating func begin(startLevel: Int, chainLo: Int, chainHi: Int) {
        self.startLevel = startLevel
        self.chainLo = min(chainLo, startLevel)
        self.chainHi = max(chainHi, startLevel)
        chainable = self.chainHi > self.chainLo                      // a degenerate band has no adjacent interval
        seg = min(max(self.chainLo, startLevel), max(self.chainLo, self.chainHi - 1))   // interval containing startLevel (clamped in-band)
        segmentQ = chainable ? Double(seg + 1) - Double(startLevel) : 0   // 0 if start is the source end, 1 if target
        directionResolved = false
        velocityQPerSecond = 0
        settleTargetQ = 1
        finalLevel = startLevel
        lastX = Double(startLevel)
        phase = .scrub
    }

    /// Feed a live pinch sample. Picks the active interval from the (band-clamped) position with detent
    /// hysteresis, and sets `segmentQ` 1:1. Returns the active segment for the host to (re)build + scrub.
    @discardableResult
    mutating func update(continuousLevel rawX: Double, dt: Double) -> Update {
        guard phase == .scrub, chainable else {                    // degenerate band ⇒ inert (host routes to reflow)
            return Update(segmentSource: segmentSource, segmentTarget: segmentTarget, segmentQ: segmentQ, hasSegment: directionResolved && chainable)
        }
        let x = min(Double(chainHi), max(Double(chainLo), rawX))   // can't chain past the eligible band

        // recent pinch velocity from the GLOBAL position (continuous across detent crossings, unlike segmentQ).
        if dt > 1e-6 {
            let inst = abs(x - lastX) / dt
            velocityQPerSecond += tuning.velocityEmaAlpha * (inst - velocityQPerSecond)
        }
        lastX = x

        if !directionResolved {
            if abs(x - Double(startLevel)) < tuning.directionResolveQ {
                // rest dead-band: hold the start detent, no segment engaged yet
                return Update(segmentSource: segmentSource, segmentTarget: segmentTarget, segmentQ: segmentQ, hasSegment: false)
            }
            directionResolved = true
        }

        // Move the active interval toward x with hysteresis, one detent at a time (handles a fast multi-level
        // flick: x can jump several intervals in one update).
        let segBefore = seg
        var guardIter = 0
        while seg > chainLo, Double(seg) - x > tuning.detentHysteresisQ { seg -= 1; guardIter += 1; if guardIter > 64 { break } }
        while seg < chainHi - 1, x - Double(seg + 1) > tuning.detentHysteresisQ { seg += 1; guardIter += 1; if guardIter > 64 { break } }

        let rawQ = min(1, max(0, Double(seg + 1) - x))
        let a = tuning.displayQLowPassAlpha
        // The low-pass carries state, so it MUST reset on an interval swap: across a crossing rawQ jumps from
        // ~1 (old segment's target detent) to ~0 (new segment's source detent), and a smeared value would
        // bypass the shared-detent seam. So snap to rawQ on a crossing (and at the pass-through default).
        segmentQ = (a >= 1 || seg != segBefore) ? rawQ : (a * rawQ + (1 - a) * segmentQ)
        return Update(segmentSource: segmentSource, segmentTarget: segmentTarget, segmentQ: segmentQ, hasSegment: true)
    }

    /// Advance the post-release settle on the driver's own clock. No-op while scrubbing (a still finger keeps
    /// the grid still). Speed respects recent pinch velocity, clamped to [min, max] q/s.
    @discardableResult
    mutating func advance(dt: Double) -> Double {
        guard dt > 0, phase == .settling else { return segmentQ }
        let speed = max(tuning.autoCompleteMinQPerSecond, min(tuning.autoCompleteMaxQPerSecond, velocityQPerSecond))
        if segmentQ < settleTargetQ { segmentQ = min(settleTargetQ, segmentQ + speed * dt) }
        else if segmentQ > settleTargetQ { segmentQ = max(settleTargetQ, segmentQ - speed * dt) }
        if abs(segmentQ - settleTargetQ) <= 1e-6 {
            segmentQ = settleTargetQ
            finalLevel = settleTargetQ >= 0.5 ? segmentTarget : segmentSource
            phase = .committed
        }
        return segmentQ
    }

    /// Fingers up. Settle the ACTIVE segment to its nearest detent (by the global position, via `segmentQ`).
    /// Returns the detent the gesture will land on. No hard snap; velocity-aware ramp in `advance`.
    @discardableResult
    mutating func release(cancelled: Bool = false) -> Int {
        guard phase == .scrub else { return finalLevel }
        // cancelled gestures also settle to nearest (graceful) — there is no abrupt revert.
        _ = cancelled
        if !directionResolved {
            settleTargetQ = segmentQ      // never moved ⇒ stay on the start detent
            finalLevel = startLevel
        } else if segmentQ >= tuning.releaseCommitQ {
            settleTargetQ = 1
            finalLevel = segmentTarget
        } else {
            settleTargetQ = 0
            finalLevel = segmentSource
        }
        phase = .settling
        return finalLevel
    }

    /// A sub-dead-band but directional pinch should not be inert. Seed the adjacent segment at the start
    /// detent, then run the normal post-release settle toward that direction at click-like speed.
    /// `direction < 0` means toward lower levels (larger thumbnails / pinch-in); `direction > 0` means toward
    /// higher levels (denser thumbnails / pinch-out).
    @discardableResult
    mutating func releaseTowardAdjacent(direction: Int, cancelled: Bool = false) -> Update {
        guard phase == .scrub, chainable, !cancelled else {
            _ = release(cancelled: cancelled)
            return Update(segmentSource: segmentSource, segmentTarget: segmentTarget, segmentQ: segmentQ, hasSegment: false)
        }
        let step = direction < 0 ? -1 : (direction > 0 ? 1 : 0)
        guard step != 0 else {
            _ = release(cancelled: cancelled)
            return Update(segmentSource: segmentSource, segmentTarget: segmentTarget, segmentQ: segmentQ, hasSegment: false)
        }
        let target = startLevel + step
        guard target >= chainLo, target <= chainHi else {
            _ = release(cancelled: cancelled)
            return Update(segmentSource: segmentSource, segmentTarget: segmentTarget, segmentQ: segmentQ, hasSegment: false)
        }

        if step < 0 {
            // Interval [target, startLevel]: startLevel is the source end (q=0), target is q=1.
            seg = target
            segmentQ = 0
            settleTargetQ = 1
        } else {
            // Interval [startLevel, target]: startLevel is the target end (q=1), target is q=0.
            seg = startLevel
            segmentQ = 1
            settleTargetQ = 0
        }
        directionResolved = true
        finalLevel = target
        velocityQPerSecond = max(velocityQPerSecond, tuning.shortStepQPerSecond)
        phase = .settling
        return Update(segmentSource: segmentSource, segmentTarget: segmentTarget, segmentQ: segmentQ, hasSegment: true)
    }

    mutating func reset() { self = PinchLiveZoomDriver(tuning: tuning) }
}
