import Foundation
import Photos
import UniformTypeIdentifiers

/// The only place PhotoKit types become `PhotoBackupAssetInfo`. Reads local metadata only -
/// `PHAssetResource.assetResources(for:)` is synchronous and never triggers downloads.
enum PhotoKitAssetMapper {

    static func info(for asset: PHAsset) -> PhotoBackupAssetInfo {
        let resources = PHAssetResource.assetResources(for: asset).map { resource in
            PhotoBackupAssetInfo.Resource(
                role: role(for: resource.type),
                originalFilename: resource.originalFilename,
                mimeType: UTType(resource.uniformTypeIdentifier)?.preferredMIMEType
            )
        }
        return PhotoBackupAssetInfo(
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            durationSeconds: asset.duration,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            isVideo: asset.mediaType == .video,
            resources: resources
        )
    }

    static func role(for type: PHAssetResourceType) -> PhotoBackupAssetInfo.Resource.Role {
        switch type {
        case .photo: return .originalPhoto
        case .alternatePhoto: return .alternatePhoto
        case .fullSizePhoto: return .fullSizePhoto
        case .video: return .originalVideo
        case .audio: return .audio
        case .fullSizeVideo: return .fullSizeVideo
        case .pairedVideo: return .pairedVideo
        case .fullSizePairedVideo: return .fullSizePairedVideo
        case .adjustmentData: return .adjustmentData
        case .adjustmentBasePhoto: return .adjustmentBasePhoto
        case .adjustmentBaseVideo: return .adjustmentBaseVideo
        case .adjustmentBasePairedVideo: return .adjustmentBasePairedVideo
        case .photoProxy: return .photoProxy
        default:
            return .other
        }
    }

    /// The concrete `PHAssetResource` behind a plan item.
    static func resource(
        for role: PhotoBackupAssetInfo.Resource.Role,
        ordinal: Int = 0,
        of asset: PHAsset
    ) -> PHAssetResource? {
        let matches = PHAssetResource.assetResources(for: asset)
            .filter { self.role(for: $0.type) == role }
            .sorted { lhs, rhs in
                if lhs.originalFilename.localizedStandardCompare(rhs.originalFilename) != .orderedSame {
                    return lhs.originalFilename.localizedStandardCompare(rhs.originalFilename) == .orderedAscending
                }
                let left = UTType(lhs.uniformTypeIdentifier)?.preferredMIMEType ?? ""
                let right = UTType(rhs.uniformTypeIdentifier)?.preferredMIMEType ?? ""
                return left < right
            }
        guard ordinal >= 0, ordinal < matches.count else { return nil }
        return matches[ordinal]
    }
}
