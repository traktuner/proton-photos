import CoreLocation
import Foundation

/// Reverse-geocodes a photo's GPS coordinate into a human place name for the viewer's top bar — the
/// Apple-Photos "named location" headline (e.g. *Schlosspark Atzenbrugg*). Pure coordinate→name
/// reverse geocoding needs no location authorization. Results are cached per (rounded) coordinate so
/// re-viewing nearby photos is instant and we stay well under `CLGeocoder`'s rate limit.
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

    /// A fresh `CLGeocoder` per call sidesteps the "operation already in progress" constraint of a
    /// shared instance and keeps the actor non-reentrant-safe.
    private static func reverseGeocode(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location) else { return nil }
        return placemarks.lazy.compactMap(bestName).first
    }

    /// Prefer a point-of-interest / landmark name (parks, buildings, attractions) over a street
    /// address. Falls back to the locality / region so something sensible always shows when GPS exists.
    private static func bestName(_ placemark: CLPlacemark) -> String? {
        if let poi = placemark.areasOfInterest?.first(where: { !$0.isEmpty }) {
            return poi
        }
        // `name` is frequently just the street address for non-POI spots — use it only when it isn't
        // the bare "<number> <street>" we'd otherwise reconstruct from the address components.
        if let name = placemark.name, !name.isEmpty {
            let streetAddress = [placemark.subThoroughfare, placemark.thoroughfare]
                .compactMap { $0 }.joined(separator: " ")
            if name != streetAddress { return name }
        }
        if let locality = placemark.locality, !locality.isEmpty { return locality }
        return placemark.subAdministrativeArea ?? placemark.administrativeArea
    }

    /// ~11 m precision — coalesces photos taken at essentially the same spot into one geocode.
    private static func cacheKey(_ latitude: Double, _ longitude: Double) -> String {
        String(format: "%.4f,%.4f", latitude, longitude)
    }
}
