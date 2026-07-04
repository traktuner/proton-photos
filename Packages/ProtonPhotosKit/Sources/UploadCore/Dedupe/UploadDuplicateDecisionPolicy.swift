import Foundation

/// The Proton duplicate decision tree - ONE implementation for every platform, reproducing the
/// remote-visible behaviour of Proton Drive iOS 1.61.0 (`PhotoConflictRemoteCheckValidator` +
/// `PhotoConflictNameHashesStrategy`, reimplemented from observed semantics):
///
/// 1. Name-hash disjointness: when no remote item carries any of the compound's name hashes, the
///    compound uploads without any content comparison.
/// 2. Draft pre-filter: ANY remote draft occupying the primary's name hash skips the compound
///    (no clientUID matching - Proton doesn't do it at this stage either).
/// 3. The primary's remote match requires name hash AND content hash to both match. No such item
///    → upload as a brand-new photo under the SAME name (photo shares tolerate duplicate name
///    hashes; a name-only collision never blocks or renames).
/// 4. A matched primary decides by link state: active → check secondaries; trashed → skip
///    (deliberate deletion); state absent → skip (deleted); active without a link id → skip as
///    inconsistent.
/// 5. A secondary counts as already uploaded iff some remote item matches its name hash AND
///    (matches its content hash OR is a draft). All uploaded → skip; otherwise upload only the
///    missing secondaries via `mainPhotoUid`.
public enum UploadDuplicateDecisionPolicy {

    /// One hashed resource of the compound, as the policy sees it.
    public struct Resource: Sendable, Equatable {
        public let source: UploadSourceIdentity
        public let nameHash: String
        public let contentHash: String

        public init(source: UploadSourceIdentity, nameHash: String, contentHash: String) {
            self.source = source
            self.nameHash = nameHash
            self.contentHash = contentHash
        }
    }

    public static func decide(
        primary: Resource,
        secondaries: [Resource] = [],
        remoteItems: [RemotePhotoDuplicate]
    ) -> UploadDuplicateDecision {
        // 1. Disjoint name hashes → clean compound, no content comparison needed.
        let localNameHashes = Set([primary.nameHash] + secondaries.map(\.nameHash))
        guard remoteItems.contains(where: { localNameHashes.contains($0.nameHash) }) else {
            return .upload
        }

        // 2. A draft occupying the primary's name hash blocks the whole compound.
        let primaryNameMatches = remoteItems.filter { $0.nameHash == primary.nameHash }
        if primaryNameMatches.contains(where: { $0.linkState == .draft }) {
            return .skip(.draftExists, remoteLinkID: nil)
        }

        // 3. The primary's true remote twin: name hash AND content hash both match.
        guard let remotePrimary = primaryNameMatches.first(where: { $0.contentHash == primary.contentHash }) else {
            return .upload
        }

        // 4. Link state decides.
        switch remotePrimary.linkState {
        case .draft:
            // Unreachable in practice (step 2 catches drafts) - kept for exactness.
            return .skip(.draftExists, remoteLinkID: remotePrimary.linkID)
        case .trashed:
            return .skip(.trashedDuplicate, remoteLinkID: remotePrimary.linkID)
        case nil:
            return .skip(.deletedRemotely, remoteLinkID: remotePrimary.linkID)
        case .active:
            guard let primaryLinkID = remotePrimary.linkID else {
                return .skip(.inconsistentRemoteState, remoteLinkID: nil)
            }
            // 5. Secondary completeness.
            let missing = secondaries.filter { secondary in
                !remoteItems.contains { remote in
                    remote.nameHash == secondary.nameHash
                        && (remote.contentHash == secondary.contentHash || remote.linkState == .draft)
                }
            }
            if missing.isEmpty {
                return .skip(.activeDuplicate, remoteLinkID: primaryLinkID)
            }
            return .uploadMissingSecondaries(primaryLinkID: primaryLinkID, missing: missing.map(\.source))
        }
    }
}
