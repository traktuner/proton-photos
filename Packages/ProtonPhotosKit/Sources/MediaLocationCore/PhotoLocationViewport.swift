import Foundation
import PhotosCore

public struct PhotoLocationViewport: Sendable, Equatable {
    public let centerLatitude: Double
    public let centerLongitude: Double
    public let latitudeDelta: Double
    public let longitudeDelta: Double

    public init(centerLatitude: Double, centerLongitude: Double, latitudeDelta: Double, longitudeDelta: Double) {
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }

    var isFinite: Bool {
        centerLatitude.isFinite
            && centerLongitude.isFinite
            && latitudeDelta.isFinite
            && longitudeDelta.isFinite
    }
}

public struct PhotoLocationVisibleCoordinatePolicy: Sendable, Equatable {
    public let marginMultiplier: Double
    public let maxCoordinates: Int

    public init(marginMultiplier: Double, maxCoordinates: Int) {
        self.marginMultiplier = marginMultiplier
        self.maxCoordinates = maxCoordinates
    }

    public func boundingBox(for viewport: PhotoLocationViewport) -> GeoBoundingBox? {
        guard viewport.isFinite, marginMultiplier.isFinite, marginMultiplier >= 0 else { return nil }

        let latitudeRadius = max(0, viewport.latitudeDelta) * marginMultiplier
        let longitudeRadius = max(0, viewport.longitudeDelta) * marginMultiplier
        return GeoBoundingBox(
            minLatitude: viewport.centerLatitude - latitudeRadius,
            maxLatitude: viewport.centerLatitude + latitudeRadius,
            minLongitude: viewport.centerLongitude - longitudeRadius,
            maxLongitude: viewport.centerLongitude + longitudeRadius
        )
    }

    public func visibleCoordinates(
        from coordinates: [PhotoCoordinate],
        in viewport: PhotoLocationViewport
    ) -> [PhotoCoordinate] {
        guard maxCoordinates > 0, let box = boundingBox(for: viewport) else { return [] }

        let visible = coordinates.filter { box.contains(latitude: $0.latitude, longitude: $0.longitude) }
        guard visible.count > maxCoordinates else { return visible }
        return Array(visible.prefix(maxCoordinates))
    }
}

public extension PhotoLocationIndex {
    func coordinates(
        in viewport: PhotoLocationViewport,
        policy: PhotoLocationVisibleCoordinatePolicy
    ) -> [PhotoCoordinate] {
        policy.visibleCoordinates(from: coordinates, in: viewport)
    }
}
