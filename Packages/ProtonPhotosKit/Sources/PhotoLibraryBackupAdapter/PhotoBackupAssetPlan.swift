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
            case alternatePhoto
            case fullSizePhoto
            case originalVideo
            case audio
            case fullSizeVideo
            case pairedVideo
            case fullSizePairedVideo
            case adjustmentData
            case adjustmentBasePhoto
            case adjustmentBaseVideo
            case adjustmentBasePairedVideo
            case photoProxy
            case other
        }

        public var role: Role
        public var originalFilename: String
        public var mimeType: String?
        /// Stable ordinal among resources with the same role after deterministic sorting.
        public var ordinal: Int

        public init(role: Role, originalFilename: String, mimeType: String? = nil, ordinal: Int = 0) {
            self.role = role
            self.originalFilename = originalFilename
            self.mimeType = mimeType
            self.ordinal = ordinal
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
    /// Stable iCloud identity when PhotoKit can provide one. Discovery resolves these in batches;
    /// Core treats it as upload metadata, never as the local lookup key.
    public var cloudIdentifier: String?

    public init(
        localIdentifier: String,
        creationDate: Date?,
        modificationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        durationSeconds: Double,
        isLivePhoto: Bool,
        isVideo: Bool,
        resources: [Resource],
        cloudIdentifier: String? = nil
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
        self.cloudIdentifier = cloudIdentifier
    }

    public var hasEditEvidence: Bool {
        resources.contains { resource in
            switch resource.role {
            case .adjustmentData, .adjustmentBasePhoto, .adjustmentBaseVideo,
                 .adjustmentBasePairedVideo, .fullSizePhoto, .fullSizeVideo,
                 .fullSizePairedVideo:
                return true
            default:
                return false
            }
        }
    }
}

/// What to export for one asset: the CURRENT user-visible bytes (edited variants when present,
/// originals otherwise) as primary, plus EVERY other officially exposed PhotoKit resource as a
/// secondary. Bytes are never rendered or converted by us; roles map 1:1 to `PHAssetResource`s.
public struct PhotoBackupExportPlan: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var role: PhotoBackupAssetInfo.Resource.Role
        public var ordinal: Int
        /// The filename the upload carries. Original resources keep their original filenames; edited
        /// renders keep the original basename with an extension that matches the rendered bytes.
        public var uploadFilename: String
        public var mimeType: String?
        public var sourceResource: UploadSourceIdentity.Resource

        public init(
            role: PhotoBackupAssetInfo.Resource.Role,
            ordinal: Int = 0,
            uploadFilename: String,
            mimeType: String?,
            sourceResource: UploadSourceIdentity.Resource
        ) {
            self.role = role
            self.ordinal = ordinal
            self.uploadFilename = uploadFilename
            self.mimeType = mimeType
            self.sourceResource = sourceResource
        }
    }

    public var primary: Item
    /// Every additional PhotoKit resource that must be tied to the primary in Proton Photos.
    public var secondaries: [Item]

    /// Compatibility convenience for older tests/call sites that only cared about Live Photos.
    public var pairedVideo: Item? {
        secondaries.first { $0.role == .pairedVideo || $0.role == .fullSizePairedVideo }
    }

    public init(primary: Item, secondaries: [Item] = []) {
        self.primary = primary
        self.secondaries = secondaries
    }
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
            resourceCount: 1 + plan.secondaries.count,
            externalIdentity: externalIdentity(for: info)
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

    private static func externalIdentity(for info: PhotoBackupAssetInfo) -> UploadBackupExternalIdentity? {
        guard let identifier = info.cloudIdentifier, !identifier.isEmpty,
              let revisionDate = info.modificationDate ?? info.creationDate else {
            return nil
        }
        return UploadBackupExternalIdentity(identifier: identifier, modificationDate: revisionDate)
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
            .map { "\($0.role.rawValue):\($0.ordinal):\($0.originalFilename):\($0.mimeType ?? "")" }
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

    /// Chooses the complete resource set:
    /// - primary = current user-visible photo/video resource when present, else the original;
    /// - secondaries = all other official PhotoKit resources, including RAW alternates, originals,
    ///   Live Photo paired videos, adjustment data/base resources, audio, proxies, and unknown
    ///   future resources surfaced by PhotoKit.
    ///
    /// For an edited render we keep the user's original basename but use the render's extension, so
    /// `IMG_1234.HEIC` + `FullSizeRender.jpg` becomes primary `IMG_1234.jpg` and the untouched
    /// `IMG_1234.HEIC` is retained as a secondary. That avoids lying about bytes vs extension while
    /// preserving the recognizable camera filename.
    public static func exportPlan(for info: PhotoBackupAssetInfo) -> PhotoBackupExportPlan? {
        let resources = normalizedResources(info.resources)
        func resource(_ role: PhotoBackupAssetInfo.Resource.Role) -> PhotoBackupAssetInfo.Resource? {
            resources.first { $0.role == role }
        }

        let original = info.isVideo ? resource(.originalVideo) : resource(.originalPhoto)
        let edited = info.isVideo ? resource(.fullSizeVideo) : resource(.fullSizePhoto)
        guard let exported = edited ?? original else { return nil }
        let uploadName = primaryUploadFilename(exported: exported, original: original)
        let primary = PhotoBackupExportPlan.Item(
            role: exported.role,
            ordinal: exported.ordinal,
            uploadFilename: uploadName,
            mimeType: exported.mimeType ?? original?.mimeType,
            sourceResource: .primary
        )

        var seenNames: Set<String> = [primary.uploadFilename.lowercased()]
        var secondaries: [PhotoBackupExportPlan.Item] = []
        for resource in resources where !isSameResource(resource, exported) {
            let filename = uniqueFilename(
                preferred: secondaryUploadFilename(for: resource, primaryOriginal: original ?? exported),
                role: resource.role,
                seen: &seenNames
            )
            secondaries.append(PhotoBackupExportPlan.Item(
                role: resource.role,
                ordinal: resource.ordinal,
                uploadFilename: filename,
                mimeType: resource.mimeType,
                sourceResource: sourceResource(for: resource)
            ))
        }
        return PhotoBackupExportPlan(primary: primary, secondaries: secondaries)
    }

    private static func normalizedResources(
        _ resources: [PhotoBackupAssetInfo.Resource]
    ) -> [PhotoBackupAssetInfo.Resource] {
        var counters: [PhotoBackupAssetInfo.Resource.Role: Int] = [:]
        return resources
            .sorted { lhs, rhs in
                if rolePriority(lhs.role) != rolePriority(rhs.role) {
                    return rolePriority(lhs.role) < rolePriority(rhs.role)
                }
                if lhs.originalFilename.localizedStandardCompare(rhs.originalFilename) != .orderedSame {
                    return lhs.originalFilename.localizedStandardCompare(rhs.originalFilename) == .orderedAscending
                }
                return (lhs.mimeType ?? "") < (rhs.mimeType ?? "")
            }
            .map { resource in
                let ordinal = counters[resource.role, default: 0]
                counters[resource.role] = ordinal + 1
                var copy = resource
                copy.ordinal = ordinal
                return copy
            }
    }

    private static func isSameResource(
        _ lhs: PhotoBackupAssetInfo.Resource,
        _ rhs: PhotoBackupAssetInfo.Resource
    ) -> Bool {
        lhs.role == rhs.role
            && lhs.ordinal == rhs.ordinal
            && lhs.originalFilename == rhs.originalFilename
            && lhs.mimeType == rhs.mimeType
    }

    private static func sourceResource(for resource: PhotoBackupAssetInfo.Resource) -> UploadSourceIdentity.Resource {
        if resource.role == .pairedVideo && resource.ordinal == 0 {
            return .livePairedVideo
        }
        return .photoKit(role: resource.role.rawValue, ordinal: resource.ordinal)
    }

    private static func primaryUploadFilename(
        exported: PhotoBackupAssetInfo.Resource,
        original: PhotoBackupAssetInfo.Resource?
    ) -> String {
        guard let original, exported.role != original.role else {
            return nonEmptyFilename(exported.originalFilename, fallback: exported.role.rawValue)
        }
        let base = deletingExtension(nonEmptyFilename(original.originalFilename, fallback: "Photo"))
        let ext = pathExtension(exported.originalFilename)
            ?? preferredExtension(for: exported.mimeType)
            ?? pathExtension(original.originalFilename)
            ?? "dat"
        return "\(base).\(ext)"
    }

    private static func secondaryUploadFilename(
        for resource: PhotoBackupAssetInfo.Resource,
        primaryOriginal: PhotoBackupAssetInfo.Resource
    ) -> String {
        let fallbackBase = deletingExtension(nonEmptyFilename(primaryOriginal.originalFilename, fallback: "Photo"))
        let fallbackExt = preferredExtension(for: resource.mimeType) ?? roleExtension(resource.role)
        let fallback = "\(fallbackBase).\(resource.role.rawValue).\(fallbackExt)"
        return nonEmptyFilename(resource.originalFilename, fallback: fallback)
    }

    private static func uniqueFilename(
        preferred: String,
        role: PhotoBackupAssetInfo.Resource.Role,
        seen: inout Set<String>
    ) -> String {
        let cleaned = nonEmptyFilename(preferred, fallback: "\(role.rawValue).dat")
        if seen.insert(cleaned.lowercased()).inserted { return cleaned }
        let base = deletingExtension(cleaned)
        let ext = pathExtension(cleaned) ?? roleExtension(role)
        var suffix = 1
        while true {
            let candidate = "\(base)-\(role.rawValue)-\(suffix).\(ext)"
            if seen.insert(candidate.lowercased()).inserted { return candidate }
            suffix += 1
        }
    }

    private static func rolePriority(_ role: PhotoBackupAssetInfo.Resource.Role) -> Int {
        switch role {
        case .fullSizePhoto: 0
        case .originalPhoto: 1
        case .alternatePhoto: 2
        case .photoProxy: 3
        case .fullSizeVideo: 4
        case .originalVideo: 5
        case .fullSizePairedVideo: 6
        case .pairedVideo: 7
        case .audio: 8
        case .adjustmentData: 9
        case .adjustmentBasePhoto: 10
        case .adjustmentBaseVideo: 11
        case .adjustmentBasePairedVideo: 12
        case .other: 100
        }
    }

    private static func nonEmptyFilename(_ filename: String, fallback: String) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func deletingExtension(_ filename: String) -> String {
        let ns = filename as NSString
        let base = ns.deletingPathExtension
        return base.isEmpty ? filename : base
    }

    private static func pathExtension(_ filename: String) -> String? {
        let ext = (filename as NSString).pathExtension
        return ext.isEmpty ? nil : ext.lowercased()
    }

    private static func preferredExtension(for mimeType: String?) -> String? {
        switch mimeType?.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/tiff": return "tif"
        case "image/x-adobe-dng", "image/dng", "image/adobe-dng": return "dng"
        case "video/quicktime": return "mov"
        case "video/mp4": return "mp4"
        case "audio/mpeg": return "mp3"
        case "application/json": return "json"
        case "application/xml", "text/xml": return "xml"
        default: return nil
        }
    }

    private static func roleExtension(_ role: PhotoBackupAssetInfo.Resource.Role) -> String {
        switch role {
        case .originalPhoto, .alternatePhoto, .fullSizePhoto, .adjustmentBasePhoto, .photoProxy:
            return "img"
        case .originalVideo, .fullSizeVideo, .pairedVideo, .fullSizePairedVideo, .adjustmentBaseVideo,
             .adjustmentBasePairedVideo:
            return "mov"
        case .audio:
            return "audio"
        case .adjustmentData:
            return "dat"
        case .other:
            return "dat"
        }
    }
}
