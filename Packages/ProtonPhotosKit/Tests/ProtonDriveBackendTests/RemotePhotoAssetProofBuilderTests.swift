import Foundation
import XCTest
@testable import ProtonDriveBackend
@testable import UploadCore

final class RemotePhotoAssetProofBuilderTests: XCTestCase {
    private func attributes(cloudID: String, modificationTime: String) throws -> DedupeXAttr {
        let object: [String: Any] = [
            "Common": ["Digests": ["SHA1": "0123456789abcdef"]],
            "iOS.photos": [
                "ICloudID": cloudID,
                "ModificationTime": modificationTime,
            ],
        ]
        return try JSONDecoder().decode(
            DedupeXAttr.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    func testDecodesOfficialIOSPhotosExtendedAttributeShape() throws {
        let decoded = try attributes(
            cloudID: "icloud-id",
            modificationTime: "2026-07-10T07:00:00.123Z"
        )

        XCTAssertEqual(decoded.iOSPhotos?.iCloudID, "icloud-id")
        XCTAssertEqual(decoded.iOSPhotos?.modificationTime, "2026-07-10T07:00:00.123Z")
        XCTAssertEqual(decoded.common?.digests?.sha1, "0123456789abcdef")
    }

    func testBuildsSimpleAndCompoundProofsFromExactEncryptedMetadata() throws {
        let timestamp = "2026-07-10T07:00:00.123Z"
        let photos = [
            PhotosListEntry(linkID: "simple", captureTime: 0, tags: [], relatedPhotos: []),
            PhotosListEntry(
                linkID: "live-primary",
                captureTime: 0,
                tags: [3],
                relatedPhotos: [.init(linkID: "live-video")]
            ),
        ]
        let records = RemotePhotoAssetProofBuilder.records(
            photos: photos,
            externalIdentitiesByLinkID: [
                "simple": identity(cloudID: "cloud-simple", timestamp: timestamp),
                "live-primary": identity(cloudID: "cloud-live", timestamp: timestamp),
                "live-video": identity(cloudID: "cloud-live", timestamp: timestamp),
            ],
            hashKeyEpoch: "epoch-1"
        )

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first { $0.externalIdentity.identifier == "cloud-simple" }?.resourceCount, 1)
        XCTAssertEqual(records.first { $0.externalIdentity.identifier == "cloud-live" }?.remoteLinkIDs,
                       ["live-primary", "live-video"])
    }

    func testRejectsCompoundWhenAnyRelatedMetadataDiffers() throws {
        let photos = [PhotosListEntry(
            linkID: "primary",
            captureTime: 0,
            tags: [3],
            relatedPhotos: [.init(linkID: "video")]
        )]
        let records = RemotePhotoAssetProofBuilder.records(
            photos: photos,
            externalIdentitiesByLinkID: [
                "primary": identity(cloudID: "cloud-live", timestamp: "2026-07-10T07:00:00.123Z"),
                "video": identity(cloudID: "cloud-live", timestamp: "2026-07-10T07:00:01.123Z"),
            ],
            hashKeyEpoch: "epoch-1"
        )

        XCTAssertTrue(records.isEmpty)
    }

    func testRejectsAmbiguousDuplicateExternalIdentity() throws {
        let timestamp = "2026-07-10T07:00:00Z"
        let photos = [
            PhotosListEntry(linkID: "one", captureTime: 0, tags: [], relatedPhotos: []),
            PhotosListEntry(linkID: "two", captureTime: 0, tags: [], relatedPhotos: []),
        ]
        let metadata = identity(cloudID: "same-cloud-id", timestamp: timestamp)
        let records = RemotePhotoAssetProofBuilder.records(
            photos: photos,
            externalIdentitiesByLinkID: ["one": metadata, "two": metadata],
            hashKeyEpoch: "epoch-1"
        )

        XCTAssertTrue(records.isEmpty)
    }

    private func identity(cloudID: String, timestamp: String) -> UploadBackupExternalIdentity {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = timestamp.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return UploadBackupExternalIdentity(
            identifier: cloudID,
            modificationDate: formatter.date(from: timestamp)!
        )
    }
}
