import Foundation

/// A photo's place on the map: its decrypted GPS coordinate + capture date, keyed by `PhotoUID`.
///
/// Platform-agnostic (Foundation only) so the same index drives the macOS, iPadOS and iOS map UIs -
/// see the universal-binary vision: the core is shared, only the map *view* is per-platform. The
/// coordinates are sensitive PII; MediaLocationCore stores them encrypted at rest (`PhotoLocationStore`)
/// and decrypted only in RAM (`PhotoLocationIndex`).
public struct PhotoCoordinate: Sendable, Equatable, Codable, Identifiable {
    public let uid: PhotoUID
    public let latitude: Double
    public let longitude: Double
    public let date: Date

    public var id: PhotoUID { uid }

    public init(uid: PhotoUID, latitude: Double, longitude: Double, date: Date) {
        self.uid = uid
        self.latitude = latitude
        self.longitude = longitude
        self.date = date
    }
}

/// A lat/lon bounding box - the visible map rect (+ margin) the index is queried against.
public struct GeoBoundingBox: Sendable, Equatable {
    public let minLatitude, maxLatitude, minLongitude, maxLongitude: Double

    public init(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
    }

    public func contains(latitude: Double, longitude: Double) -> Bool {
        latitude >= minLatitude && latitude <= maxLatitude
            && longitude >= minLongitude && longitude <= maxLongitude
    }
}
