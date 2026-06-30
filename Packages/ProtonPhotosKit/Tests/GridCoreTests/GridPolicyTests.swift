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
        var policy = GridTextureResidencyPolicy<String>(capacity: 2, uploadBudgetPerFrame: 10)
        for id in ["a", "b", "c"] {
            policy.beginFrame(pinned: [])
            _ = policy.selectUploads(wanted: [id])
            policy.completeUpload(id)
        }

        policy.beginFrame(pinned: ["a"])
        let evicted = policy.evictToBudget()

        #expect(policy.isResident("a"))
        #expect(!policy.isResident("b"))
        #expect(policy.isResident("c"))
        #expect(evicted == ["b"])
    }

    @Test func placeholderAndUploadDedupAreStable() {
        var policy = GridTextureResidencyPolicy<String>(capacity: 10, uploadBudgetPerFrame: 10)
        #expect(policy.drawState("a") == .placeholder)

        policy.beginFrame(pinned: [])
        #expect(policy.selectUploads(wanted: ["a", "b"]) == ["a", "b"])
        #expect(policy.selectUploads(wanted: ["a", "b", "c"]) == ["c"])
        policy.completeUpload("a")

        #expect(policy.drawState("a") == .real)
        #expect(policy.selectUploads(wanted: ["a", "b", "c"]) == [])
    }

    @Test func uploadBudgetPreservesPriorityOrder() {
        var policy = GridTextureResidencyPolicy<Int>(capacity: 100, uploadBudgetPerFrame: 3)
        let wanted = Array(0 ..< 10)
        #expect(policy.selectUploads(wanted: wanted) == [0, 1, 2])
    }
}

@Suite struct GridTextureStreamingPolicyTests {
    @Test func pinsVisibleAndOverscanForScrollReversalReuse() {
        let window = GridTextureStreamingPolicy.window(
            visibleIDs: ["visible-a", "visible-b"],
            overscanIDs: ["above-a", "below-a"]
        )

        #expect(window.priority == ["visible-a", "visible-b", "above-a", "below-a"])
        #expect(window.pinned == ["visible-a", "visible-b", "above-a", "below-a"])
    }

    @Test func deduplicatesWhilePreservingVisibleFirstOrder() {
        let window = GridTextureStreamingPolicy.window(visibleIDs: ["a", "b"], overscanIDs: ["b", "c", "a"])

        #expect(window.priority == ["a", "b", "c"])
        #expect(window.pinned == ["a", "b", "c"])
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
