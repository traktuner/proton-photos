import Foundation
import UploadCore

/// Bridges the planner's PhotoKit-free `PhotoBackupAssetInfo` to the Core catalog's
/// `PhotoLibraryCatalogEntry`. Pure logic over plain values - no PhotoKit, no I/O - so the catalog's
/// change detection is fully testable off-device.
///
/// The catalog's two revision fields are deliberately the SAME values the backup planner uses:
/// `contentFingerprint` is the structural fingerprint (a metadata-only change never moves it) and
/// `metadataRevision` is the modification-date revision. This keeps "the catalog thinks it changed"
/// aligned with "the preflight would re-check it", so a catalogued change is a meaningful signal.
public enum PhotoLibraryCatalogMapper {

    public static func entry(for info: PhotoBackupAssetInfo, observedAt: Date) -> PhotoLibraryCatalogEntry {
        PhotoLibraryCatalogEntry(
            localIdentifier: info.localIdentifier,
            creationDate: info.creationDate,
            modificationDate: info.modificationDate,
            pixelWidth: info.pixelWidth,
            pixelHeight: info.pixelHeight,
            durationSeconds: info.durationSeconds,
            mediaKind: info.isVideo ? .video : .image,
            isLivePhoto: info.isLivePhoto,
            resources: info.resources.map {
                PhotoLibraryCatalogResource(
                    role: $0.role.rawValue,
                    originalFilename: $0.originalFilename,
                    mimeType: $0.mimeType,
                    ordinal: $0.ordinal
                )
            },
            contentFingerprint: PhotoBackupAssetPlanner.fingerprintRevision(for: info).rawValue,
            metadataRevision: PhotoBackupAssetPlanner.metadataRevision(for: info).rawValue,
            firstSeenAt: observedAt,
            lastSeenAt: observedAt
        )
    }
}
