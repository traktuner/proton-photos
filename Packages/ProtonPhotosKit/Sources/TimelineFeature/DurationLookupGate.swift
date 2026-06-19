import PhotosCore

/// Bounds the number of concurrent video-duration metadata lookups the grid runs. A dense video
/// section can ask dozens of visible cells to resolve their duration at once; without a cap each one
/// spawns its own metadata/network task. This pure value type tracks which uids are in flight, which
/// are queued, and which have already completed, so the coordinator can admit at most `maxConcurrent`
/// at a time, coalesce duplicate requests for the same uid, and promote one queued uid each time an
/// active lookup finishes. It holds no `IndexPath`/cell state — the coordinator maps uid→cell itself.
struct DurationLookupGate: Equatable {
    let maxConcurrent: Int

    private(set) var active: Set<PhotoUID> = []
    private(set) var queue: [PhotoUID] = []
    private var queued: Set<PhotoUID> = []
    private(set) var completed: Set<PhotoUID> = []

    init(maxConcurrent: Int = 4) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    var activeCount: Int { active.count }
    var queuedCount: Int { queue.count }

    enum Decision: Equatable {
        case start    // admitted now — caller should launch the lookup
        case queued   // capacity full — caller should remember it; the gate will promote it later
        case ignored  // already active, queued, or completed — caller does nothing
    }

    /// Registers interest in `uid`. Returns whether the caller should start it now, hold it, or drop it
    /// (a duplicate / already-resolved request).
    mutating func request(_ uid: PhotoUID) -> Decision {
        guard !completed.contains(uid), !active.contains(uid), !queued.contains(uid) else { return .ignored }
        if active.count < maxConcurrent {
            active.insert(uid)
            return .start
        }
        queue.append(uid)
        queued.insert(uid)
        return .queued
    }

    /// Marks `uid` finished and, if a queued uid can now run, admits and returns it (already moved into
    /// `active`); the caller launches it. Returns `nil` when nothing is waiting.
    mutating func complete(_ uid: PhotoUID) -> PhotoUID? {
        active.remove(uid)
        completed.insert(uid)
        while !queue.isEmpty, active.count < maxConcurrent {
            let next = queue.removeFirst()
            queued.remove(next)
            guard !completed.contains(next), !active.contains(next) else { continue }
            active.insert(next)
            return next
        }
        return nil
    }
}
