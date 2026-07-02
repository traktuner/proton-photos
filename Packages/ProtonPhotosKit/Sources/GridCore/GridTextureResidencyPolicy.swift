/// Pure LRU bookkeeping for a per-item texture cache. This type owns no Metal or image resources; it only
/// decides residency, pinning, in-flight upload de-duplication, per-frame upload budget, upload admission,
/// and eviction order.
///
/// Residency is bounded by a hybrid budget: `capacity` (texture count) and `costCapacity` (an opaque cost
/// unit - the Metal cache supplies real texture bytes). Both are enforced structurally: `canAdmitUpload`
/// refuses uploads that could not fit even after evicting every non-pinned resident, and `evictToBudget`
/// evicts least-recently-used non-pinned entries until BOTH budgets are satisfied. Pinned entries are never
/// evicted, so admission is what keeps the pinned working set from silently overflowing the budget.
///
/// Platform adapters provide their own memory budgets. The same policy must behave identically for macOS,
/// iOS, and iPadOS because IDs are generic and the policy has no UI, MetalKit, or PhotosCore dependency.
package struct GridTextureResidencyPolicy<ID: Hashable & Sendable>: Equatable {
    package enum DrawState: Equatable, Sendable {
        case real
        case placeholder
    }

    package let capacity: Int
    package let costCapacity: Int
    package let uploadBudgetPerFrame: Int

    package private(set) var resident: Set<ID> = []
    private var lastUsed: [ID: Int] = [:]
    private var cost: [ID: Int] = [:]
    private var inFlight: Set<ID> = []
    package private(set) var pinned: Set<ID> = []
    private var tick = 0
    package private(set) var evictionCount = 0
    package private(set) var residentCost = 0
    /// Cost/count of resident entries that are pinned this frame - the floor eviction can never go below.
    package private(set) var pinnedResidentCost = 0
    package private(set) var pinnedResidentCount = 0

    package init(capacity: Int, costCapacity: Int, uploadBudgetPerFrame: Int) {
        self.capacity = max(1, capacity)
        self.costCapacity = max(1, costCapacity)
        self.uploadBudgetPerFrame = max(1, uploadBudgetPerFrame)
    }

    package var residentCount: Int { resident.count }
    package var inFlightCount: Int { inFlight.count }
    package var pinnedCount: Int { pinned.count }

    /// What the renderer should draw for `id` this frame: the real texture if resident, else a placeholder.
    package func drawState(_ id: ID) -> DrawState { resident.contains(id) ? .real : .placeholder }
    package func isResident(_ id: ID) -> Bool { resident.contains(id) }
    package func isInFlight(_ id: ID) -> Bool { inFlight.contains(id) }

    /// Start a frame: advance the clock and pin the currently-protected (visible-first) set.
    package mutating func beginFrame(pinned: Set<ID>) {
        tick += 1
        self.pinned = pinned
        pinnedResidentCost = 0
        pinnedResidentCount = 0
        for id in pinned {
            if let c = cost[id] {
                pinnedResidentCost += c
                pinnedResidentCount += 1
            }
        }
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

    /// Whether uploading `id` at `cost` can end the frame within budget. Pinned entries can never be
    /// evicted, so a pinned upload is admitted only if the pinned-resident floor plus this upload still
    /// fits; an unpinned upload must fit the current totals outright (eviction may free room next frame,
    /// but admitting it now would just churn upload→evict inside one frame).
    package func canAdmitUpload(_ id: ID, cost uploadCost: Int) -> Bool {
        if pinned.contains(id) {
            return pinnedResidentCount < capacity && pinnedResidentCost + uploadCost <= costCapacity
        }
        return resident.count < capacity && residentCost + uploadCost <= costCapacity
    }

    /// Whether an already-resident texture can be replaced with a larger/smaller texture and still end the
    /// frame structurally admissible. Count is unchanged, so only the byte delta matters. Pinned replacements
    /// use the same visible-first floor as pinned uploads: offscreen residents may be evicted later to make
    /// room, but the pinned working set itself must fit inside the byte budget.
    package func canReplaceResident(_ id: ID, oldCost: Int, newCost: Int) -> Bool {
        guard resident.contains(id) else { return false }
        let oldCost = max(0, oldCost)
        let newCost = max(0, newCost)
        if pinned.contains(id) {
            return pinnedResidentCost - oldCost + newCost <= costCapacity
        }
        return residentCost - oldCost + newCost <= costCapacity
    }

    /// A texture upload finished: the ID is now resident at `cost` and freshly used.
    package mutating func completeUpload(_ id: ID, cost uploadCost: Int) {
        inFlight.remove(id)
        if !resident.insert(id).inserted, let previous = cost[id] {
            residentCost -= previous
            if pinned.contains(id) {
                pinnedResidentCost -= previous
                pinnedResidentCount -= 1
            }
        }
        cost[id] = uploadCost
        residentCost += uploadCost
        if pinned.contains(id) {
            pinnedResidentCost += uploadCost
            pinnedResidentCount += 1
        }
        lastUsed[id] = tick
    }

    /// A texture upload failed or was abandoned; clear the in-flight flag so it can be retried.
    package mutating func abandonUpload(_ id: ID) {
        inFlight.remove(id)
    }

    private var overBudget: Bool { resident.count > capacity || residentCost > costCapacity }

    /// Evict least-recently-used non-pinned textures until residency fits BOTH the count and the cost
    /// budget. Partial selection (never a full sort of the resident set): each pass heap-selects the k
    /// lowest-tick candidates, where k is exact for the count budget and estimated via the mean resident
    /// cost for the cost budget; eviction stops at the minimal LRU prefix that satisfies both budgets,
    /// looping only if the estimate under-shot.
    package mutating func evictToBudget() -> [ID] {
        var evicted: [ID] = []
        while overBudget {
            let countOver = max(0, resident.count - capacity)
            let costOver = residentCost > costCapacity ? residentCost - costCapacity : 0
            let averageCost = max(1, residentCost / max(1, resident.count))
            let costDrivenNeed = (costOver + averageCost - 1) / averageCost
            let evictionsNeeded = max(1, max(countOver, costDrivenNeed))
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

            guard !candidates.isEmpty else { break }   // only pinned residents remain - nothing evictable
            let selectionExhaustedNonPinned = candidates.count < evictionsNeeded
            candidates.sort { $0.tick < $1.tick }
            for candidate in candidates {
                guard overBudget else { break }
                resident.remove(candidate.id)
                lastUsed.removeValue(forKey: candidate.id)
                if let c = cost.removeValue(forKey: candidate.id) { residentCost -= c }
                evicted.append(candidate.id)
            }
            if selectionExhaustedNonPinned { break }   // evicted every non-pinned entry; the rest is pinned floor
        }
        evictionCount += evicted.count
        return evicted
    }
}
