import Foundation

/// One map cell after location aggregation.
///
/// The location core bins nearby coordinates before handing them to MapKit, so the map renders a
/// bounded number of pins while each pin still carries the true set of represented photos.
public struct AggregatedCoordinate: Sendable, Equatable {
    public let memberUIDs: [PhotoUID]
    public let latitude: Double
    public let longitude: Double
    public let uid: PhotoUID

    public var count: Int { memberUIDs.count }

    public init(memberUIDs: [PhotoUID], latitude: Double, longitude: Double, uid: PhotoUID) {
        self.memberUIDs = memberUIDs
        self.latitude = latitude
        self.longitude = longitude
        self.uid = uid
    }
}
