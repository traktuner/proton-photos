import Foundation
import MapKit
import MediaLocationCore
import PhotosCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The platform-neutral engine that keeps an `MKMapView`'s photo annotations in sync with the visible
/// region - framing, off-main aggregation, coalescing, the generation guard, and the add/remove diff.
///
/// This is the logic that was previously duplicated verbatim in the iOS (`UIKitLibraryMapHostView`) and
/// macOS (`LibraryMapView.Coordinator`) hosts. `MKMapView`, `MKAnnotation`, `MKMapRect` and
/// `PhotoMapAnnotation` are identical on both platforms, so all of it lives here once. What stays in the
/// hosts is only what genuinely differs per platform: `MKMapViewDelegate` conformance (an `@objc`
/// protocol a generic type can't adopt), annotation-VIEW vending, and thumbnail application (`UIImage`
/// vs `NSImage`). The host drives this loader from its delegate callbacks.
@MainActor
public final class PhotoMapAnnotationLoader {
    private let index: PhotoLocationIndex
    private let policy: PhotoLocationVisibleCoordinatePolicy
    private weak var mapView: MKMapView?

    /// Authoritative tracker of the annotations THIS loader put on the map (never derived from
    /// `mapView.annotations`, which is O(n) and includes MapKit's own cluster annotations).
    private var shownUIDs = Set<PhotoUID>()
    private var annotationByUID: [PhotoUID: PhotoMapAnnotation] = [:]
    private var lastRevision = Int.min
    private var didFrame = false
    /// Last queried box, so a sub-pixel `regionDidChange` (or a revision bump that didn't move the box)
    /// doesn't re-filter and re-diff for nothing.
    private var lastBoundingBox: GeoBoundingBox?
    /// Monotonic id per pass: the aggregation runs off the main thread; a result returning after a newer
    /// pass started is stale (old viewport) and is dropped.
    private var reloadGeneration = 0
    private var reloadTask: Task<Void, Never>?

    /// Invoked with the UIDs whose annotations were just removed, so the host can cancel any in-flight
    /// thumbnail loads bound to them (those live in the host because they apply a platform image).
    private let onRemoved: (Set<PhotoUID>) -> Void

    public init(
        index: PhotoLocationIndex,
        policy: PhotoLocationVisibleCoordinatePolicy,
        onRemoved: @escaping (Set<PhotoUID>) -> Void
    ) {
        self.index = index
        self.policy = policy
        self.onRemoved = onRemoved
    }

    deinit { reloadTask?.cancel() }

    /// Bind the loader to its map and do the first pass. Framing is synchronous (cheap, centres on the
    /// dense core before first paint); the first aggregation is deferred to the next runloop tick so the
    /// map surface presents instantly and the pins populate a beat later.
    public func attach(_ mapView: MKMapView) {
        self.mapView = mapView
        frameToDenseCoreIfNeeded()
        DispatchQueue.main.async { [weak self] in self?.reloadVisible() }
    }

    /// The index contents changed (the crawl added coordinates): invalidate the box cache so we re-query
    /// even if the map region itself didn't move, and re-frame until there is data.
    public func refreshIfChanged(revision: Int) {
        guard revision != lastRevision else { return }
        lastRevision = revision
        lastBoundingBox = nil
        frameToDenseCoreIfNeeded()
        reloadVisible()
    }

    /// The annotation currently shown for `uid`, if any - the host uses this to apply a loaded thumbnail
    /// without scanning `mapView.annotations`.
    public func annotation(for uid: PhotoUID) -> PhotoMapAnnotation? { annotationByUID[uid] }

    /// Land the user where most of their photos are (once, when the first coordinates arrive). Frames the
    /// dense core, not the bounds of every coordinate, so one photo from a trip abroad doesn't drag the
    /// centre out into the ocean.
    public func frameToDenseCoreIfNeeded() {
        guard !didFrame, let mapView, !index.coordinates.isEmpty,
              let box = PhotoLocationFraming.denseBoundingBox(for: index.coordinates) else { return }
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: box.minLatitude, longitude: box.minLongitude))
        let b = MKMapPoint(CLLocationCoordinate2D(latitude: box.maxLatitude, longitude: box.maxLongitude))
        let rect = MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        guard !rect.isNull else { return }
        #if canImport(UIKit)
        let padding = UIEdgeInsets(top: 80, left: 80, bottom: 80, right: 80)
        #else
        let padding = NSEdgeInsets(top: 80, left: 80, bottom: 80, right: 80)
        #endif
        mapView.setVisibleMapRect(rect, edgePadding: padding, animated: false)
        didFrame = true
    }

    /// Aggregate OFF the main thread, then apply the delta on the main actor. Filtering thousands of
    /// coordinates + grid binning is the dominant cost and must never block the tab transition or a
    /// scroll/pinch. Snapshot the value-type coordinates on the main actor (cheap, copy-on-write), bin
    /// them on a background task, apply the handful of resulting annotations back on the main actor.
    public func reloadVisible() {
        guard let mapView else { return }
        let r = mapView.region
        let viewport = PhotoLocationViewport(
            centerLatitude: r.center.latitude,
            centerLongitude: r.center.longitude,
            latitudeDelta: r.span.latitudeDelta,
            longitudeDelta: r.span.longitudeDelta
        )
        guard let box = policy.boundingBox(for: viewport) else { return }
        if lastBoundingBox == box { return }
        lastBoundingBox = box

        let coords = index.coordinates
        let policy = self.policy
        reloadGeneration &+= 1
        let generation = reloadGeneration
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            let cells = await Task.detached(priority: .userInitiated) {
                policy.aggregatedCoordinates(from: coords, in: viewport)
            }.value
            guard !Task.isCancelled, let self, generation == self.reloadGeneration else { return }
            self.applyCells(cells)
        }
    }

    /// Diff the freshly aggregated cells against what is on screen and add/remove the delta. Runs on the
    /// main actor (mutates the map); the expensive aggregation already ran off-main in `reloadVisible`.
    private func applyCells(_ cells: [AggregatedCoordinate]) {
        guard let mapView else { return }
        let wanted = Set(cells.map(\.uid))

        let toRemove = shownUIDs.subtracting(wanted)
        if !toRemove.isEmpty {
            let stale = toRemove.compactMap { annotationByUID[$0] }
            if !stale.isEmpty {
                mapView.removeAnnotations(stale)
                for uid in toRemove { annotationByUID.removeValue(forKey: uid) }
                shownUIDs.subtract(toRemove)
            }
            onRemoved(toRemove)
        }

        let fresh = cells.filter { !shownUIDs.contains($0.uid) }
        if !fresh.isEmpty {
            let annotations = fresh.map(PhotoMapAnnotation.init)
            for (i, cell) in fresh.enumerated() { annotationByUID[cell.uid] = annotations[i] }
            mapView.addAnnotations(annotations)
            shownUIDs.formUnion(fresh.map(\.uid))
        }
    }
}
