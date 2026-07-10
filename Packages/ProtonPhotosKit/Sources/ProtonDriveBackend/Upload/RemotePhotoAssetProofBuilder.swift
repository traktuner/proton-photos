import Foundation
import UploadCore

struct DedupeXAttr: Decodable {
    let common: Common?
    let iOSPhotos: IOSPhotos?

    enum CodingKeys: String, CodingKey {
        case common = "Common"
        case iOSPhotos = "iOS.photos"
    }

    struct Common: Decodable {
        let digests: Digests?
        enum CodingKeys: String, CodingKey { case digests = "Digests" }

        struct Digests: Decodable {
            let sha1: String?
            enum CodingKeys: String, CodingKey { case sha1 = "SHA1" }
        }
    }

    struct IOSPhotos: Decodable {
        let iCloudID: String?
        let modificationTime: String?
        enum CodingKeys: String, CodingKey {
            case iCloudID = "ICloudID"
            case modificationTime = "ModificationTime"
        }
    }
}

enum RemotePhotoAssetProofBuilder {
    static func records(
        photos: [PhotosListEntry],
        externalIdentitiesByLinkID: [String: UploadBackupExternalIdentity],
        hashKeyEpoch: String
    ) -> [UploadRemoteAssetIndexRecord] {
        var result: [UploadRemoteAssetIndexRecord] = []
        result.reserveCapacity(photos.count)
        var seen: Set<UploadBackupExternalIdentity> = []
        var ambiguous: Set<UploadBackupExternalIdentity> = []

        for photo in photos {
            let linkIDs = [photo.linkID] + photo.relatedPhotos.map(\.linkID)
            guard Set(linkIDs).count == linkIDs.count,
                  let identity = externalIdentitiesByLinkID[photo.linkID] else {
                continue
            }
            let allResourcesMatch = linkIDs.allSatisfy { linkID in
                externalIdentitiesByLinkID[linkID] == identity
            }
            guard allResourcesMatch else { continue }
            guard seen.insert(identity).inserted else {
                ambiguous.insert(identity)
                continue
            }
            result.append(UploadRemoteAssetIndexRecord(
                externalIdentity: identity,
                resourceCount: linkIDs.count,
                remoteLinkIDs: linkIDs,
                hashKeyEpoch: hashKeyEpoch
            ))
        }

        if !ambiguous.isEmpty {
            result.removeAll { ambiguous.contains($0.externalIdentity) }
        }
        return result
    }
}
