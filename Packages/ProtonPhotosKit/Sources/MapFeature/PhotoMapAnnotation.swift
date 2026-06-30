import Foundation
import MapKit
import PhotosCore

/// One photo pinned on the map. MapKit groups these into `MKClusterAnnotation`s (see the
/// `clusteringIdentifier` set on the view); the cluster's hero photo + count are derived from its members.
final class PhotoMapAnnotation: NSObject, MKAnnotation {
    let uid: PhotoUID
    let date: Date
    let coordinate: CLLocationCoordinate2D

    init(_ coordinate: PhotoCoordinate) {
        self.uid = coordinate.uid
        self.date = coordinate.date
        self.coordinate = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}
