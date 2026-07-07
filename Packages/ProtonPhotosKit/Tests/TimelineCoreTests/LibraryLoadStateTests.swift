import Testing
@testable import TimelineCore

/// Covers the five library-load phases the product requires: unknown count, known count / no thumbnails,
/// first content ready, empty library, and error - plus the transitions and edge cases between them.
@Suite struct LibraryLoadStateTests {

    private func reduce(_ state: LibraryLoadState, _ events: [LibraryLoadEvent]) -> LibraryLoadState {
        events.reduce(state) { LibraryLoadPolicy.reduce($0, $1) }
    }

    // MARK: Authenticated, Inventory Not Loaded

    @Test func initialStateIsPreparingWithUnknownCount() {
        let state = LibraryLoadState.initial
        #expect(state == .preparingInventory)
        #expect(state.knownCount == nil)          // count is genuinely unknown — must not fake a number
        #expect(state.isLoading)                  // shell shows an indeterminate spinner
        #expect(!state.isContentReady)
        #expect(!state.hasSettled)
    }

    // MARK: Inventory Known, First Thumbnails Pending

    @Test func freshInventoryResolvingMovesToLoadingContentWithCount() {
        let state = reduce(.initial, [.inventoryResolved(count: 20_000, cached: false)])
        #expect(state == .loadingContent(count: 20_000, usingCachedInventory: false))
        #expect(state.knownCount == 20_000)       // count shown calmly once known
        #expect(state.isLoading)                  // still loading — grid must NOT show yet (no blank grid)
        #expect(!state.isContentReady)
        #expect(!state.hasSettled)
    }

    @Test func cachedInventoryIsDistinguishedFromFresh() {
        let cached = reduce(.initial, [.inventoryResolved(count: 42, cached: true)])
        #expect(cached == .loadingContent(count: 42, usingCachedInventory: true))
        // A fresh load afterwards flips the cached flag and can revise the count without layout jumps.
        let fresh = reduce(cached, [.inventoryResolved(count: 50, cached: false)])
        #expect(fresh == .loadingContent(count: 50, usingCachedInventory: false))
        #expect(fresh.knownCount == 50)
    }

    // MARK: First Content Ready

    @Test func firstContentReadyPromotesLoadingToContentReady() {
        let state = reduce(.initial, [
            .inventoryResolved(count: 12, cached: false),
            .firstContentReady,
        ])
        #expect(state == .contentReady(count: 12))
        #expect(state.isContentReady)
        #expect(!state.isLoading)                 // spinner gone; grid is presentable
        #expect(state.hasSettled)
        #expect(state.knownCount == 12)
    }

    @Test func countKeepsUpdatingAfterContentIsReady() {
        // A later refresh (e.g. an upload landed) must update the count without leaving the presented grid.
        let state = reduce(.initial, [
            .inventoryResolved(count: 12, cached: true),
            .firstContentReady,
            .inventoryResolved(count: 13, cached: false),
        ])
        #expect(state == .contentReady(count: 13))
        #expect(state.isContentReady)
    }

    @Test func firstContentReadyBeforeInventoryIsIgnored() {
        // A stray first-content signal with no known inventory must never reveal an unprepared grid.
        let state = reduce(.initial, [.firstContentReady])
        #expect(state == .preparingInventory)
        #expect(!state.isContentReady)
    }

    // MARK: Empty Library

    @Test func zeroCountResolvesToEmpty() {
        let state = reduce(.initial, [.inventoryResolved(count: 0, cached: false)])
        #expect(state == .empty)
        #expect(state.isEmpty)
        #expect(state.knownCount == 0)
        #expect(!state.isLoading)                 // empty settles immediately — no perpetual spinner
        #expect(state.hasSettled)
    }

    @Test func emptyIsReachedFromCachedZeroToo() {
        let state = reduce(.initial, [.inventoryResolved(count: 0, cached: true)])
        #expect(state == .empty)
    }

    @Test func libraryEmptiedAfterContentBecomesEmpty() {
        // Everything got trashed after the grid was shown → the grid collapses to the empty state.
        let state = reduce(.initial, [
            .inventoryResolved(count: 3, cached: false),
            .firstContentReady,
            .inventoryResolved(count: 0, cached: false),
        ])
        #expect(state == .empty)
    }

    // MARK: Retryable Load Failure

    @Test func failureBeforeContentSurfacesError() {
        let state = reduce(.initial, [.failed(message: "Network unavailable", retryable: true)])
        #expect(state == .failed(message: "Network unavailable", retryable: true))
        #expect(state.failure?.message == "Network unavailable")
        #expect(state.failure?.retryable == true)
        #expect(!state.isLoading)                 // error settles — retry affordance, not a spinner
        #expect(state.hasSettled)
    }

    @Test func failureAfterCachedInventoryKeepsShowingCachedContent() {
        // A cached snapshot is loading; the fresh refresh then fails. The user keeps their (cached) photos and
        // browses offline - no error wall replaces resolvable content.
        let state = reduce(.initial, [
            .inventoryResolved(count: 100, cached: true),
            .failed(message: "Timed out", retryable: true),
        ])
        #expect(state == .loadingContent(count: 100, usingCachedInventory: true))
    }

    @Test func failureAfterEmptyDoesNotSurface() {
        // Settled-empty then a background refresh fails → stays empty, not an error.
        let state = reduce(.initial, [
            .inventoryResolved(count: 0, cached: false),
            .failed(message: "Timed out", retryable: true),
        ])
        #expect(state == .empty)
    }

    @Test func nonRetryableFailureIsPreserved() {
        let state = reduce(.initial, [.failed(message: "Session expired", retryable: false)])
        #expect(state.failure?.retryable == false)
    }

    @Test func backgroundFailureDoesNotYankPresentedGrid() {
        // Once content is on screen, a subsequent (background refresh) failure keeps the grid intact.
        let state = reduce(.initial, [
            .inventoryResolved(count: 7, cached: false),
            .firstContentReady,
            .failed(message: "Refresh failed", retryable: true),
        ])
        #expect(state == .contentReady(count: 7))
        #expect(state.isContentReady)
    }

    // MARK: Reset / lifecycle

    @Test func resetReturnsToPreparingFromAnyState() {
        let states: [LibraryLoadState] = [
            .preparingInventory,
            .loadingContent(count: 5, usingCachedInventory: true),
            .contentReady(count: 5),
            .empty,
            .failed(message: "x", retryable: true),
        ]
        for start in states {
            #expect(LibraryLoadPolicy.reduce(start, .reset) == .preparingInventory)
        }
    }

    @Test func retryAfterFailureReloads() {
        // Failure → reset (retry tapped) → fresh inventory → content ready.
        let state = reduce(.initial, [
            .failed(message: "Network unavailable", retryable: true),
            .reset,
            .inventoryResolved(count: 9, cached: false),
            .firstContentReady,
        ])
        #expect(state == .contentReady(count: 9))
    }

    @Test func stateIsValueSemantic() {
        // Equatable + Sendable value type - safe to publish across the app without shared mutable state.
        let a = LibraryLoadState.loadingContent(count: 1, usingCachedInventory: false)
        let b = LibraryLoadState.loadingContent(count: 1, usingCachedInventory: false)
        #expect(a == b)
        #expect(a != .loadingContent(count: 1, usingCachedInventory: true))
    }
}
