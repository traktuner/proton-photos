import Foundation
import Observation
import PhotosCore

/// The whole library's GPS coordinates, held in RAM for instant map queries.
///
/// Loaded once (decrypted) from `PhotoLocationStore` and then filled in live by `LocationCrawl`. At
/// ~40–60 bytes per photo, 20k photos is ~1 MB, so keeping the entire library resident is trivial and
/// makes region queries an in-memory filter (microseconds) — no per-view decode. The decrypted
/// coordinates exist ONLY here in RAM; on disk they are always AES-GCM encrypted.
///
/// `@MainActor @Observable`: the map view binds to `revision`, so annotations refresh as the crawl adds
/// coordinates. Platform-agnostic (no AppKit) — reused as-is by a future iOS/iPad map UI.
@MainActor
@Observable
public final class PhotoLocationIndex {
    public private(set) var coordinates: [PhotoCoordinate] = []
    /// Bumped whenever `coordinates` changes. The map view observes this to re-derive annotations.
    public private(set) var revision = 0
    @ObservationIgnored private var seen = Set<PhotoUID>()

    public init() {}

    /// Replace the whole index — e.g. after decrypting the persisted snapshot at startup.
    public func replaceAll(_ coords: [PhotoCoordinate]) {
        coordinates = coords
        seen = Set(coords.map(\.uid))
        revision += 1
    }

    /// Merge newly-crawled coordinates, deduped by uid. Bumps `revision` only if something was added,
    /// so an idle re-crawl that finds nothing new never churns the view.
    public func merge(_ coords: [PhotoCoordinate]) {
        var added = false
        for c in coords where seen.insert(c.uid).inserted {
            coordinates.append(c)
            added = true
        }
        if added { revision += 1 }
    }

    /// The uids already indexed — used by the crawl to skip work it has already done (resumable).
    public func indexedUIDs() -> Set<PhotoUID> { seen }

    /// Coordinates whose point falls inside the bounding box (the visible map rect + margin).
    public func coordinates(in box: GeoBoundingBox) -> [PhotoCoordinate] {
        coordinates.filter { box.contains(latitude: $0.latitude, longitude: $0.longitude) }
    }
}
