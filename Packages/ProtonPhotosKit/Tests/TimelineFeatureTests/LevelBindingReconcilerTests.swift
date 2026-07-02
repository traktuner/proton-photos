import Testing
import Foundation
import TimelineCore
@testable import TimelineFeature

/// GUARANTEE 1 - Binding-echo guard. After a host-led pinch commit advances `coordinator.level` to N and pushes
/// N to the SwiftUI `@Binding level`, an `updateNSView` pass that arrives carrying the STALE pre-commit value S
/// must NOT re-drive `animateToLevel(S)` (which would re-anchor at the viewport centre and jump a different
/// photo under the cursor). The pure decision lives in `LevelBindingReconciler`; the host owns the latch and
/// the three commit sites arm it. These tests pin the decision table AND the production wiring (source guards),
/// since `MetalProductionGridView` (an `NSViewRepresentable`) is not directly unit-testable.
@Suite struct LevelBindingReconcilerTests {

    private func source(_ name: String) -> String {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent(); url.deleteLastPathComponent(); url.deleteLastPathComponent()
        return (try? String(contentsOf: url.appendingPathComponent("Sources/TimelineFeature/\(name)"), encoding: .utf8)) ?? ""
    }

    // MARK: 1 - the bug case: a stale pre-commit echo while awaiting binding sync is SUPPRESSED.
    @Test func stalePostCommitEchoIsIgnored() {
        // Pinch committed S=3 → N=1; the host armed the echo guard with the pre-commit level (3). A coincident
        // updateNSView pass delivers the stale binding S=3 while the host is already at N=1.
        let action = LevelBindingReconciler.decide(binding: 3, hostLevel: 1, staleEcho: 3)
        #expect(action == .ignore, "a stale pre-commit echo must be ignored, never re-drive animateToLevel")
    }

    // MARK: 2 - binding catch-up clears the latch (a no-op, since binding == host level).
    @Test func bindingCatchUpClearsLatch() {
        let action = LevelBindingReconciler.decide(binding: 1, hostLevel: 1, staleEcho: 3)
        #expect(action == .clearLatch, "when the binding reaches the committed level the latch clears (no re-drive)")
    }

    // MARK: 3 - a genuine external (+/-) change while the latch is armed is STILL honoured (not swallowed)
    //          as long as it is not the exact stale value - and it clears the latch.
    @Test func genuineExternalChangeWhileLatchedIsHonoured() {
        // Host at N=1 (just committed from 3); user presses − to go to level 2. 2 ≠ host(1) and 2 ≠ stale(3).
        let action = LevelBindingReconciler.decide(binding: 2, hostLevel: 1, staleEcho: 3)
        #expect(action == .reDrive(2), "a genuine external change that isn't the stale value must re-drive")
    }

    // MARK: 4 - with NO latch armed, the reconciler behaves exactly like the legacy guard.
    @Test func noLatchBehavesLikeLegacyGuard() {
        #expect(LevelBindingReconciler.decide(binding: 4, hostLevel: 2, staleEcho: nil) == .reDrive(4),
                "external change with no latch must re-drive (legacy `if level != coordinator.level` behaviour)")
        #expect(LevelBindingReconciler.decide(binding: 2, hostLevel: 2, staleEcho: nil) == .clearLatch,
                "in-sync with no latch is a no-op")
    }

    // MARK: 5 - the latch only suppresses the EXACT stale value; recovery can never stick.
    @Test func latchOnlySuppressesTheStaleValueAndRecovers() {
        // Multiple stale passes (all S) are each ignored while the latch is armed…
        #expect(LevelBindingReconciler.decide(binding: 3, hostLevel: 1, staleEcho: 3) == .ignore)
        #expect(LevelBindingReconciler.decide(binding: 3, hostLevel: 1, staleEcho: 3) == .ignore)
        // …but the very next NON-stale binding value re-drives (clearing the latch in the host), so a legitimate
        // change can never be swallowed for more than the one stale value - the latch can't get permanently stuck.
        #expect(LevelBindingReconciler.decide(binding: 0, hostLevel: 1, staleEcho: 3) == .reDrive(0))
    }

    // MARK: 6 - production wiring: updateNSView routes the level binding through the latch, NOT a bare
    //          `if level != coordinator.level { animateToLevel(level) }`.
    @Test func updateNSViewRoutesThroughReconciler() {
        let view = source("MetalProductionGridView.swift")
        #expect(view.contains("host.reconcileLevelBinding(level)"),
                "updateNSView must reconcile the level binding through the echo-guarded path")
        #expect(!view.contains("if level != host.coordinator.level { host.animateToLevel(level) }"),
                "the legacy unguarded reconciliation must be gone (it re-issued a stale viewport-centre zoom)")
    }

    // MARK: 7 - production wiring: the host arms the echo guard at EVERY host-led commit site (lattice pinch,
    //          reflow, overview dissolve), and reconcileLevelBinding consults LevelBindingReconciler.
    @Test func hostArmsEchoGuardAtEveryCommitSite() {
        let host = source("MetalGridScrollHost.swift")
        #expect(host.contains("LevelBindingReconciler.decide("),
                "reconcileLevelBinding must use the pure decision")
        // All three commit paths push the level THROUGH the arming helper (no bare onZoomCommit survives).
        let commitCalls = host.components(separatedBy: "commitLevelToBinding(previousLevel:").count - 1
        // 3 call sites (lattice / reflow / overview) + the helper's own parameter declaration = 4 textual matches.
        #expect(commitCalls >= 4, "lattice / reflow / overview commits must all arm the echo guard (found \(commitCalls - 1) sites)")
        // The binding may be pushed in exactly ONE place - the arming helper - so no commit site can bypass it.
        let bindingPushes = host.components(separatedBy: "onZoomCommit?(coordinator.level)").count - 1
        #expect(bindingPushes == 1, "the level binding must be pushed only via the echo-arming chokepoint (found \(bindingPushes))")
        // Armed only on a real level change (a no-op commit must not swallow the next external change).
        #expect(host.contains("if coordinator.level != previousLevel { pendingLevelEcho = previousLevel }"),
                "the echo guard must arm only when the commit actually changed the level")
    }
}
