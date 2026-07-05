import CryptoKit
import Foundation
import UploadCore

/// PhotoKit-free description of one photo-library asset - the mapper translates `PHAsset` +
/// `PHAssetResource` into this, and EVERY planning decision (what to export, how to fingerprint,
/// what candidate to emit) is pure logic over these values, fully covered by SPM tests.
public struct PhotoBackupAssetInfo: Sendable, Equatable {
    public struct Resource: Sendable, Equatable {
        /// Platform-neutral projection of `PHAssetResourceType`.
        public enum Role: String, Sendable, CaseIterable {
            case originalPhoto
            case fullSizePhoto
            case originalVideo
            case fullSizeVideo
            case pairedVideo
            case fullSizePairedVideo
            /// Any adjustment-related resource (adjustment data or pre-edit base variants):
            /// presence proves the asset has been content-edited at least once.
            case adjustmentEvidence
            case other
        }

        public var role: Role
        public var originalFilename: String
        public var mimeType: String?

        public init(role: Role, originalFilename: String, mimeType: String? = nil) {
            self.role = role
            self.originalFilename = originalFilename
            self.mimeType = mimeType
        }
    }

    public var localIdentifier: String
    public var creationDate: Date?
    public var modificationDate: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var durationSeconds: Double
    public var isLivePhoto: Bool
    public var isVideo: Bool
    public var resources: [Resource]

    public init(
        localIdentifier: String,
        creationDate: Date?,
        modificationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        durationSeconds: Double,
        isLivePhoto: Bool,
        isVideo: Bool,
        resources: [Resource]
    ) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
        self.isLivePhoto = isLivePhoto
        self.isVideo = isVideo
        self.resources = resources
    }

    public var hasEditEvidence: Bool {
        resources.contains { resource in
            switch resource.role {
            case .adjustmentEvidence, .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo:
                return true
            default:
                return false
            }
        }
    }
}

/// What to export for one asset: the CURRENT user-visible bytes (edited variants when present,
/// originals otherwise), each with the preserved original filename. Never a rendered/converted
/// image - roles map 1:1 to PhotoKit's original data resources.
public struct PhotoBackupExportPlan: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var role: PhotoBackupAssetInfo.Resource.Role
        /// The filename the upload carries. Always the asset's ORIGINAL user-facing name
        /// (IMG_1234.HEIC), never a synthetic edit-render name.
        public var uploadFilename: String
        public var mimeType: String?

        public init(role: PhotoBackupAssetInfo.Resource.Role, uploadFilename: String, mimeType: String?) {
            self.role = role
            self.uploadFilename = uploadFilename
            self.mimeType = mimeType
        }
    }

    public var primary: Item
    /// A Live Photo's paired video, when present.
    public var pairedVideo: Item?
}

/// Pure planning over `PhotoBackupAssetInfo`. No PhotoKit, no I/O.
public enum PhotoBackupAssetPlanner {

    /// The candidate the shared preflight classifies. Nil when the asset exposes no exportable
    /// primary resource (broken/placeholder assets are skipped, never guessed at).
    public static func candidate(for info: PhotoBackupAssetInfo) -> UploadBackupAssetCandidate? {
        guard let plan = exportPlan(for: info) else { return nil }
        let snapshot = UploadBackupAssetSnapshot(
            source: source(for: info),
            revision: metadataRevision(for: info),
            editRevision: editRevision(for: info),
            resourceCount: plan.pairedVideo == nil ? 1 : 2
        )
        return UploadBackupAssetCandidate(
            snapshot: snapshot,
            originalFilename: plan.primary.uploadFilename,
            byteCount: nil    // PHAssetResource exposes no official size pre-export on current OSes
        )
    }

    public static func source(for info: PhotoBackupAssetInfo) -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .photoLibraryAsset, identifier: info.localIdentifier, resource: .primary)
    }

    /// Metadata revision: PhotoKit moves `modificationDate` on content AND metadata changes, so
    /// this drifts often - the edit-revision evidence below keeps drift cheap for unedited assets.
    public static func metadataRevision(for info: PhotoBackupAssetInfo) -> UploadBackupRevision {
        UploadBackupRevision(date: info.modificationDate ?? info.creationDate ?? .distantPast)
    }

    /// Edit evidence, on the safe side of PhotoKit's official surface:
    /// - A NEVER-edited asset gets a structural fingerprint revision (resource roles + names +
    ///   dimensions + duration). Metadata-only changes (favorite, album) leave it untouched, so
    ///   preflight proves the asset already backed up WITHOUT export or hashing. The first
    ///   content edit always adds adjustment/full-size resources (official resource model), which
    ///   changes the structure → re-check.
    /// - An EDITED asset returns `.unavailable`: nothing official distinguishes edit N from
    ///   edit N+1 structurally, so every metadata drift re-verifies by hash. Safe over cheap.
    public static func editRevision(for info: PhotoBackupAssetInfo) -> UploadBackupEditRevision {
        guard !info.hasEditEvidence else { return .unavailable }
        return .revision(fingerprintRevision(for: info))
    }

    static func fingerprintRevision(for info: PhotoBackupAssetInfo) -> UploadBackupRevision {
        let parts = info.resources
            .map { "\($0.role.rawValue):\($0.originalFilename)" }
            .sorted()
            .joined(separator: "|")
        let material = "\(parts)#\(info.pixelWidth)x\(info.pixelHeight)#\(Int(info.durationSeconds * 1000))#live=\(info.isLivePhoto)"
        let digest = SHA256.hash(data: Data(material.utf8))
        var raw: Int64 = 0
        for byte in digest.prefix(8) { raw = (raw << 8) | Int64(byte) }
        // Positive, and never colliding with the µs-quantized date space of real timestamps is
        // not required - the preflight keys records by exact value either way.
        return UploadBackupRevision(rawValue: raw & 0x7FFF_FFFF_FFFF_FFFF)
    }

    /// Chooses the CURRENT user-visible resource set:
    /// photos: full-size edited render when present, else original; videos likewise; Live pairs:
    /// current paired video. Upload filenames always come from the ORIGINAL resource so the
    /// remote library keeps user-recognizable names.
    public static func exportPlan(for info: PhotoBackupAssetInfo) -> PhotoBackupExportPlan? {
        func resource(_ role: PhotoBackupAssetInfo.Resource.Role) -> PhotoBackupAssetInfo.Resource? {
            info.resources.first { $0.role == role }
        }

        let original = info.isVideo ? resource(.originalVideo) : resource(.originalPhoto)
        let edited = info.isVideo ? resource(.fullSizeVideo) : resource(.fullSizePhoto)
        guard let exported = edited ?? original else { return nil }
        let uploadName = original?.originalFilename ?? exported.originalFilename
        let primary = PhotoBackupExportPlan.Item(
            role: exported.role,
            uploadFilename: uploadName,
            mimeType: exported.mimeType ?? original?.mimeType
        )

        var paired: PhotoBackupExportPlan.Item?
        if info.isLivePhoto {
            let originalPaired = resource(.pairedVideo)
            let editedPaired = resource(.fullSizePairedVideo)
            if let exportedPaired = editedPaired ?? originalPaired {
                paired = PhotoBackupExportPlan.Item(
                    role: exportedPaired.role,
                    uploadFilename: originalPaired?.originalFilename ?? exportedPaired.originalFilename,
                    mimeType: exportedPaired.mimeType ?? originalPaired?.mimeType
                )
            }
        }
        return PhotoBackupExportPlan(primary: primary, pairedVideo: paired)
    }
}
