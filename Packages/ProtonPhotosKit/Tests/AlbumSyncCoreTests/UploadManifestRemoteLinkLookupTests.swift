import Testing
import Foundation
import PhotosCore
import UploadCore
@testable import AlbumSyncCore

/// Integration of the album-sync link lookup against a REAL upload identity manifest database -
/// the exact store the dedupe pipeline writes.
@Suite struct UploadManifestRemoteLinkLookupTests {

    private func makeManifest() throws -> (store: UploadIdentityManifestStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("album-sync-lookup-\(UUID().uuidString).sqlite")
        let store = try #require(UploadIdentityManifestStore(url: url))
        return (store, url)
    }

    private func record(
        assetID: String,
        resource: UploadSourceIdentity.Resource,
        linkID: String?,
        outcome: UploadIdentityManifestStore.Outcome?
    ) -> UploadIdentityRecord {
        UploadIdentityRecord(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: assetID, resource: resource),
            filename: "IMG_0001.HEIC",
            correctedName: "IMG_0001.HEIC",
            fileSize: 1234,
            modificationDate: Date(timeIntervalSinceReferenceDate: 1000),
            sha1Hex: "abc123",
            nameHash: "nh",
            contentHash: "ch",
            hashKeyEpoch: "epoch1",
            remoteVolumeID: linkID == nil ? nil : "vol1",
            remoteLinkID: linkID,
            outcome: outcome?.rawValue,
            updatedAt: Date(timeIntervalSinceReferenceDate: 1000)
        )
    }

    @Test func returnsPrimaryLinksOnlyNeverLivePhotoSecondaries() async throws {
        let (store, url) = try makeManifest()
        // A Live Photo: primary photo + paired video, both uploaded.
        store.upsert(record(assetID: "asset-1", resource: .primary, linkID: "l-main", outcome: .uploaded))
        store.upsert(record(assetID: "asset-1", resource: .livePairedVideo, linkID: "l-video", outcome: .uploaded))
        store.close()

        let lookup = try #require(UploadManifestRemoteLinkLookup(manifestURL: url, policy: .conservative))
        let links = await lookup.remoteLinks(for: ["asset-1"])
        // Only the MAIN photo is attachable; the paired video follows it server-side.
        #expect(links["asset-1"]?.uid.nodeID == "l-main")
        #expect(links["asset-1"]?.sha1Hex == "abc123")
        #expect(links["asset-1"]?.isTrashed == false)
    }

    @Test func mapsDuplicateOutcomesAndSkipsUnfinishedRows() async throws {
        let (store, url) = try makeManifest()
        store.upsert(record(assetID: "uploaded", resource: .primary, linkID: "l-1", outcome: .uploaded))
        store.upsert(record(assetID: "duplicate", resource: .primary, linkID: "l-2", outcome: .duplicateActive))
        store.upsert(record(assetID: "trashed", resource: .primary, linkID: "l-3", outcome: .duplicateTrashed))
        store.upsert(record(assetID: "pending", resource: .primary, linkID: nil, outcome: nil))
        store.close()

        let lookup = try #require(UploadManifestRemoteLinkLookup(manifestURL: url, policy: .conservative))
        let links = await lookup.remoteLinks(for: ["uploaded", "duplicate", "trashed", "pending", "unknown"])
        #expect(links["uploaded"]?.uid.nodeID == "l-1")
        #expect(links["duplicate"]?.uid.nodeID == "l-2")
        #expect(links["trashed"]?.isTrashed == true)
        #expect(links["pending"] == nil)
        #expect(links["unknown"] == nil)
        #expect(links.count == 3)
    }
}
