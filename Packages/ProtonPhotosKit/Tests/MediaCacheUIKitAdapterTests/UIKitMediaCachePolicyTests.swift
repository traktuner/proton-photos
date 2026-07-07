import Foundation
import Testing
@testable import MediaCacheUIKitAdapter

/// Deterministic iOS/iPadOS budget-policy tests: exact budgets for the 4/6/8/12 GB device classes, the clamp
/// edges, the constrained-memory decoded curve, and the dynamic-headroom cap. Physical/available memory are
/// injected, so nothing here depends on the machine running the tests.
@Suite struct UIKitMediaCachePolicyTests {
    private let GiB: UInt64 = 1024 * 1024 * 1024
    private let MiB = 1024 * 1024

    // MARK: - Device memory class

    @Test func memoryClassSplitsAtFourPointFiveGiB() {
        #expect(UIKitMediaCachePolicy.memoryClass(physicalMemory: 4 * GiB) == .constrained)
        // Real "4 GB" hardware reports below the marketing size - still constrained.
        #expect(UIKitMediaCachePolicy.memoryClass(physicalMemory: UInt64(3.7 * Double(GiB))) == .constrained)
        #expect(UIKitMediaCachePolicy.memoryClass(physicalMemory: UInt64(4.5 * Double(GiB))) == .constrained)
        #expect(UIKitMediaCachePolicy.memoryClass(physicalMemory: UInt64(4.5 * Double(GiB)) + 1) == .standard)
        #expect(UIKitMediaCachePolicy.memoryClass(physicalMemory: 6 * GiB) == .standard)
        #expect(UIKitMediaCachePolicy.memoryClass(physicalMemory: 12 * GiB) == .standard)
    }

    // MARK: - Compressed byte RAM (1%, 32…512 MiB)

    @Test func byteRAMBudgetForDeviceClasses() {
        #expect(UIKitMediaCachePolicy.dataMemoryBudgetBytes(physicalMemory: 4 * GiB) == 42_949_672)    // ~41 MiB
        #expect(UIKitMediaCachePolicy.dataMemoryBudgetBytes(physicalMemory: 6 * GiB) == 64_424_509)    // ~61 MiB
        #expect(UIKitMediaCachePolicy.dataMemoryBudgetBytes(physicalMemory: 8 * GiB) == 85_899_345)    // ~82 MiB
        #expect(UIKitMediaCachePolicy.dataMemoryBudgetBytes(physicalMemory: 12 * GiB) == 128_849_018)  // ~123 MiB
    }

    @Test func byteRAMBudgetClampEdges() {
        #expect(UIKitMediaCachePolicy.dataMemoryBudgetBytes(physicalMemory: 2 * GiB) == 32 * MiB)      // floor binds
        #expect(UIKitMediaCachePolicy.dataMemoryBudgetBytes(physicalMemory: 64 * GiB) == 512 * MiB)    // ceiling binds
    }

    // MARK: - Decoded thumbnail RAM (constrained 5.5% ≤224 MiB; standard 8% ≤1024 MiB)

    @Test func decodedRAMBudgetOnConstrainedFourGiBIsCappedAt224MiB() {
        // The audit's core number: a 4 GB iPhone must land at ~200-224 MiB, not the old flat 8% (~328 MiB).
        let fourGiB = UIKitMediaCachePolicy.decodedRAMBudgetBytes(physicalMemory: 4 * GiB, availableMemoryBytes: nil)
        #expect(fourGiB == 224 * MiB)

        // Real-world "4 GB" hardware reports less than 4 GiB - the curve keeps it inside the target window.
        let reported = UIKitMediaCachePolicy.decodedRAMBudgetBytes(
            physicalMemory: UInt64(3.5 * Double(GiB)), availableMemoryBytes: nil)
        #expect(reported == 206_695_301)                       // ~197 MiB
        #expect(reported >= 96 * MiB && reported <= 224 * MiB)
    }

    @Test func decodedRAMBudgetOnStandardDevicesKeepsProportionalEightPercent() {
        #expect(UIKitMediaCachePolicy.decodedRAMBudgetBytes(physicalMemory: 6 * GiB, availableMemoryBytes: nil) == 515_396_075)     // ~492 MiB
        #expect(UIKitMediaCachePolicy.decodedRAMBudgetBytes(physicalMemory: 8 * GiB, availableMemoryBytes: nil) == 687_194_767)     // ~655 MiB
        #expect(UIKitMediaCachePolicy.decodedRAMBudgetBytes(physicalMemory: 12 * GiB, availableMemoryBytes: nil) == 1_030_792_151)  // ~983 MiB
    }

    @Test func decodedRAMBudgetClampEdges() {
        // 1 GiB constrained device → the 96 MiB floor binds.
        #expect(UIKitMediaCachePolicy.decodedRAMBudgetBytes(physicalMemory: 1 * GiB, availableMemoryBytes: nil) == 96 * MiB)
        // 2 GiB constrained device → proportional 5.5% inside the window.
        #expect(UIKitMediaCachePolicy.decodedRAMBudgetBytes(physicalMemory: 2 * GiB, availableMemoryBytes: nil) == 118_111_600)
        // 16 GiB standard device → the 1 GiB ceiling binds.
        #expect(UIKitMediaCachePolicy.decodedRAMBudgetBytes(physicalMemory: 16 * GiB, availableMemoryBytes: nil) == 1024 * MiB)
    }

    @Test func decodedRAMBudgetHonorsDynamicHeadroom() {
        // Launching into an already-pressured system: never take more than half the available memory…
        let tight = UIKitMediaCachePolicy.decodedRAMBudgetBytes(
            physicalMemory: 4 * GiB, availableMemoryBytes: UInt64(300 * MiB))
        #expect(tight == 150 * MiB)
        // …but never below the 96 MiB working floor either.
        let veryTight = UIKitMediaCachePolicy.decodedRAMBudgetBytes(
            physicalMemory: 4 * GiB, availableMemoryBytes: UInt64(120 * MiB))
        #expect(veryTight == 96 * MiB)
        // Plentiful or unknown headroom leaves the curve untouched.
        #expect(UIKitMediaCachePolicy.decodedRAMBudgetBytes(
            physicalMemory: 4 * GiB, availableMemoryBytes: 8 * GiB) == 224 * MiB)
        #expect(UIKitMediaCachePolicy.decodedRAMBudgetBytes(
            physicalMemory: 4 * GiB, availableMemoryBytes: nil) == 224 * MiB)
        #expect(UIKitMediaCachePolicy.decodedRAMBudgetBytes(
            physicalMemory: 4 * GiB, availableMemoryBytes: 0) == 224 * MiB)   // 0 = "no reading", not "no memory"
    }

    // MARK: - UIImage wrapper RAM (0.25%, 8…48 MiB)

    @Test func wrapperRAMBudgetForDeviceClassesAndClampEdges() {
        #expect(UIKitMediaCachePolicy.wrapperRAMBudgetBytes(physicalMemory: 4 * GiB) == 10_737_418)   // ~10 MiB
        #expect(UIKitMediaCachePolicy.wrapperRAMBudgetBytes(physicalMemory: 6 * GiB) == 16_106_127)   // ~15 MiB
        #expect(UIKitMediaCachePolicy.wrapperRAMBudgetBytes(physicalMemory: 8 * GiB) == 21_474_836)   // ~20 MiB
        #expect(UIKitMediaCachePolicy.wrapperRAMBudgetBytes(physicalMemory: 12 * GiB) == 32_212_254)  // ~31 MiB
        #expect(UIKitMediaCachePolicy.wrapperRAMBudgetBytes(physicalMemory: 2 * GiB) == 8 * MiB)      // floor binds
        #expect(UIKitMediaCachePolicy.wrapperRAMBudgetBytes(physicalMemory: 64 * GiB) == 48 * MiB)    // ceiling binds
    }
}
