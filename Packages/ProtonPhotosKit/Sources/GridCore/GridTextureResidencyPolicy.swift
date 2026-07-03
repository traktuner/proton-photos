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

    package func isPinned(_ id: ID) -> Bool { pinned.contains(id) }

    private func isOverBudget(maxCount: Int, maxCost: Int) -> Bool {
        resident.count > maxCount || residentCost > maxCost
    }

    /// The soft byte target `evictToBudget` sheds down to once the HARD cost budget is exceeded: a 10% headroom
    /// band below the ceiling (`costCapacity - costCapacity / 10`). Evicting to a band below the cap - rather
    /// than to the exact cap - stops residency oscillating at 100%, where every upload re-triggers a
    /// full-resident eviction scan. One eviction then frees room for many subsequent frames' uploads, so
    /// eviction runs far less often and visible uploads keep admission headroom. Integer-fraction based (no
    /// fixed byte amount), so it scales identically to the smaller iOS/iPadOS budgets. Never below 0.
    package var softCostTarget: Int { max(0, costCapacity - costCapacity / 10) }

    /// Evict least-recently-used non-pinned textures when residency exceeds the HARD budget, down to the soft
    /// byte target (a headroom band below the ceiling) and the count capacity. Pinned entries are never evicted.
    package mutating func evictToBudget() -> [ID] {
        guard isOverBudget(maxCount: capacity, maxCost: costCapacity) else { return [] }
        return evict(targetCount: capacity, targetCost: softCostTarget)
    }

    /// Memory-pressure response: shed non-pinned LRU residents down to a REDUCED ceiling. The ceiling
    /// is clamped to the normal budget, so this can only ever shrink residency, never grow it. Pinned
    /// (visible-first) entries are never evicted - so the visible working set stays drawable even at a
    /// `0` ceiling ("keep only what is visible"). Returns evicted IDs.
    package mutating func evictToReducedBudget(maxCount: Int, maxCost: Int) -> [ID] {
        evict(targetCount: min(capacity, max(0, maxCount)), targetCost: min(costCapacity, max(0, maxCost)))
    }

    /// Evict non-pinned residents oldest-first until BOTH `targetCount` and `targetCost` are satisfied.
    ///
    /// Single bounded pass: the resident set is scanned exactly ONCE into a min-heap keyed by LRU tick, then
    /// the oldest are extracted one at a time and evicted by ACTUAL cost until the budgets fit. Heapify is
    /// O(resident); each extraction is O(log resident) - so a small over-budget case evicts a short prefix
    /// without a full sort, and no case ever rescans the resident set. This replaces the earlier mean-cost
    /// estimate, which could under-shoot on heterogeneous L5 textures (oldest tiles cheaper than the mean) and
    /// rescan the whole resident set many times - the 20-40 ms L5 eviction spikes.
    private mutating func evict(targetCount: Int, targetCost: Int) -> [ID] {
        guard isOverBudget(maxCount: targetCount, maxCost: targetCost) else { return [] }

        var heap: [(id: ID, tick: Int)] = []
        heap.reserveCapacity(resident.count)
        for id in resident where !pinned.contains(id) {
            heap.append((id, lastUsed[id] ?? -1))
        }
        guard !heap.isEmpty else { return [] }   // only pinned residents remain - nothing evictable

        // Min-heap by tick (oldest = smallest tick at the root). Restore the heap property after moving the
        // last element to the root on each extraction.
        func siftDown(from index: Int) {
            var parent = index
            while true {
                let left = parent * 2 + 1
                guard left < heap.count else { return }
                let right = left + 1
                var smallest = left
                if right < heap.count, heap[right].tick < heap[left].tick { smallest = right }
                guard heap[smallest].tick < heap[parent].tick else { return }
                heap.swapAt(smallest, parent)
                parent = smallest
            }
        }
        for i in stride(from: heap.count / 2 - 1, through: 0, by: -1) { siftDown(from: i) }

        var evicted: [ID] = []
        while isOverBudget(maxCount: targetCount, maxCost: targetCost), !heap.isEmpty {
            let oldest = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty { heap[0] = last; siftDown(from: 0) }   // extract-min
            resident.remove(oldest.id)
            lastUsed.removeValue(forKey: oldest.id)
            if let c = cost.removeValue(forKey: oldest.id) { residentCost -= c }
            evicted.append(oldest.id)
        }
        evictionCount += evicted.count
        return evicted
    }
}
