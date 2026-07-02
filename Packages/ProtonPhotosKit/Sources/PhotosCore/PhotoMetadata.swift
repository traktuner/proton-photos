import Foundation

/// Full file metadata for the viewer's info panel - filename, capture/EXIF-ish data, dimensions and
/// location. Sourced from the decrypted Drive link `Name` + the file's `XAttr` (Proton stores only a
/// device string, not full EXIF: no aperture/ISO/lens are available).
public struct PhotoMetadata: Sendable, Equatable {
    public var filename: String?
    public var mimeType: String?
    public var fileSize: Int?            // bytes
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var device: String?           // capturing device/camera model
    public var durationSeconds: Double?  // videos
    public var modificationTime: Date?
    public var latitude: Double?
    public var longitude: Double?

    public init(
        filename: String? = nil,
        mimeType: String? = nil,
        fileSize: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        device: String? = nil,
        durationSeconds: Double? = nil,
        modificationTime: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.filename = filename
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.device = device
        self.durationSeconds = durationSeconds
        self.modificationTime = modificationTime
        self.latitude = latitude
        self.longitude = longitude
    }

    public var hasLocation: Bool { latitude != nil && longitude != nil }
}

/// Optional backend capability: fetch full metadata for a photo/video (link name + decrypted XAttr).
public protocol PhotoMetadataProvider: Sendable {
    func metadata(for uid: PhotoUID) async throws -> PhotoMetadata
}
