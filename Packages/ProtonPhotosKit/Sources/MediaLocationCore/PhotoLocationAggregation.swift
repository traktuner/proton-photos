import Foundation
import PhotosCore

/// Bins visible-map coordinates into grid cells so MKMapView never manages more than a few hundred
/// pin views regardless of library size.
///
/// The cell size is a fraction of the visible viewport's span, so zooming in splits cells (more pins,
/// individual photos resolve) and zooming out merges them (fewer pins, dense regions collapse to a
/// handful of count-bearing cells). The `maxCoordinates` cap limits the number of CELLS, not raw
/// photos, so even a 50k-photo downtown fits in a few hundred pins — each carrying the true count of
/// photos in its cell. MapKit's built-in clustering still merges nearby cells, and the cluster view
/// sums the cell counts so the badge shows every underlying photo.
public struct PhotoLocationAggregation {

    /// Aggregate `coordinates` into grid cells sized to `viewport`.
    ///
    /// - Parameters:
    ///   - coordinates: All photos in the visible rect + margin (already filtered to the box).
    ///   - viewport: The visible map region; the cell size is derived from its span.
    ///   - cellDivisor: How many cells fit across the viewport (e.g. 12 → each cell spans 1/12 of the
    ///     visible width/height). Larger → more, smaller pins; smaller → coarser aggregation.
    ///   - maxCells: Upper bound on the number of cells returned. Excess cells (farthest from the
    ///     viewport center) are dropped, preserving the on-screen core.
    /// - Returns: One `AggregatedCoordinate` per occupied cell, ordered newest-hero-first so the
    ///   cluster hero resolution prefers recent photos.
    public static func aggregate(
        _ coordinates: [PhotoCoordinate],
        in viewport: PhotoLocationViewport,
        cellDivisor: Double,
        maxCells: Int,
        minCellMeters: Double = 0
    ) -> [AggregatedCoordinate] {
        guard !coordinates.isEmpty, cellDivisor > 0, maxCells > 0 else { return [] }

        // Floor the cell size so photos within `minCellMeters` of each other always land in the same
        // cell — and therefore a single pin — no matter how far the user zooms in. Without a floor the
        // viewport-relative cell keeps shrinking on zoom-in, so a GPS-noisy burst at one place (dozens
        // of photos taken at home) scatters across adjacent tiny cells into a pile of overlapping pins.
        let metersPerDegLat = 111_320.0
        let cosLat = Foundation.cos(viewport.centerLatitude * .pi / 180)
        let metersPerDegLon = metersPerDegLat * max(abs(cosLat), 0.01)
        let floorLat = minCellMeters > 0 ? minCellMeters / metersPerDegLat : 0
        let floorLon = minCellMeters > 0 ? minCellMeters / metersPerDegLon : 0

        let latStep = max(max(viewport.latitudeDelta, 0) / cellDivisor, floorLat)
        let lonStep = max(max(viewport.longitudeDelta, 0) / cellDivisor, floorLon)
        // Guard against a degenerate viewport (zero span) producing all-same-cell collisions: fall
        // back to one cell per degree so coincident photos still bin predictably.
        let latCell = latStep > 0 ? latStep : 1
        let lonCell = lonStep > 0 ? lonStep : 1

        // Bin by integer cell index. Swift's Dictionary preserves insertion order for iteration on
        // recent toolchains, but we sort explicitly afterward so order is not load-bearing here.
        struct CellKey: Hashable { let lat: Int; let lon: Int }
        var bins: [CellKey: (members: [PhotoCoordinate], lat: Double, lon: Double)] = [:]
        for c in coordinates {
            let key = CellKey(
                lat: Int((c.latitude - viewport.centerLatitude) / latCell),
                lon: Int((c.longitude - viewport.centerLongitude) / lonCell)
            )
            if var existing = bins[key] {
                existing.members.append(c)
                bins[key] = existing
            } else {
                bins[key] = ([c], c.latitude, c.longitude)
            }
        }

        var cells = bins.map { (_, v) -> AggregatedCoordinate in
            // Hero: newest photo in the cell (max date). Date ties break by uid tuple so the hero is
            // deterministic across crawls and toolchains.
            let hero = v.members.max { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date < rhs.date }
                return (lhs.uid.volumeID, lhs.uid.nodeID) < (rhs.uid.volumeID, rhs.uid.nodeID)
            } ?? v.members[0]
            return AggregatedCoordinate(
                memberUIDs: v.members.map(\.uid),
                latitude: v.lat,
                longitude: v.lon,
                uid: hero.uid
            )
        }

        if cells.count > maxCells {
            // Keep the cells that represent the MOST photos, not merely the ones nearest the center.
            // A count-blind nearest-center prune could drop the single densest cell (e.g. 2000 photos
            // at home) while keeping hundreds of one-photo cells that happen to sit closer to the map
            // center — making the densest place vanish as the user pans. Rank by member count first so
            // a dense cluster can never be dropped; break ties by center distance so, among equally
            // dense cells, the on-screen ones win.
            let centerLat = viewport.centerLatitude
            let centerLon = viewport.centerLongitude
            cells.sort { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return distSq(lhs, centerLat, centerLon) < distSq(rhs, centerLat, centerLon)
            }
            cells = Array(cells.prefix(maxCells))
        }

        // Deterministic output order (newest hero first) so identical inputs produce identical
        // sequences and the diff in the map host doesn't churn on dictionary ordering quirks.
        cells.sort { lhs, rhs in
            // Order is cosmetic (the host diffs by uid set anyway), but keep it stable.
            (lhs.uid.volumeID, lhs.uid.nodeID) < (rhs.uid.volumeID, rhs.uid.nodeID)
        }
        return cells
    }

    private static func distSq(_ c: AggregatedCoordinate, _ centerLat: Double, _ centerLon: Double) -> Double {
        let dLat = c.latitude - centerLat
        let dLon = c.longitude - centerLon
        return dLat * dLat + dLon * dLon
    }
}
