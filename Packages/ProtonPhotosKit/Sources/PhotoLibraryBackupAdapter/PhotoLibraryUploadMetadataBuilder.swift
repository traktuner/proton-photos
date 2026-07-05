import CoreLocation
import Foundation
import Photos
import UploadCore

enum PhotoLibraryUploadMetadataBuilder {
    static func metadata(for asset: PHAsset) throws -> [PhotoUploadAdditionalMetadata] {
        let captureDate = asset.creationDate ?? asset.modificationDate
        let modificationDate = asset.modificationDate ?? asset.creationDate
        let location = location(from: asset.location)
        let camera = PhotoUploadMetadataEncoder.Camera(captureTime: captureDate.map(format))
        let media = PhotoUploadMetadataEncoder.Media(
            width: asset.pixelWidth > 0 ? asset.pixelWidth : nil,
            height: asset.pixelHeight > 0 ? asset.pixelHeight : nil,
            duration: asset.mediaType == .video ? asset.duration : nil
        )
        let iOSPhotos = cloudIdentifier(for: asset).map {
            PhotoUploadMetadataEncoder.IOSPhotos(
                iCloudID: $0,
                modificationTime: modificationDate.map(format)
            )
        }
        return try PhotoUploadMetadataEncoder.metadata(
            location: location,
            camera: camera,
            media: media,
            iOSPhotos: iOSPhotos
        )
    }

    private static func location(from location: CLLocation?) -> PhotoUploadMetadataEncoder.Location? {
        guard let location, CLLocationCoordinate2DIsValid(location.coordinate) else { return nil }
        return PhotoUploadMetadataEncoder.Location(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
    }

    private static func cloudIdentifier(for asset: PHAsset) -> String? {
        let mapping = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: [asset.localIdentifier])
        return try? mapping[asset.localIdentifier]?.get().stringValue
    }

    private static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
