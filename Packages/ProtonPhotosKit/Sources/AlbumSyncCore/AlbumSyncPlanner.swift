import Foundation

/// The attach plan for one album sync run, computed AFTER the backup step settled.
public struct AlbumSyncAttachPlan: Sendable, Equatable {
    /// Photos to attach, in local album order, deduplicated by remote link id.
    public var toAttach: [AlbumSyncAttachCandidate] = []
    /// Local assets whose remote photo is already in the album (no-op on re-run).
    public var alreadyMember = 0
    /// Local assets with no usable remote link (backup failed / asset missing) - honest gap.
    public var missingRemote = 0
    /// Local assets whose only remote copy sits in Proton trash - never attached, never re-uploaded.
    public var trashedRemote = 0
    /// Distinct local assets that resolved to an already-planned remote link (duplicate content
    /// across the album collapses to ONE attach).
    public var duplicatesCollapsed = 0

    public init() {}
}

/// Pure set-difference planning: local assets × manifest links × current album members → attach
/// actions. O(n) in the album size; no I/O, no async, fully deterministic - the perf and edge-case
/// tests pin this.
public enum AlbumSyncPlanner {
    public static func plan(
        orderedLocalIdentifiers: [String],
        remoteLinks: [String: AlbumSyncRemoteLink],
        existingChildLinkIDs: Set<String>
    ) -> AlbumSyncAttachPlan {
        var plan = AlbumSyncAttachPlan()
        var planned = Set<String>()
        planned.reserveCapacity(orderedLocalIdentifiers.count)
        var seenMembers = Set<String>()

        for identifier in orderedLocalIdentifiers {
            guard let link = remoteLinks[identifier] else {
                plan.missingRemote += 1
                continue
            }
            if link.isTrashed {
                plan.trashedRemote += 1
                continue
            }
            let linkID = link.uid.nodeID
            if existingChildLinkIDs.contains(linkID) {
                // Count each distinct member once even if several local assets map to it.
                if seenMembers.insert(linkID).inserted {
                    plan.alreadyMember += 1
                } else {
                    plan.duplicatesCollapsed += 1
                }
                continue
            }
            if planned.insert(linkID).inserted {
                plan.toAttach.append(AlbumSyncAttachCandidate(uid: link.uid, sha1Hex: link.sha1Hex))
            } else {
                plan.duplicatesCollapsed += 1
            }
        }
        return plan
    }
}
