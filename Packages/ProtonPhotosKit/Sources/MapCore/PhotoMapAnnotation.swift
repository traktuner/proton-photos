import Foundation
import MapKit
import PhotosCore

/// One map pin backed by an `AggregatedCoordinate` - a grid cell that may represent several photos.
///
/// Shared by the macOS (`MapFeature`) and iOS/iPadOS (`MapUIKitAdapter`) map UIs because
/// `MKAnnotation`/`CLLocationCoordinate2D` are identical on both platforms. There is no per-platform
/// flavor of this type; only the annotation VIEWS differ (AppKit vs UIKit).
///
/// MapKit groups these into `MKClusterAnnotation`s via the `clusteringIdentifier` set on the view;
/// the cluster view sums `memberCount` across its member annotations so the badge reflects every
/// underlying photo, not just the count of cell pins MapKit happened to show.
final public class PhotoMapAnnotation: NSObject, MKAnnotation {
    /// Hero photo of the cell - the one whose thumbnail decorates the pin. Also the stable identity
    /// used by the map host's diff set (`shownUIDs`).
    public let uid: PhotoUID
    /// Every photo collapsed into this cell. Used to drive the cluster-series screen (lists every
    /// underlying photo, not just the hero) and to keep cluster counts honest.
    public let memberUIDs: [PhotoUID]
    /// The number of photos in this cell. Equal to `memberUIDs.count`; cached as a property so the
    /// cluster view can sum member annotations without walking each one's array.
    public let memberCount: Int
    public let coordinate: CLLocationCoordinate2D

    public init(_ aggregated: AggregatedCoordinate) {
        self.uid = aggregated.uid
        self.memberUIDs = aggregated.memberUIDs
        self.memberCount = aggregated.count
        self.coordinate = CLLocationCoordinate2D(
            latitude: aggregated.latitude,
            longitude: aggregated.longitude
        )
    }
}
