// GridTransitionTuning.swift
//
// Centralized, tunable surface for the L0↔L1 single-presentation-lattice transition spike.
// EVERY value here is a TEMPORARY SPIKE CONSTANT derived from the V3.4 / V3.5 / V3.6 offline
// evidence passes (candidate CLICKV2_420_FULLER_CORNER). They are deliberately gathered in one
// place so duration / curve / window parameters can be fine-tuned after the spike WITHOUT any
// architecture rewrite. No constants for this transition live anywhere else.

import Foundation
import CoreGraphics

struct GridTransitionTuning: Equatable, Sendable {
    // ── click (toolbar / keyboard +/-) ──
    var clickDurationMs: Double = 420            // V3.6 chosen duration (420 best trade-off; 360 fallback)
    var clickRampFraction: Double = 0.20         // trapezoidal-velocity accel/decel fraction r/D
    var c1EdgeFraction: Double = 0.20            // C1 linear-core edge fraction a (s = 1/(1-a) = 1.25)

    // ── structural targets (validated by tests; NOT enforced by a per-frame optimizer) ──
    var minFocusInteriorSamples60: Int = 4       // cid0 focus ≥ 4 useful interior samples @60
    var minCornerInteriorSamples60: Int = 2      // cid5 corner ≥ 2 useful interior samples @60
    var maxSimultaneousPartialComponents: Int = 1

    // ── live pinch (PINCH071) ──
    var pinchWidthQ: Double = 0.0706             // W071 fixed handoff width in q-space
    var pinchFollowerOmegaN: Double = 27.8       // host-owned critically-damped follower (rad/s)

    // ── V3.9 continuous multi-level live-pinch scrub driver (PinchLiveZoomDriver) ──
    // The grid is one continuous scrub surface across detents: segmentQ follows the finger 1:1 within the
    // active adjacent interval; crossing a detent swaps the interval (seam-continuous); NO mid-gesture latch.
    // On release the active segment settles to its nearest detent (the SEPARATE release-commit threshold).
    var pinchReleaseCommitQ: Double = 0.50          // fingers-up: active segment ≥ ⇒ target detent, < ⇒ source
    var pinchAutoCompleteMinQPerSecond: Double = 1.8 // release-settle floor (never stalls)
    var pinchAutoCompleteMaxQPerSecond: Double = 8.0 // release-settle cap (no instant snap)
    var pinchVelocityEmaAlpha: Double = 0.25         // recent-velocity EMA weight
    var pinchDirectionResolveQ: Double = 0.02        // rest dead-band before the first segment engages
    var pinchDetentHysteresisQ: Double = 0.02        // hysteresis around a detent before the interval switches
    var pinchDisplayLowPassAlpha: Double = 1.0       // 1.0 = no smoothing (default); < 1 = light low-pass

    // ── window placement (click variable-window scheduler) ──
    var leadInFrames60: Int = 1                  // pure-source lead-in @60 (keeps first window off q=0)
    var leadOutFrames60: Int = 3                 // pure-target lead-out @60 (keeps last window < q=0.99)
    var edgeZoneLo: Double = 0.01                // no visible component compressed ONLY into [0, edgeZoneLo]
    var edgeZoneHi: Double = 0.99                // …or ONLY into [edgeZoneHi, 1]
    var minVisibleWindowWidthQ: Double = 0.035   // visible (≥2%) component window width floor
    var visibleAreaThresholdPct: Double = 2.0    // "visible" component peak-area threshold

    /// Reference refresh used to allocate the immutable plan (the harder rate; finer is smoother).
    var planRefreshHz: Double = 60

    static let `default` = GridTransitionTuning()

    var localAlphaCurve: LocalAlphaCurve { LocalAlphaCurve(edgeFraction: c1EdgeFraction) }
    var clickDurationSeconds: Double { clickDurationMs / 1000.0 }
}
