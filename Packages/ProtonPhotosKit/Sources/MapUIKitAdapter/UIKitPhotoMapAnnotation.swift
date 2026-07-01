#if canImport(UIKit)
import Foundation
import MapKit
import MediaLocationCore
import PhotosCore

final class UIKitPhotoMapAnnotation: NSObject, MKAnnotation {
    let uid: PhotoUID
    let date: Date
    let coordinate: CLLocationCoordinate2D

    init(_ coordinate: PhotoCoordinate) {
        self.uid = coordinate.uid
        self.date = coordinate.date
        self.coordinate = CLLocationCoordinate2D(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }
}
#endif
