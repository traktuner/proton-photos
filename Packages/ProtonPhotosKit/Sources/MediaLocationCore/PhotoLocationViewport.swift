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
        // Stable selection when capped: pick the N closest to the viewport center so a tiny box
        // jitter at the margin doesn't swap thousands of results and cause massive diff churn.
        // Plain euclidean squared distance on lat/lon — only a comparison key, not a real distance,
        // so we keep MediaLocationCore free of any platform location type.
        let centerLat = viewport.centerLatitude
        let centerLon = viewport.centerLongitude
        return Array(visible
            .sorted { lhs, rhs in
                let dl = distSq(lhs, centerLat, centerLon)
                let dr = distSq(rhs, centerLat, centerLon)
                if dl != dr { return dl < dr }
                // Tie on distance: break deterministically so selection is stable across runs and
                // toolchains (Swift's sorted(by:) stability is not guaranteed). Compare the uid's
                // (volumeID, nodeID) tuple lexicographically — cheaper and separator-safe vs. a
                // string key, since PhotoUID isn't Comparable.
                return (lhs.uid.volumeID, lhs.uid.nodeID) < (rhs.uid.volumeID, rhs.uid.nodeID)
            }
            .prefix(maxCoordinates))
    }

    private func distSq(_ coord: PhotoCoordinate, _ centerLat: Double, _ centerLon: Double) -> Double {
        let dLat = coord.latitude - centerLat
        let dLon = coord.longitude - centerLon
        return dLat * dLat + dLon * dLon
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
