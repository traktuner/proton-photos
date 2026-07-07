import Foundation

/// A group of photos that share a map cell, presented to MapKit as a single pin.
///
/// `PhotoLocationAggregation` bins all coordinates that fall inside the same grid cell of the visible
/// map rect into one `AggregatedCoordinate`. Each becomes one `MKAnnotation`, so MKMapView never has to
/// manage thousands of individual pin views: a dense 3k-photo neighborhood collapses to a handful of
/// cells, each carrying the true count of photos it represents. MapKit's built-in clustering still
/// merges nearby cells into `MKClusterAnnotation`s; the cluster view sums `memberCount` across its
/// member annotations so the displayed badge reflects every underlying photo, not just the number of
/// cell pins MapKit chose to show.
public struct AggregatedCoordinate: Sendable, Equatable {
    /// All photos represented by this cell. Used to drive the cluster-series screen (lists every
    /// underlying photo, not just the cell's hero) and to keep cluster counts honest.
    public let memberUIDs: [PhotoUID]
    /// The representative coordinate shown on the map (centroid of the cell).
    public let latitude: Double
    public let longitude: Double
    /// The hero photo whose thumbnail decorates this cell. Newest member wins so the cell stays
    /// visually anchored to the most recent visit as the crawl fills the index in. Also the stable
    /// identity used by the map host's diff set (`shownUIDs`).
    public let uid: PhotoUID

    public var count: Int { memberUIDs.count }

    public init(memberUIDs: [PhotoUID], latitude: Double, longitude: Double, uid: PhotoUID) {
        self.memberUIDs = memberUIDs
        self.latitude = latitude
        self.longitude = longitude
        self.uid = uid
    }
}
