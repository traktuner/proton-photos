import Foundation
import Testing
import PhotosCore
@testable import MediaCache

/// Proves the stable-viewport debounce emits the visible set ONCE per settle, not every frame
/// The viewport debounce should enqueue visible requests once, not every frame.
@Suite("Viewport request debouncer")
struct ViewportRequestDebouncerTests {
    private func uids(_ ids: [String]) -> [PhotoUID] { ids.map { PhotoUID(volumeID: "v", nodeID: $0) } }

    @Test func stationaryViewportEmitsExactlyOnce() {
        let d = ViewportRequestDebouncer(window: 0.1)
        let set = uids(["a", "b", "c"])
        // Same set re-noted every frame for 90 ms (still within the window).
        d.note(set, at: 0.00)
        d.note(set, at: 0.03)
        d.note(set, at: 0.06)
        d.note(set, at: 0.09)
        #expect(d.flushIfStable(at: 0.05) == nil)   // not stable long enough yet
        #expect(d.flushIfStable(at: 0.20) == set)   // settled → emit once
        #expect(d.flushIfStable(at: 0.30) == nil)   // already emitted; no repeat for the same set
        #expect(d.flushIfStable(at: 0.50) == nil)
    }

    @Test func changingViewportNeverSettlesUntilItStops() {
        let d = ViewportRequestDebouncer(window: 0.1)
        // A fast scroll: the set changes every frame.
        d.note(uids(["a"]), at: 0.00)
        d.note(uids(["b"]), at: 0.05)
        d.note(uids(["c"]), at: 0.09)
        #expect(d.flushIfStable(at: 0.12) == nil)        // c noted at 0.09, only 0.03 stable
        // Scrolling stops on c.
        #expect(d.flushIfStable(at: 0.20) == uids(["c"])) // now stable → emit the final set once
        #expect(d.flushIfStable(at: 0.40) == nil)
    }

    @Test func rearmDecisionEmitsFinalSetExactlyOnce() {
        // Models the scheduling policy: note A, then B/C before the first settle check; the early check
        // returns nil but signals there's still pending work to re-arm; a later check emits the final set C
        // exactly once. (Regression guard: re-arm must key off the debouncer, not the caller's per-frame queue.)
        let d = ViewportRequestDebouncer(window: 0.1)
        let a = uids(["a"]); let b = uids(["b"]); let c = uids(["c"])
        d.note(a, at: 0.00)
        d.note(b, at: 0.02)
        d.note(c, at: 0.04)                               // final set settles on C at t=0.04
        #expect(d.flushIfStable(at: 0.05) == nil)         // too early (C only 0.01 s stable)
        #expect(d.hasPendingUnflushed() == true)          // → caller re-arms another settle check
        #expect(d.flushIfStable(at: 0.15) == c)           // C has now been stable ≥ window → emit once
        #expect(d.hasPendingUnflushed() == false)         // emitted → no further re-arm
        #expect(d.flushIfStable(at: 0.30) == nil)         // never re-emitted
    }

    @Test func newSetAfterFlushEmitsAgain() {
        let d = ViewportRequestDebouncer(window: 0.1)
        d.note(uids(["a"]), at: 0.0)
        #expect(d.flushIfStable(at: 0.2) == uids(["a"]))
        d.note(uids(["b"]), at: 0.3)
        #expect(d.flushIfStable(at: 0.35) == nil)         // b not yet stable
        #expect(d.flushIfStable(at: 0.45) == uids(["b"])) // b settled → emit
    }
}
