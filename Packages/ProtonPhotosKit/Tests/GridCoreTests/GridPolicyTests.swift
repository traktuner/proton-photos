import Testing
import GridCore

@Suite struct CoreTelemetryEventTests {
    @Test func eventIsPlainSendableValue() {
        let event = CoreTelemetryEvent(name: "GridTransition", fields: ["event": "PLAN_BUILT"])

        #expect(event == CoreTelemetryEvent(name: "GridTransition", fields: ["event": "PLAN_BUILT"]))
        #expect(event.name == "GridTransition")
        #expect(event.fields["event"] == "PLAN_BUILT")
    }
}

@Suite struct GridTextureResidencyPolicyTests {
    @Test func pinnedVisibleSurvivesEviction_offscreenEvicts() {
        var policy = GridTextureResidencyPolicy<String>(capacity: 2, costCapacity: .max, uploadBudgetPerFrame: 10)
        for id in ["a", "b", "c"] {
            policy.beginFrame(pinned: [])
            _ = policy.selectUploads(wanted: [id])
            policy.completeUpload(id, cost: 1)
        }

        policy.beginFrame(pinned: ["a"])
        let evicted = policy.evictToBudget()

        #expect(policy.isResident("a"))
        #expect(!policy.isResident("b"))
        #expect(policy.isResident("c"))
        #expect(evicted == ["b"])
    }

    @Test func evictionSkipsPinnedAndKeepsNewestNonPinnedResidents() {
        var policy = GridTextureResidencyPolicy<Int>(capacity: 4, costCapacity: .max, uploadBudgetPerFrame: 10)
        for id in 0 ..< 8 {
            policy.beginFrame(pinned: [])
            _ = policy.selectUploads(wanted: [id])
            policy.completeUpload(id, cost: 1)
        }

        policy.beginFrame(pinned: [0, 2])
        let evicted = policy.evictToBudget()

        #expect(evicted == [1, 3, 4, 5])
        #expect(policy.residentCount == 4)
        #expect(policy.isResident(0))
        #expect(policy.isResident(2))
        #expect(policy.isResident(6))
        #expect(policy.isResident(7))
        #expect(policy.evictionCount == 4)
    }

    @Test func largeResidencyEvictsOnlyNeededOldestSubsetWithinFrameBudget() {
        var policy = GridTextureResidencyPolicy<String>(capacity: 4_096, costCapacity: .max, uploadBudgetPerFrame: 128)
        let ids = (0 ..< 4_192).map { "photo-\($0)" }
        for id in ids {
            policy.beginFrame(pinned: [])
            _ = policy.selectUploads(wanted: [id])
            policy.completeUpload(id, cost: 1)
        }

        let pinned = Set(ids.prefix(256))
        policy.beginFrame(pinned: pinned)
        let clock = ContinuousClock()
        let start = clock.now
        let evicted = policy.evictToBudget()
        let elapsed = start.duration(to: clock.now)

        #expect(evicted == Array(ids[256 ..< 352]))
        #expect(policy.residentCount == 4_096)
        #expect(pinned.allSatisfy(policy.isResident))
        #expect(elapsed < .milliseconds(50))
    }

    @Test func placeholderAndUploadDedupAreStable() {
        var policy = GridTextureResidencyPolicy<String>(capacity: 10, costCapacity: .max, uploadBudgetPerFrame: 10)
        #expect(policy.drawState("a") == .placeholder)

        policy.beginFrame(pinned: [])
        #expect(policy.selectUploads(wanted: ["a", "b"]) == ["a", "b"])
        #expect(policy.selectUploads(wanted: ["a", "b", "c"]) == ["c"])
        policy.completeUpload("a", cost: 1)

        #expect(policy.drawState("a") == .real)
        #expect(policy.selectUploads(wanted: ["a", "b", "c"]) == [])
    }

    @Test func uploadBudgetPreservesPriorityOrder() {
        var policy = GridTextureResidencyPolicy<Int>(capacity: 100, costCapacity: .max, uploadBudgetPerFrame: 3)
        let wanted = Array(0 ..< 10)
        #expect(policy.selectUploads(wanted: wanted) == [0, 1, 2])
    }
}

@Suite struct GridTextureResidencyByteBudgetTests {
    /// Uploads `id` at `cost` through the full select→complete path in its own frame.
    private func upload<ID>(_ id: ID, cost: Int, pinned: Set<ID> = [], into policy: inout GridTextureResidencyPolicy<ID>) {
        policy.beginFrame(pinned: pinned)
        _ = policy.selectUploads(wanted: [id])
        policy.completeUpload(id, cost: cost)
    }

    @Test func byteBudgetEvictsLRUUntilUnderBothCountAndBytes() {
        var policy = GridTextureResidencyPolicy<String>(capacity: 100, costCapacity: 1_000, uploadBudgetPerFrame: 10)
        for (i, id) in ["a", "b", "c", "d"].enumerated() {
            upload(id, cost: 400, into: &policy)
            #expect(policy.residentCost == 400 * (i + 1))
        }

        policy.beginFrame(pinned: [])
        let evicted = policy.evictToBudget()

        // 1,600 bytes resident, cap 1,000 → the two oldest go (1,600 → 800 ≤ 1,000 after two).
        #expect(evicted == ["a", "b"])
        #expect(policy.residentCost == 800)
        #expect(policy.residentCount == 2)
    }

    @Test func byteEvictionStopsAtMinimalLRUPrefixAndKeepsPinned() {
        var policy = GridTextureResidencyPolicy<String>(capacity: 100, costCapacity: 1_000, uploadBudgetPerFrame: 10)
        upload("old-pinned", cost: 500, into: &policy)
        upload("old-evictable", cost: 500, into: &policy)
        upload("new", cost: 500, into: &policy)

        policy.beginFrame(pinned: ["old-pinned"])
        let evicted = policy.evictToBudget()

        // The pinned LRU entry survives; evicting the single oldest non-pinned suffices (1,500 → 1,000).
        #expect(evicted == ["old-evictable"])
        #expect(policy.isResident("old-pinned"))
        #expect(policy.isResident("new"))
        #expect(policy.residentCost == 1_000)
    }

    @Test func evictionCannotGoBelowPinnedFloorEvenWhenOverByteBudget() {
        var policy = GridTextureResidencyPolicy<String>(capacity: 100, costCapacity: 1_000, uploadBudgetPerFrame: 10)
        // Force an over-budget pinned set by bypassing admission (completeUpload directly).
        for id in ["p1", "p2", "p3"] { upload(id, cost: 600, pinned: ["p1", "p2", "p3"], into: &policy) }

        policy.beginFrame(pinned: ["p1", "p2", "p3"])
        let evicted = policy.evictToBudget()

        #expect(evicted.isEmpty)                       // pinned is never evicted
        #expect(policy.residentCost == 1_800)          // still over — admission is what prevents this state
    }

    @Test func admissionRefusesPinnedUploadBeyondPinnedResidentByteFloor() {
        var policy = GridTextureResidencyPolicy<String>(capacity: 100, costCapacity: 1_000, uploadBudgetPerFrame: 10)
        upload("visible-a", cost: 600, pinned: ["visible-a", "visible-b"], into: &policy)

        policy.beginFrame(pinned: ["visible-a", "visible-b"])
        #expect(policy.pinnedResidentCost == 600)
        #expect(policy.canAdmitUpload("visible-b", cost: 400))     // 600 + 400 fits exactly
        #expect(!policy.canAdmitUpload("visible-b", cost: 500))    // 600 + 500 can never fit — refuse
    }

    @Test func admissionRefusesUnpinnedUploadThatWouldOvershootTotals() {
        var policy = GridTextureResidencyPolicy<String>(capacity: 2, costCapacity: 1_000, uploadBudgetPerFrame: 10)
        upload("resident", cost: 900, into: &policy)

        policy.beginFrame(pinned: [])
        #expect(policy.canAdmitUpload("small", cost: 100))
        #expect(!policy.canAdmitUpload("big", cost: 200))          // would overshoot bytes right now

        upload("second", cost: 50, into: &policy)
        policy.beginFrame(pinned: [])
        #expect(!policy.canAdmitUpload("third", cost: 10))         // would overshoot the count capacity
    }

    @Test func pinnedFloorRecomputesFromCurrentWindowEachFrame() {
        var policy = GridTextureResidencyPolicy<String>(capacity: 100, costCapacity: 1_000, uploadBudgetPerFrame: 10)
        upload("scrolled-away", cost: 800, pinned: ["scrolled-away"], into: &policy)

        // Still pinned → a large new upload cannot be admitted above the floor.
        policy.beginFrame(pinned: ["scrolled-away", "incoming"])
        #expect(!policy.canAdmitUpload("incoming", cost: 400))

        // Window moved on: the old texture is unpinned, floor drops, the new visible item is admitted.
        policy.beginFrame(pinned: ["incoming"])
        #expect(policy.pinnedResidentCost == 0)
        #expect(policy.canAdmitUpload("incoming", cost: 400))
    }

    @Test func admissionGatedFramesKeepResidencyByteBoundedUnderChurn() {
        var policy = GridTextureResidencyPolicy<Int>(capacity: 50, costCapacity: 2_000, uploadBudgetPerFrame: 8)
        // Simulate a scroll: each frame a fresh window of 6 items (3 visible + 3 overscan) shifted by 2.
        for frame in 0 ..< 40 {
            let window = Array(frame * 2 ..< frame * 2 + 6)
            policy.beginFrame(pinned: Set(window))
            for id in policy.selectUploads(wanted: window) {
                if policy.canAdmitUpload(id, cost: 300) {
                    policy.completeUpload(id, cost: 300)
                } else {
                    policy.abandonUpload(id)
                }
            }
            _ = policy.evictToBudget()
            #expect(policy.residentCost <= 2_000)
            #expect(policy.residentCount <= 50)
            // The pinned floor never exceeds the byte budget — the structural P0 guarantee.
            #expect(policy.pinnedResidentCost <= 2_000)
        }
    }
}

@Suite struct GridTextureStreamingPolicyTests {
    @Test func pinsVisibleAndOverscanForScrollReversalReuse() {
        let window = GridTextureStreamingPolicy.window(
            visibleIDs: ["visible-a", "visible-b"],
            overscanIDs: ["above-a", "below-a"],
            maxPinned: 100
        )

        #expect(window.priority == ["visible-a", "visible-b", "above-a", "below-a"])
        #expect(window.pinned == ["visible-a", "visible-b", "above-a", "below-a"])
    }

    @Test func deduplicatesWhilePreservingVisibleFirstOrder() {
        let window = GridTextureStreamingPolicy.window(visibleIDs: ["a", "b"], overscanIDs: ["b", "c", "a"], maxPinned: 100)

        #expect(window.priority == ["a", "b", "c"])
        #expect(window.pinned == ["a", "b", "c"])
    }

    @Test func pinnedClampKeepsVisibleFirstThenNearestOverscanAndFullPriority() {
        let window = GridTextureStreamingPolicy.window(
            visibleIDs: ["v1", "v2"],
            overscanIDs: ["o1", "o2", "o3"],
            maxPinned: 3
        )

        // Overscan cannot make the protected set unbounded: only the nearest overscan stays pinned…
        #expect(window.pinned == ["v1", "v2", "o1"])
        // …but everything remains in upload priority order (evictable once the budget needs the room).
        #expect(window.priority == ["v1", "v2", "o1", "o2", "o3"])
    }

    @Test func pinnedClampDegradesToVisiblePrefixAtDenseLevels() {
        let visible = (0 ..< 6).map { "v\($0)" }
        let window = GridTextureStreamingPolicy.window(visibleIDs: visible, overscanIDs: ["o1"], maxPinned: 4)

        #expect(window.pinned == ["v0", "v1", "v2", "v3"])   // visible-first even when visible alone overflows
        #expect(window.priority == visible + ["o1"])
    }
}

@Suite struct GridTextureBudgetTests {
    @Test func budgetShapePreservesInjectedAdapterValues() {
        let budget = GridTextureBudget(
            maxUploadsPerFrame: 5,
            maxUploadBytesPerFrame: 1_234,
            maxCachedTextures: 17,
            maxResidentBytes: 56_789,
            overscanFraction: 0.75
        )

        #expect(budget.maxUploadsPerFrame == 5)
        #expect(budget.maxUploadBytesPerFrame == 1_234)
        #expect(budget.maxCachedTextures == 17)
        #expect(budget.maxResidentBytes == 56_789)
        #expect(budget.overscanFraction == 0.75)
    }
}

@Suite struct GridSelectionControllerTests {
    @Test func replaceToggleRangeAndClearMutateFlatSelection() {
        let ids = Array(0 ..< 10)
        var selection = GridSelectionController<Int>()

        selection.apply(.replace, flatIndex: 2, id: 2, orderedIDs: ids)
        #expect(selection.selected == [2])
        #expect(selection.anchorIndex == 2)

        selection.apply(.toggle, flatIndex: 5, id: 5, orderedIDs: ids)
        #expect(selection.selected == [2, 5])
        #expect(selection.anchorIndex == 5)

        selection.apply(.range, flatIndex: 7, id: 7, orderedIDs: ids)
        #expect(selection.selected == [5, 6, 7])
        #expect(selection.anchorIndex == 5)

        let didClear = selection.clear()
        #expect(didClear)
        #expect(selection.selected.isEmpty)
        #expect(selection.anchorIndex == nil)
        let didClearAgain = selection.clear()
        #expect(!didClearAgain)
    }

    @Test func rangeWithoutAnchorFallsBackToReplace() {
        let ids = Array(0 ..< 4)
        var selection = GridSelectionController<Int>()

        selection.apply(.range, flatIndex: 2, id: 2, orderedIDs: ids)

        #expect(selection.selected == [2])
        #expect(selection.anchorIndex == 2)
    }

    @Test func marqueeReplacesOrAddsToDragStartSelection() {
        var selection = GridSelectionController<String>()

        selection.apply(.replace, flatIndex: 0, id: "base", orderedIDs: ["base", "a", "b", "c"])
        selection.marqueeBegan(additive: false)
        let firstMarqueeChanged = selection.marqueeChanged(["a", "b"])
        #expect(firstMarqueeChanged)
        #expect(selection.selected == ["a", "b"])
        let duplicateMarqueeChanged = selection.marqueeChanged(["a", "b"])
        #expect(!duplicateMarqueeChanged)

        selection.marqueeBegan(additive: true)
        let additiveMarqueeChanged = selection.marqueeChanged(["c"])
        #expect(additiveMarqueeChanged)
        #expect(selection.selected == ["a", "b", "c"])
    }
}
