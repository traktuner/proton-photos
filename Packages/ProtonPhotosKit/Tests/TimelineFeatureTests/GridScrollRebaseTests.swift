import Testing
import Foundation
import CoreGraphics
import GridCore
@testable import TimelineFeature

/// The edge/corner scroll rebase must be a short, monotonic, no-bounce slide that ends EXACTLY at the legal
/// settled scroll - never an instant jump, and a no-op for normal (in-bounds) commits.
@Suite struct GridScrollRebaseTests {

    // (2) Armed only when the gesture/anchored scroll differs from the legal settled scroll.
    @Test func armsOnlyWhenSourceDiffersFromTarget() {
        #expect(GridScrollRebase.shouldArm(fromY: 100, toY: 100) == false)     // normal commit → no bridge
        #expect(GridScrollRebase.shouldArm(fromY: 100, toY: 100.4) == false)   // imperceptible → instant
        #expect(GridScrollRebase.shouldArm(fromY: 420, toY: 300) == true)      // edge clamp → bridge
        #expect(GridScrollRebase.shouldArm(fromY: 0, toY: 90) == true)
    }

    // (3) Progress interpolates from source to target MONOTONICALLY, staying within [from, to] (no bounce).
    @Test func interpolatesMonotonicallyNoBounce() {
        let from: CGFloat = 420, to: CGFloat = 300   // a downward clamp (zoom-out shrank content)
        var last = GridScrollRebase.scrollY(fromY: from, toY: to, progress: 0)
        #expect(abs(last - from) < 1e-9)             // starts at source
        for i in 1...20 {
            let p = CGFloat(i) / 20
            let y = GridScrollRebase.scrollY(fromY: from, toY: to, progress: p)
            #expect(y <= last + 1e-9)                // monotonic toward target (to < from here)
            #expect(y <= from + 1e-9 && y >= to - 1e-9)   // never overshoots either endpoint
            last = y
        }
    }

    // (4) The bridge's final frame equals the canonical settled scroll exactly.
    @Test func finalFrameEqualsTargetExactly() {
        #expect(GridScrollRebase.scrollY(fromY: 420, toY: 300, progress: 1) == 300)
        #expect(GridScrollRebase.scrollY(fromY: 0, toY: 137.5, progress: 1) == 137.5)
        #expect(GridScrollRebase.scrollY(fromY: 420, toY: 300, progress: 1.5) == 300)   // clamped past 1
    }

    @Test func easeOutIsClampedAndMonotonic() {
        #expect(GridScrollRebase.easeOut(0) == 0)
        #expect(GridScrollRebase.easeOut(1) == 1)
        #expect(GridScrollRebase.easeOut(-1) == 0)
        #expect(GridScrollRebase.easeOut(2) == 1)
        #expect(GridScrollRebase.easeOut(0.5) > 0.5)                            // ease-OUT: fast then slow
        #expect(GridScrollRebase.easeOut(0.25) < GridScrollRebase.easeOut(0.75))
    }

    @Test func progressClampsToUnitInterval() {
        #expect(GridScrollRebase.progress(start: 10, now: 10) == 0)
        #expect(GridScrollRebase.progress(start: 10, now: 10 + GridScrollRebase.duration) == 1)
        #expect(GridScrollRebase.progress(start: 10, now: 100) == 1)           // way past → clamped
        #expect(GridScrollRebase.progress(start: 10, now: 5) == 0)             // before start → clamped
        #expect(GridScrollRebase.duration <= 0.18 && GridScrollRebase.duration >= 0.12)  // within spec window
    }
}
