import Foundation
import XCTest
import PhotoLibraryBackupAdapter
@testable import UploadCore

/// Pure planning layer of the PhotoKit adapter: candidate/fingerprint/export decisions over
/// platform-neutral asset descriptions - no PhotoKit, no photo access, runs everywhere.
final class PhotoBackupPlannerTests: XCTestCase {

    private func info(
        id: String = "asset-1",
        created: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        modified: Date? = Date(timeIntervalSince1970: 1_700_000_100),
        width: Int = 4032, height: Int = 3024,
        duration: Double = 0,
        live: Bool = false,
        video: Bool = false,
        resources: [PhotoBackupAssetInfo.Resource]
    ) -> PhotoBackupAssetInfo {
        PhotoBackupAssetInfo(
            localIdentifier: id, creationDate: created, modificationDate: modified,
            pixelWidth: width, pixelHeight: height, durationSeconds: duration,
            isLivePhoto: live, isVideo: video, resources: resources
        )
    }

    // MARK: Filenames and formats are preserved

    func testOriginalFilenameAndExtensionArePreserved() throws {
        let asset = info(resources: [
            .init(role: .originalPhoto, originalFilename: "IMG_1234.HEIC", mimeType: "image/heic")
        ])
        let plan = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: asset))
        XCTAssertEqual(plan.primary.uploadFilename, "IMG_1234.HEIC")
        XCTAssertEqual(plan.primary.mimeType, "image/heic")
        XCTAssertEqual(plan.primary.role, .originalPhoto)
        XCTAssertNil(plan.pairedVideo)
    }

    func testEditedPhotoExportsCurrentBytesAndPreservesOriginalResources() throws {
        let asset = info(resources: [
            .init(role: .originalPhoto, originalFilename: "IMG_1234.HEIC", mimeType: "image/heic"),
            .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.jpg", mimeType: "image/jpeg"),
            .init(role: .adjustmentData, originalFilename: "Adjustments.plist", mimeType: "application/octet-stream"),
        ])
        let plan = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: asset))
        XCTAssertEqual(plan.primary.role, .fullSizePhoto, "the CURRENT user-visible bytes are backed up")
        XCTAssertEqual(plan.primary.uploadFilename, "IMG_1234.jpg",
                       "the edited render keeps the original basename but gets an honest extension")
        XCTAssertEqual(
            plan.secondaries.map { "\($0.role.rawValue):\($0.uploadFilename)" },
            ["originalPhoto:IMG_1234.HEIC", "adjustmentData:Adjustments.plist"],
            "the untouched original and edit metadata must remain attached to the compound"
        )
        XCTAssertEqual(PhotoBackupAssetPlanner.candidate(for: asset)?.snapshot.resourceCount, 3)
    }

    func testRawAlternateIsBackedUpAsPartOfTheCompound() throws {
        let asset = info(resources: [
            .init(role: .originalPhoto, originalFilename: "IMG_7777.HEIC", mimeType: "image/heic"),
            .init(role: .alternatePhoto, originalFilename: "IMG_7777.DNG", mimeType: "image/x-adobe-dng"),
        ])

        let plan = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: asset))

        XCTAssertEqual(plan.primary.uploadFilename, "IMG_7777.HEIC")
        XCTAssertEqual(plan.secondaries.map(\.uploadFilename), ["IMG_7777.DNG"])
        XCTAssertEqual(plan.secondaries.map(\.sourceResource.rawValue), ["photoKit.alternatePhoto.0"])
        XCTAssertEqual(PhotoBackupAssetPlanner.candidate(for: asset)?.snapshot.resourceCount, 2)
    }

    func testVideoPrefersCurrentRenderAndKeepsMOV() throws {
        let asset = info(video: true, resources: [
            .init(role: .originalVideo, originalFilename: "IMG_5000.MOV", mimeType: "video/quicktime")
        ])
        let plan = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: asset))
        XCTAssertEqual(plan.primary.uploadFilename, "IMG_5000.MOV")
        XCTAssertEqual(plan.primary.mimeType, "video/quicktime")
    }

    // MARK: Live Photos are compounds

    func testLivePhotoBecomesTwoResourceCompound() throws {
        let asset = info(live: true, resources: [
            .init(role: .originalPhoto, originalFilename: "IMG_2000.HEIC", mimeType: "image/heic"),
            .init(role: .pairedVideo, originalFilename: "IMG_2000.MOV", mimeType: "video/quicktime"),
        ])
        let candidate = try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: asset))
        XCTAssertEqual(candidate.snapshot.resourceCount, 2)
        XCTAssertEqual(candidate.snapshot.source.kind, .photoLibraryAsset)
        XCTAssertEqual(candidate.snapshot.source.resource, .primary)
        let plan = try XCTUnwrap(PhotoBackupAssetPlanner.exportPlan(for: asset))
        XCTAssertEqual(plan.pairedVideo?.uploadFilename, "IMG_2000.MOV")
    }

    func testCatalogRoundTripRetainsExternalIdentityForProofReplay() throws {
        var asset = info(
            modified: Date(timeIntervalSince1970: 1_700_000_100.1234),
            resources: [.init(role: .originalPhoto, originalFilename: "IMG_1.HEIC")]
        )
        asset.cloudIdentifier = "icloud-asset"
        let entry = PhotoLibraryCatalogMapper.entry(for: asset, observedAt: Date())
        let replayed = PhotoLibraryCatalogMapper.info(for: entry)
        let candidate = try XCTUnwrap(PhotoBackupAssetPlanner.candidate(for: replayed))

        XCTAssertEqual(candidate.snapshot.externalIdentity?.identifier, "icloud-asset")
        XCTAssertEqual(
            candidate.snapshot.externalIdentity,
            UploadBackupExternalIdentity(
                identifier: "icloud-asset",
                modificationDate: Date(timeIntervalSince1970: 1_700_000_100.1234)
            )
        )
    }

    // MARK: Edit evidence (safe over cheap)

    func testUneditedAssetGetsStableFingerprintEvidence() {
        let resources: [PhotoBackupAssetInfo.Resource] = [
            .init(role: .originalPhoto, originalFilename: "IMG_1.HEIC", mimeType: "image/heic")
        ]
        let base = info(resources: resources)
        // Metadata-only drift: same resources, different modification date.
        let favorited = info(modified: Date(timeIntervalSince1970: 1_700_009_999), resources: resources)

        guard case let .revision(fpBase) = PhotoBackupAssetPlanner.editRevision(for: base),
              case let .revision(fpAfter) = PhotoBackupAssetPlanner.editRevision(for: favorited) else {
            return XCTFail("unedited assets must expose fingerprint evidence")
        }
        XCTAssertEqual(fpBase, fpAfter, "metadata-only changes must not move the fingerprint")
        XCTAssertNotEqual(fpBase, PhotoBackupAssetPlanner.metadataRevision(for: base),
                          "fingerprint must be distinct from the metadata revision")
    }

    func testEditedAssetRefusesFingerprintTrust() {
        let edited = info(resources: [
            .init(role: .originalPhoto, originalFilename: "IMG_1.HEIC", mimeType: nil),
            .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.jpg", mimeType: nil),
        ])
        XCTAssertEqual(PhotoBackupAssetPlanner.editRevision(for: edited), .unavailable,
                       "edited assets must re-verify by hash - never trust a structural fingerprint")
    }

    func testFirstEditChangesTheFingerprint() {
        let before = info(resources: [
            .init(role: .originalPhoto, originalFilename: "IMG_1.HEIC", mimeType: nil)
        ])
        let after = info(resources: [
            .init(role: .originalPhoto, originalFilename: "IMG_1.HEIC", mimeType: nil),
            .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.jpg", mimeType: nil),
        ])
        guard case .revision = PhotoBackupAssetPlanner.editRevision(for: before) else {
            return XCTFail("unedited baseline expected")
        }
        XCTAssertEqual(PhotoBackupAssetPlanner.editRevision(for: after), .unavailable,
                       "the first edit adds adjustment resources and must invalidate fingerprint trust")
    }

    // MARK: Metadata-only drift skips export entirely (preflight round trip)

    func testMetadataOnlyChangeClassifiesAlreadyBackedUpWithoutRecheck() async throws {
        final class MemoryStore: UploadBackupStateStore, @unchecked Sendable {
            private let lock = NSLock()
            private var rows: [UploadSourceIdentity: [UploadBackupRevision: UploadBackupAssetRecord]] = [:]
            func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? {
                lock.withLock { rows[source]?[revision] }
            }
            func hasAnyRecord(for source: UploadSourceIdentity) -> Bool {
                lock.withLock { !(rows[source]?.isEmpty ?? true) }
            }
            func upsert(_ record: UploadBackupAssetRecord) -> Bool {
                lock.withLock { rows[record.source, default: [:]][record.revision] = record }
                return true
            }
            func count() -> Int { lock.withLock { rows.values.reduce(0) { $0 + $1.count } } }
        }

        let resources: [PhotoBackupAssetInfo.Resource] = [
            .init(role: .originalPhoto, originalFilename: "IMG_1.HEIC", mimeType: nil)
        ]
        let original = info(resources: resources)
        let favorited = info(modified: Date(timeIntervalSince1970: 1_700_050_000), resources: resources)

        let index = UploadBackupPreflightIndex(store: MemoryStore())
        let originalSnapshot = PhotoBackupAssetPlanner.candidate(for: original)!.snapshot
        try await index.markBackedUp(originalSnapshot)

        let decision = try await index.classify(PhotoBackupAssetPlanner.candidate(for: favorited)!.snapshot)
        XCTAssertEqual(decision, .alreadyBackedUp,
                       "a favorite toggle must not export, hash, or query anything")
    }

    // MARK: Broken assets

    func testAssetWithoutExportableResourceIsSkipped() {
        let broken = info(resources: [
            .init(role: .adjustmentData, originalFilename: "Adjustments.plist", mimeType: nil)
        ])
        XCTAssertNil(PhotoBackupAssetPlanner.candidate(for: broken))
    }

    // MARK: Access states

    func testAccessStateBackupGating() {
        XCTAssertTrue(PhotoBackupAccessState.full.allowsBackup)
        XCTAssertTrue(PhotoBackupAccessState.limited.allowsBackup, "limited access backs up the selection honestly")
        XCTAssertFalse(PhotoBackupAccessState.denied.allowsBackup)
        XCTAssertFalse(PhotoBackupAccessState.notDetermined.allowsBackup)
        XCTAssertFalse(PhotoBackupAccessState.restricted.allowsBackup)
    }
}
