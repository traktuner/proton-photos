import Foundation
import Observation
import PhotosCore

/// The whole library's GPS coordinates, held in RAM for instant map queries.
///
/// Loaded once (decrypted) from `PhotoLocationStore` and then filled in live by `LocationCrawl`. At
/// ~40–60 bytes per photo, 20k photos is ~1 MB, so keeping the entire library resident is trivial and
/// makes region queries an in-memory filter (microseconds) - no per-view decode. The decrypted
/// coordinates exist ONLY here in RAM; on disk they are always AES-GCM encrypted.
///
/// `@MainActor @Observable`: the map view binds to `revision`, so annotations refresh as the crawl adds
/// coordinates. Platform-agnostic (no AppKit) - reused as-is by a future iOS/iPad map UI.
@MainActor
@Observable
public final class PhotoLocationIndex {
    public private(set) var coordinates: [PhotoCoordinate] = []
    /// Bumped whenever `coordinates` changes. The map view observes this to re-derive annotations.
    public private(set) var revision = 0
    /// Live progress of the GPS crawl feeding this index. The map's empty state observes it to say
    /// "scanning…" honestly instead of a misleading "no places yet" while the scan hasn't finished.
    public private(set) var scanProgress = PhotoLocationScanProgress()
    @ObservationIgnored private var seen = Set<PhotoUID>()

    public init() {}

    /// Published by `LocationCrawl` (start / batch cadence / completion) - never per item.
    public func updateScanProgress(_ progress: PhotoLocationScanProgress) {
        scanProgress = progress
    }

    /// Replace the whole index - e.g. after decrypting the persisted snapshot at startup.
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

    /// The uids already indexed - used by the crawl to skip work it has already done (resumable).
    public func indexedUIDs() -> Set<PhotoUID> { seen }

    /// Coordinates whose point falls inside the bounding box (the visible map rect + margin).
    public func coordinates(in box: GeoBoundingBox) -> [PhotoCoordinate] {
        coordinates.filter { box.contains(latitude: $0.latitude, longitude: $0.longitude) }
    }
}

/// Where the GPS crawl currently stands, for honest map empty states and diagnostics.
public struct PhotoLocationScanProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// No crawl has run this session (library still loading, or Map never opened).
        case idle
        /// Crawl running - the map should say "scanning", not "no places".
        case scanning
        /// Crawl finished this session. Zero `found` now honestly means "no geotagged photos".
        case completed
        /// Crawl finished but EVERY probe failed (metadata unreachable) - a real failure, not "no GPS".
        case failed
    }

    public var phase: Phase
    /// Photos probed so far in this run (excludes ones already indexed from the persisted snapshot).
    public var scanned: Int
    /// Total candidates for this run.
    public var total: Int
    /// Coordinates in the index overall (persisted snapshot + this run).
    public var found: Int
    /// Probes that returned metadata without GPS.
    public var noLocation: Int
    /// Probes that failed outright (network/decode/decrypt).
    public var failed: Int

    public init(phase: Phase = .idle, scanned: Int = 0, total: Int = 0,
                found: Int = 0, noLocation: Int = 0, failed: Int = 0) {
        self.phase = phase
        self.scanned = scanned
        self.total = total
        self.found = found
        self.noLocation = noLocation
        self.failed = failed
    }
}
