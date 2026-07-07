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
    /// Maximum number of AGGREGATED pins returned per query. Each pin represents one grid cell and
    /// may stand in for dozens of photos, so this caps what MKMapView has to render — not the number
    /// of underlying photos. A dense neighborhood of 5k photos at the same block collapses to one cell.
    public let maxCells: Int
    /// How many grid cells fit across the viewport's span. Higher → finer cells (more, smaller pins);
    /// lower → coarser cells (fewer, larger pins). Tuned so a typical city view produces a few hundred
    /// cells at most, letting MapKit's built-in clustering do the final visual merge.
    public let cellDivisor: Double
    /// Lower bound on a grid cell's edge length, in meters. Photos closer than this always share a
    /// cell (one pin) regardless of zoom, so a dense same-place burst (e.g. many photos at home) never
    /// scatters into overlapping pins when zooming in. 0 disables the floor (pure viewport-relative).
    public let minCellMeters: Double

    public init(marginMultiplier: Double, maxCells: Int, cellDivisor: Double, minCellMeters: Double = 0) {
        self.marginMultiplier = marginMultiplier
        self.maxCells = maxCells
        self.cellDivisor = cellDivisor
        self.minCellMeters = minCellMeters
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

    /// Filter to the visible box, then bin into grid cells so MKMapView gets one pin per cell (each
    /// carrying the true photo count) instead of one pin per photo.
    public func aggregatedCoordinates(
        from coordinates: [PhotoCoordinate],
        in viewport: PhotoLocationViewport
    ) -> [AggregatedCoordinate] {
        guard maxCells > 0, let box = boundingBox(for: viewport) else { return [] }
        let visible = coordinates.filter { box.contains(latitude: $0.latitude, longitude: $0.longitude) }
        return PhotoLocationAggregation.aggregate(
            visible,
            in: viewport,
            cellDivisor: cellDivisor,
            maxCells: maxCells,
            minCellMeters: minCellMeters
        )
    }
}

public extension PhotoLocationIndex {
    func coordinates(
        in viewport: PhotoLocationViewport,
        policy: PhotoLocationVisibleCoordinatePolicy
    ) -> [AggregatedCoordinate] {
        policy.aggregatedCoordinates(from: coordinates, in: viewport)
    }
}
