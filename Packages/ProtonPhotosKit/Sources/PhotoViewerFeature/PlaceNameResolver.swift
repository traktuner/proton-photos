import Foundation
import MapKit

/// Reverse-geocodes a photo's GPS coordinate into a human place name for the viewer's top bar - the
/// Apple-Photos "named location" headline (e.g. *Schlosspark Atzenbrugg*). Pure coordinate→name
/// reverse geocoding needs no location authorization. Results are cached per (rounded) coordinate so
/// re-viewing nearby photos is instant and we stay well under reverse-geocoding rate limits.
actor PlaceNameResolver {
    static let shared = PlaceNameResolver()

    /// `nil` value = geocoded but no usable name (so we don't re-request it).
    private var cache: [String: String?] = [:]

    /// Best place name for a coordinate, or `nil` if none could be resolved.
    func placeName(latitude: Double, longitude: Double) async -> String? {
        let key = Self.cacheKey(latitude, longitude)
        if let cached = cache[key] { return cached }
        let name = await Self.reverseGeocode(latitude: latitude, longitude: longitude)
        cache[key] = name
        return name
    }

    /// A fresh request per call keeps cancellation and rate-limiting behavior local to the lookup.
    private static func reverseGeocode(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let request = MKReverseGeocodingRequest(location: location),
              let mapItems = try? await request.mapItems else { return nil }
        return mapItems.lazy.compactMap(bestName).first
    }

    /// Prefer a point-of-interest / landmark name (parks, buildings, attractions) over a street
    /// address. Falls back to the locality / region so something sensible always shows when GPS exists.
    private static func bestName(_ item: MKMapItem) -> String? {
        let address = item.address
        let addressRepresentations = item.addressRepresentations
        // `name` can be just the address for non-POI spots; use it only when it differs from the
        // structured address strings MapKit now exposes.
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

    /// ~11 m precision - coalesces photos taken at essentially the same spot into one geocode.
    private static func cacheKey(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.4f,%.4f", latitude, longitude)
    }
}
