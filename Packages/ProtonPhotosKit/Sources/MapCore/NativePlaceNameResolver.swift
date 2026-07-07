import Foundation
import MapKit
import PhotosCore

public actor NativePlaceNameResolver: PlaceNameResolving {
    public static let shared = NativePlaceNameResolver()

    private var cache: [String: String?] = [:]

    public func placeName(latitude: Double, longitude: Double) async -> String? {
        let key = Self.cacheKey(latitude, longitude)
        if let cached = cache[key] { return cached }
        let name = await Self.reverseGeocode(latitude: latitude, longitude: longitude)
        cache[key] = name
        return name
    }

    private static func reverseGeocode(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let request = MKReverseGeocodingRequest(location: location),
              let mapItems = try? await request.mapItems else { return nil }
        return mapItems.lazy.compactMap(bestName).first
    }

    private static func bestName(_ item: MKMapItem) -> String? {
        let address = item.address
        let addressRepresentations = item.addressRepresentations
        if let name = item.name, !name.isEmpty {
            let isAddress = [address?.shortAddress, address?.fullAddress]
                .compactMap { $0 }
                .contains(name)
            if !isAddress { return name }
        }
        if let city = addressRepresentations?.cityName, !city.isEmpty { return city }
        if let city = addressRepresentations?.cityWithContext, !city.isEmpty { return city }
        if let region = addressRepresentations?.regionName, !region.isEmpty { return region }
        return address?.shortAddress ?? address?.fullAddress
    }

    private static func cacheKey(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.4f,%.4f", latitude, longitude)
    }
}
