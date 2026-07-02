/// Pure LRU bookkeeping for a per-item texture cache. This type owns no Metal or image resources; it only
/// decides residency, pinning, in-flight upload de-duplication, per-frame upload budget, and eviction order.
///
/// Platform adapters provide their own memory budgets. The same policy must behave identically for macOS,
/// iOS, and iPadOS because IDs are generic and the policy has no UI, MetalKit, or PhotosCore dependency.
package struct GridTextureResidencyPolicy<ID: Hashable & Sendable>: Equatable {
    package enum DrawState: Equatable, Sendable {
        case real
        case placeholder
    }

    package let capacity: Int
    package let uploadBudgetPerFrame: Int

    package private(set) var resident: Set<ID> = []
    private var lastUsed: [ID: Int] = [:]
    private var inFlight: Set<ID> = []
    package private(set) var pinned: Set<ID> = []
    private var tick = 0
    package private(set) var evictionCount = 0

    package init(capacity: Int, uploadBudgetPerFrame: Int) {
        self.capacity = max(1, capacity)
        self.uploadBudgetPerFrame = max(1, uploadBudgetPerFrame)
    }

    package var residentCount: Int { resident.count }
    package var inFlightCount: Int { inFlight.count }
    package var pinnedCount: Int { pinned.count }

    /// What the renderer should draw for `id` this frame: the real texture if resident, else a placeholder.
    package func drawState(_ id: ID) -> DrawState { resident.contains(id) ? .real : .placeholder }
    package func isResident(_ id: ID) -> Bool { resident.contains(id) }
    package func isInFlight(_ id: ID) -> Bool { inFlight.contains(id) }

    /// Start a frame: advance the clock and pin the currently-visible/overscan set.
    package mutating func beginFrame(pinned: Set<ID>) {
        tick += 1
        self.pinned = pinned
    }

    /// Mark a resident texture as used this frame so it sorts newer in the LRU order.
    package mutating func noteUsed(_ id: ID) {
        if resident.contains(id) { lastUsed[id] = tick }
    }

    /// Pick up to `uploadBudgetPerFrame` IDs from `wanted` that are neither resident nor already in-flight.
    package mutating func selectUploads(wanted: [ID]) -> [ID] {
        var chosen: [ID] = []
        for id in wanted {
            guard chosen.count < uploadBudgetPerFrame else { break }
            guard !resident.contains(id), !inFlight.contains(id) else { continue }
            inFlight.insert(id)
            chosen.append(id)
        }
        return chosen
    }

    /// A texture upload finished: the ID is now resident and freshly used.
    package mutating func completeUpload(_ id: ID) {
        inFlight.remove(id)
        resident.insert(id)
        lastUsed[id] = tick
    }

    /// A texture upload failed or was abandoned; clear the in-flight flag so it can be retried.
    package mutating func abandonUpload(_ id: ID) {
        inFlight.remove(id)
    }

    /// Evict least-recently-used non-pinned textures until residency fits the capacity budget.
    package mutating func evictToBudget() -> [ID] {
        guard resident.count > capacity else { return [] }
        let evictionsNeeded = resident.count - capacity
        var candidates: [(id: ID, tick: Int)] = []
        candidates.reserveCapacity(min(evictionsNeeded, resident.count))

        func siftUp(_ index: Int) {
            var child = index
            while child > 0 {
                let parent = (child - 1) / 2
                guard candidates[child].tick > candidates[parent].tick else { return }
                candidates.swapAt(child, parent)
                child = parent
            }
        }

        func siftDown(from index: Int) {
            var parent = index
            while true {
                let left = parent * 2 + 1
                guard left < candidates.count else { return }
                let right = left + 1
                var largest = left
                if right < candidates.count, candidates[right].tick > candidates[left].tick {
                    largest = right
                }
                guard candidates[largest].tick > candidates[parent].tick else { return }
                candidates.swapAt(largest, parent)
                parent = largest
            }
        }

        for id in resident where !pinned.contains(id) {
            let usedTick = lastUsed[id] ?? -1
            if candidates.count < evictionsNeeded {
                candidates.append((id, usedTick))
                siftUp(candidates.count - 1)
            } else if let newestCandidate = candidates.first, usedTick < newestCandidate.tick {
                candidates[0] = (id, usedTick)
                siftDown(from: 0)
            }
        }

        candidates.sort { $0.tick < $1.tick }
        var evicted: [ID] = []
        evicted.reserveCapacity(candidates.count)
        for candidate in candidates {
            resident.remove(candidate.id)
            lastUsed.removeValue(forKey: candidate.id)
            evicted.append(candidate.id)
        }
        evictionCount += evicted.count
        return evicted
    }
}
