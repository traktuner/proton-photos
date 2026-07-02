import AppKit
import Testing
import PhotosCore
import GridCore
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

    @Test func viewportDrawSlotsExcludeOverscanOnlyTiles() {
        let slots = [
            GridRenderSlot(index: 0, column: 0, row: -2, rect: CGRect(x: 0, y: -220, width: 100, height: 100)),
            GridRenderSlot(index: 1, column: 0, row: -1, rect: CGRect(x: 0, y: -20, width: 100, height: 100)),
            GridRenderSlot(index: 2, column: 0, row: 0, rect: CGRect(x: 0, y: 20, width: 100, height: 100)),
            GridRenderSlot(index: 3, column: 0, row: 9, rect: CGRect(x: 0, y: 390, width: 100, height: 100)),
            GridRenderSlot(index: 4, column: 0, row: 10, rect: CGRect(x: 0, y: 520, width: 100, height: 100)),
        ]

        let drawn = MetalGridCoordinator.viewportDrawSlots(slots, viewportSize: CGSize(width: 320, height: 480))

        #expect(drawn.map(\.index) == [1, 2, 3])
    }
}
