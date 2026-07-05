import Foundation
import XCTest
@testable import UploadCore

final class PhotoUploadMetadataEncoderTests: XCTestCase {
    func testEncodesProtonPhotoXAttrSections() throws {
        let metadata = try PhotoUploadMetadataEncoder.metadata(
            location: .init(latitude: 48.2082, longitude: 16.3738),
            camera: .init(captureTime: "2026-07-05T10:00:00.000Z", device: "iPhone", orientation: 1),
            media: .init(width: 4032, height: 3024, duration: nil),
            iOSPhotos: .init(iCloudID: "cloud-id", modificationTime: "2026-07-05T10:01:00.000Z")
        )

        XCTAssertEqual(metadata.map(\.name), ["Location", "Camera", "Media", "iOS.photos"])
        XCTAssertEqual(try json(metadata[0])["Latitude"] as? Double, 48.2082)
        XCTAssertEqual(try json(metadata[0])["Longitude"] as? Double, 16.3738)
        XCTAssertEqual(try json(metadata[1])["CaptureTime"] as? String, "2026-07-05T10:00:00.000Z")
        XCTAssertEqual(try json(metadata[1])["Device"] as? String, "iPhone")
        XCTAssertEqual(try json(metadata[1])["Orientation"] as? Int, 1)
        XCTAssertEqual(try json(metadata[2])["Width"] as? Int, 4032)
        XCTAssertEqual(try json(metadata[2])["Height"] as? Int, 3024)
        XCTAssertNil(try json(metadata[2])["Duration"])
        XCTAssertEqual(try json(metadata[3])["ICloudID"] as? String, "cloud-id")
        XCTAssertEqual(try json(metadata[3])["ModificationTime"] as? String, "2026-07-05T10:01:00.000Z")
    }

    func testApplyingIdentityPreservesAdditionalMetadata() {
        let metadata = PhotoUploadAdditionalMetadata(name: "Media", utf8JsonValue: Data(#"{"Width":1}"#.utf8))
        let request = PhotoUploadRequest(
            queueItemID: UUID(),
            cancellationToken: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/photo.heic"),
            name: "photo.heic",
            mediaType: "image/heic",
            fileSize: 10,
            captureTime: Date(timeIntervalSince1970: 1),
            modificationDate: Date(timeIntervalSince1970: 2),
            tags: [],
            additionalMetadata: [metadata]
        )

        let identity = UploadIdentity(
            correctedName: "photo-corrected.heic",
            nameHash: "name",
            sha1Hex: "0123456789012345678901234567890123456789",
            sha1Digest: Data(repeating: 1, count: 20),
            contentHash: "content"
        )

        let applied = request.applying(identity: identity)
        XCTAssertEqual(applied.name, "photo-corrected.heic")
        XCTAssertEqual(applied.additionalMetadata, [metadata])
    }

    private func json(_ metadata: PhotoUploadAdditionalMetadata) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: metadata.utf8JsonValue) as? [String: Any])
    }
}
