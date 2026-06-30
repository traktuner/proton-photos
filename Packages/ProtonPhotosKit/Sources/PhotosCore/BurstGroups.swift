import Foundation

/// A lightweight, backend-neutral description of one server-reported burst edge.
///
/// Proton's REST photo listing exposes burst membership through a photo's own link ID plus
/// `RelatedPhotos`. Different entries in the same series may report overlapping related sets, so callers
/// should not assume a single row is the complete group. `BurstGroupResolver` merges those overlaps into
/// deterministic groups that every platform can consume.
public struct BurstGroupCandidate: Equatable, Sendable {
    public let id: String
    public let relatedIDs: [String]
    public let captureTime: Date

    public init(id: String, relatedIDs: [String], captureTime: Date) {
        self.id = id
        self.relatedIDs = relatedIDs
        self.captureTime = captureTime
    }
}

public enum BurstGroupResolver {
    /// Returns `memberID -> full group member IDs`, with every group sorted by capture time and then ID.
    /// Singleton candidates are intentionally omitted; the viewer only needs groups with multiple choices.
    ///
    /// Proton deployments can expose burst photos in two shapes:
    /// 1. explicit `RelatedPhotos` edges, which are authoritative and may overlap;
    /// 2. burst-tagged rows without edges, where the only reliable grouping signal is that the captures are
    ///    adjacent in time. The temporal fallback is deliberately narrow so unrelated bursts are not merged.
    public static func memberLookup(candidates: [BurstGroupCandidate],
                                    temporalClusterWindow: TimeInterval = 2.0) -> [String: [String]] {
        guard !candidates.isEmpty else { return [:] }

        var captureTimes: [String: Date] = [:]
        var groups: [Set<String>] = []

        for candidate in candidates {
            captureTimes[candidate.id] = candidate.captureTime
            let ids = Set(([candidate.id] + candidate.relatedIDs).filter { !$0.isEmpty })
            guard ids.count > 1 else { continue }
            for id in ids where captureTimes[id] == nil { captureTimes[id] = candidate.captureTime }

            var merged = ids
            var retained: [Set<String>] = []
            for group in groups {
                if group.isDisjoint(with: merged) {
                    retained.append(group)
                } else {
                    merged.formUnion(group)
                }
            }
            retained.append(merged)
            groups = retained
        }

        let groupedExplicitIDs = Set(groups.flatMap { $0 })
        let temporalCandidates = candidates
            .filter { !groupedExplicitIDs.contains($0.id) }
            .sorted {
                if $0.captureTime == $1.captureTime { return $0.id < $1.id }
                return $0.captureTime < $1.captureTime
            }
        var temporalCluster: [BurstGroupCandidate] = []

        func flushTemporalCluster() {
            guard temporalCluster.count > 1 else {
                temporalCluster.removeAll(keepingCapacity: true)
                return
            }
            groups.append(Set(temporalCluster.map(\.id)))
            temporalCluster.removeAll(keepingCapacity: true)
        }

        for candidate in temporalCandidates {
            if let previous = temporalCluster.last,
               candidate.captureTime.timeIntervalSince(previous.captureTime) > temporalClusterWindow {
                flushTemporalCluster()
            }
            temporalCluster.append(candidate)
        }
        flushTemporalCluster()

        var lookup: [String: [String]] = [:]
        for group in groups where group.count > 1 {
            let sorted = group.sorted {
                let lt = captureTimes[$0] ?? .distantPast
                let rt = captureTimes[$1] ?? .distantPast
                if lt == rt { return $0 < $1 }
                return lt < rt
            }
            for id in sorted { lookup[id] = sorted }
        }
        return lookup
    }
}
