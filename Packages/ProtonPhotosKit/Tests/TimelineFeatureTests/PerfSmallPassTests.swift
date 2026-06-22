import AppKit
import Testing
import PhotosCore
@testable import TimelineFeature

// MARK: - Hot-path diagnostics counters (shares PhotoDiagnostics.shared)
//
// The thumbnail-cell perf tests (polling backoff, duration-lookup gate, RoundedCellView rect cache,
// PhotoGridItem badge layout) were removed with the legacy NSCollectionView grid. The remaining test
// guards the still-live `PhotoDiagnostics` pinch hot-path accounting.

/// `.serialized`: reads `PhotoDiagnostics.shared` counter deltas, so it must not run in parallel with
/// other suites that touch the same shared counters.
@Suite("Perf small pass — counters", .serialized)
@MainActor
struct PerfSmallPassCounterTests {

    // DiagnosticsCounterAccuracyTest: presence checks are NOT counted as disk reads.
    @Test func diskPresenceCheckNotCountedAsDiskRead() {
        let d = PhotoDiagnostics.shared
        d.setActivePinch(true)
        defer { d.setActivePinch(false) }

        let before = d.hotPathCounters()
        d.recordDiskPresenceCheckDuringPinch()
        d.recordDiskPresenceCheckDuringPinch()
        d.recordDiskReadDuringPinch()
        let after = d.hotPathCounters()

        #expect(after.diskPresenceCheckDuringPinch - before.diskPresenceCheckDuringPinch == 2)
        #expect(after.diskReadDuringPinch - before.diskReadDuringPinch == 1)

        // Outside a pinch both are ignored.
        d.setActivePinch(false)
        let idle = d.hotPathCounters()
        d.recordDiskPresenceCheckDuringPinch()
        d.recordDiskReadDuringPinch()
        let stillIdle = d.hotPathCounters()
        #expect(stillIdle.diskPresenceCheckDuringPinch == idle.diskPresenceCheckDuringPinch)
        #expect(stillIdle.diskReadDuringPinch == idle.diskReadDuringPinch)
    }
}
