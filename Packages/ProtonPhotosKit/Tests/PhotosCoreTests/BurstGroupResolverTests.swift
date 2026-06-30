import XCTest
@testable import PhotosCore

final class BurstGroupResolverTests: XCTestCase {
    func testMergesOverlappingRelatedPhotoGroups() {
        let base = Date(timeIntervalSince1970: 1_000)
        let lookup = BurstGroupResolver.memberLookup(candidates: [
            BurstGroupCandidate(id: "a", relatedIDs: ["b"], captureTime: base.addingTimeInterval(2)),
            BurstGroupCandidate(id: "b", relatedIDs: ["c"], captureTime: base.addingTimeInterval(1)),
            BurstGroupCandidate(id: "c", relatedIDs: [], captureTime: base.addingTimeInterval(3)),
            BurstGroupCandidate(id: "z", relatedIDs: [], captureTime: base.addingTimeInterval(4)),
        ])

        XCTAssertEqual(lookup["a"], ["b", "a", "c"])
        XCTAssertEqual(lookup["b"], ["b", "a", "c"])
        XCTAssertEqual(lookup["c"], ["b", "a", "c"])
        XCTAssertNil(lookup["z"], "Singleton candidates are not actionable burst groups")
    }

    func testClustersBurstTaggedRowsWithoutRelatedEdgesByCaptureTime() {
        let base = Date(timeIntervalSince1970: 2_000)
        let lookup = BurstGroupResolver.memberLookup(
            candidates: [
                BurstGroupCandidate(id: "a", relatedIDs: [], captureTime: base),
                BurstGroupCandidate(id: "b", relatedIDs: [], captureTime: base.addingTimeInterval(0.4)),
                BurstGroupCandidate(id: "c", relatedIDs: [], captureTime: base.addingTimeInterval(0.8)),
                BurstGroupCandidate(id: "later", relatedIDs: [], captureTime: base.addingTimeInterval(9)),
            ],
            temporalClusterWindow: 2
        )

        XCTAssertEqual(lookup["a"], ["a", "b", "c"])
        XCTAssertEqual(lookup["b"], ["a", "b", "c"])
        XCTAssertEqual(lookup["c"], ["a", "b", "c"])
        XCTAssertNil(lookup["later"], "A single later burst-tagged photo is not enough to show a filmstrip")
    }

    func testRelatedEdgesDoNotMergeThroughTemporalFallback() {
        let base = Date(timeIntervalSince1970: 3_000)
        let lookup = BurstGroupResolver.memberLookup(
            candidates: [
                BurstGroupCandidate(id: "edgeA", relatedIDs: ["edgeB"], captureTime: base),
                BurstGroupCandidate(id: "edgeB", relatedIDs: [], captureTime: base.addingTimeInterval(0.1)),
                BurstGroupCandidate(id: "orphanA", relatedIDs: [], captureTime: base.addingTimeInterval(0.2)),
                BurstGroupCandidate(id: "orphanB", relatedIDs: [], captureTime: base.addingTimeInterval(0.3)),
            ],
            temporalClusterWindow: 2
        )

        XCTAssertEqual(lookup["edgeA"], ["edgeA", "edgeB"])
        XCTAssertEqual(lookup["edgeB"], ["edgeA", "edgeB"])
        XCTAssertEqual(lookup["orphanA"], ["orphanA", "orphanB"])
        XCTAssertEqual(lookup["orphanB"], ["orphanA", "orphanB"])
    }

    func testPhotoItemBurstMetadataIsCodableAndBackwardsCompatible() throws {
        let oldJSON = """
        {
          "uid": { "volumeID": "v", "nodeID": "n" },
          "captureTime": 0,
          "mediaType": "image/jpeg",
          "isLivePhoto": false,
          "tags": []
        }
        """.data(using: .utf8)!
        let oldItem = try JSONDecoder().decode(PhotoItem.self, from: oldJSON)
        XCTAssertEqual(oldItem.burstMemberIDs, [])
        XCTAssertFalse(oldItem.isBurstCandidate)

        let item = PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "b"),
            captureTime: Date(timeIntervalSince1970: 42),
            mediaType: "image/jpeg",
            tags: [.bursts],
            burstMemberIDs: ["a", "b", "c"]
        )
        let roundTrip = try JSONDecoder().decode(PhotoItem.self, from: JSONEncoder().encode(item))
        XCTAssertTrue(roundTrip.isBurstCandidate)
        XCTAssertEqual(roundTrip.burstMemberUIDs, [
            PhotoUID(volumeID: "v", nodeID: "a"),
            PhotoUID(volumeID: "v", nodeID: "b"),
            PhotoUID(volumeID: "v", nodeID: "c"),
        ])
    }
}
