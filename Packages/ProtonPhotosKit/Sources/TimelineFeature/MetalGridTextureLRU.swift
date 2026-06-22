import PhotosCore

/// Pure LRU bookkeeping for the per-image GPU texture cache — no Metal, so the eviction / pinning /
/// dedup / per-frame-budget policy is unit-testable headlessly (`MetalGridTextureCacheTests`). The
/// Metal-backed `MetalGridTextureCache` owns the actual `MTLTexture`s and delegates every residency
/// decision to this type.
///
/// Guarantees the spec requires:
///  • visible (pinned) items are NEVER evicted,
///  • offscreen items are evicted once the budget is exceeded (least-recently-used first),
///  • the same UID is never uploaded twice concurrently (in-flight dedup),
///  • per-frame upload count is bounded,
///  • geometry never depends on texture residency (residency is tracked here; rects come from layout).
struct MetalGridTextureLRU: Equatable {
    enum DrawState: Equatable { case real, placeholder }

    let capacity: Int
    let uploadBudgetPerFrame: Int

    private(set) var resident: Set<PhotoUID> = []
    private var lastUsed: [PhotoUID: Int] = [:]
    private var inFlight: Set<PhotoUID> = []
    private(set) var pinned: Set<PhotoUID> = []
    private var tick = 0
    private(set) var evictionCount = 0

    init(capacity: Int, uploadBudgetPerFrame: Int) {
        self.capacity = max(1, capacity)
        self.uploadBudgetPerFrame = max(1, uploadBudgetPerFrame)
    }

    var residentCount: Int { resident.count }
    var inFlightCount: Int { inFlight.count }
    var pinnedCount: Int { pinned.count }

    /// What the renderer should draw for `uid` this frame: the real texture if resident, else a
    /// placeholder (always available — there is never a transparent hole).
    func drawState(_ uid: PhotoUID) -> DrawState { resident.contains(uid) ? .real : .placeholder }
    func isResident(_ uid: PhotoUID) -> Bool { resident.contains(uid) }
    func isInFlight(_ uid: PhotoUID) -> Bool { inFlight.contains(uid) }

    /// Start a frame: advance the clock and pin the currently-visible set (pinned items survive eviction).
    mutating func beginFrame(pinned: Set<PhotoUID>) {
        tick += 1
        self.pinned = pinned
    }

    /// Mark a resident texture as used this frame (refreshes its LRU recency). Visible + overscan items
    /// call this so they sort to the front of the cache.
    mutating func noteUsed(_ uid: PhotoUID) {
        if resident.contains(uid) { lastUsed[uid] = tick }
    }

    /// Pick up to `uploadBudgetPerFrame` UIDs from `wanted` (priority order — visible first) that are not
    /// already resident and not already in flight, and mark them in flight (so they can't be uploaded
    /// twice). Returns the chosen UIDs for the caller to actually upload.
    mutating func selectUploads(wanted: [PhotoUID]) -> [PhotoUID] {
        var chosen: [PhotoUID] = []
        for uid in wanted {
            guard chosen.count < uploadBudgetPerFrame else { break }
            guard !resident.contains(uid), !inFlight.contains(uid) else { continue }
            inFlight.insert(uid)
            chosen.append(uid)
        }
        return chosen
    }

    /// A texture upload finished: the UID is now resident (and freshly used).
    mutating func completeUpload(_ uid: PhotoUID) {
        inFlight.remove(uid)
        resident.insert(uid)
        lastUsed[uid] = tick
    }

    /// A texture upload failed/was abandoned: clear the in-flight flag so it can be retried later.
    mutating func abandonUpload(_ uid: PhotoUID) {
        inFlight.remove(uid)
    }

    /// Evict least-recently-used NON-pinned textures until residency fits the capacity budget. Returns
    /// the evicted UIDs so the caller can release their `MTLTexture`s.
    mutating func evictToBudget() -> [PhotoUID] {
        guard resident.count > capacity else { return [] }
        let evictable = resident.subtracting(pinned)
        // Oldest first (smallest lastUsed tick; unseen → -1 so they go first).
        let ordered = evictable.sorted { (lastUsed[$0] ?? -1) < (lastUsed[$1] ?? -1) }
        var evicted: [PhotoUID] = []
        var count = resident.count
        for uid in ordered where count > capacity {
            resident.remove(uid)
            lastUsed.removeValue(forKey: uid)
            evicted.append(uid)
            count -= 1
        }
        evictionCount += evicted.count
        return evicted
    }
}
