import Foundation
import MapKit
import PhotosCore

/// Shared MapKit annotation for one aggregated photo-location cell.
final public class PhotoMapAnnotation: NSObject, MKAnnotation {
    public let uid: PhotoUID
    public let memberUIDs: [PhotoUID]
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
