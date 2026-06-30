import SwiftUI
import MapKit
import AppKit
import PhotosCore
import MediaLocationCore

/// The library map: a native MapKit map (Apple tiles, no API key) with clustered photo badges over the
/// shared, encrypted `PhotoLocationIndex`.
///
/// Only the annotations in the visible map rect (+ margin) are placed, so even a 20k-photo library puts
/// just the on-screen subset on the map; MapKit's built-in clustering then merges them into count+hero
/// badges that split apart on zoom. Annotations refresh as the background GPS crawl fills the index in
/// (the `revision` binding). macOS UI layer — an iOS/iPad variant reuses the same `PhotoLocationIndex`.
public struct LibraryMapView: NSViewRepresentable {
    private let index: PhotoLocationIndex
    private let thumbnail: (PhotoUID) -> NSImage?
    private let onSelectPhoto: (PhotoUID) -> Void

    public init(index: PhotoLocationIndex,
                thumbnail: @escaping (PhotoUID) -> NSImage?,
                onSelectPhoto: @escaping (PhotoUID) -> Void) {
        self.index = index
        self.thumbnail = thumbnail
        self.onSelectPhoto = onSelectPhoto
    }

    public func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = false
        map.pointOfInterestFilter = .excludingAll
        map.register(PhotoAnnotationView.self, forAnnotationViewWithReuseIdentifier: PhotoAnnotationView.reuseID)
        map.register(PhotoClusterAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        context.coordinator.attach(map)
        return map
    }

    public func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.thumbnail = thumbnail
        context.coordinator.onSelectPhoto = onSelectPhoto
        context.coordinator.refreshIfChanged(revision: index.revision)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(index: index, thumbnail: thumbnail, onSelectPhoto: onSelectPhoto)
    }

    @MainActor
    public final class Coordinator: NSObject, MKMapViewDelegate {
        private let index: PhotoLocationIndex
        var thumbnail: (PhotoUID) -> NSImage?
        var onSelectPhoto: (PhotoUID) -> Void
        private weak var map: MKMapView?
        private var shownUIDs = Set<PhotoUID>()
        private var lastRevision = Int.min
        private var didFrame = false

        init(index: PhotoLocationIndex,
             thumbnail: @escaping (PhotoUID) -> NSImage?,
             onSelectPhoto: @escaping (PhotoUID) -> Void) {
            self.index = index
            self.thumbnail = thumbnail
            self.onSelectPhoto = onSelectPhoto
        }

        func attach(_ map: MKMapView) {
            self.map = map
            frameToAllDataIfNeeded()
            reloadVisible()
        }

        func refreshIfChanged(revision: Int) {
            guard revision != lastRevision else { return }
            lastRevision = revision
            frameToAllDataIfNeeded()
            reloadVisible()
        }

        /// Land the user on their photos: frame the map to fit all coordinates (once, when the first
        /// coordinates arrive). Re-runs until there is data so the very first crawl batch frames it.
        private func frameToAllDataIfNeeded() {
            guard !didFrame, let map, !index.coordinates.isEmpty else { return }
            let rect = boundingRect(of: index.coordinates.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })
            guard !rect.isNull else { return }
            map.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 80, left: 80, bottom: 80, right: 80), animated: false)
            didFrame = true
        }

        /// Region-based loading: keep only the annotations whose photos are in the visible rect (+ margin),
        /// so the map never holds more than the on-screen subset. MapKit clusters that subset.
        private func reloadVisible() {
            guard let map else { return }
            let r = map.region
            let m = 1.6   // load a bit beyond the edges so panning is seamless
            let box = GeoBoundingBox(
                minLatitude: r.center.latitude - r.span.latitudeDelta * m,
                maxLatitude: r.center.latitude + r.span.latitudeDelta * m,
                minLongitude: r.center.longitude - r.span.longitudeDelta * m,
                maxLongitude: r.center.longitude + r.span.longitudeDelta * m)
            let visible = index.coordinates(in: box)
            // Cap so the clusterer stays fast on dense regions; the cap only drops far-from-centre points.
            let capped = visible.count > 3000 ? Array(visible.prefix(3000)) : visible
            let wanted = Set(capped.map(\.uid))

            let stale = map.annotations.compactMap { $0 as? PhotoMapAnnotation }.filter { !wanted.contains($0.uid) }
            if !stale.isEmpty {
                map.removeAnnotations(stale)
                shownUIDs.subtract(stale.map(\.uid))
            }
            let fresh = capped.filter { !shownUIDs.contains($0.uid) }
            if !fresh.isEmpty {
                map.addAnnotations(fresh.map(PhotoMapAnnotation.init))
                shownUIDs.formUnion(fresh.map(\.uid))
            }
        }

        private func boundingRect(of coords: [CLLocationCoordinate2D]) -> MKMapRect {
            coords.reduce(MKMapRect.null) { acc, c in
                let p = MKMapPoint(c)
                return acc.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
            }
        }

        // MARK: MKMapViewDelegate

        public func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            reloadVisible()
        }

        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier, for: annotation) as! PhotoClusterAnnotationView
                let hero = cluster.memberAnnotations.first as? PhotoMapAnnotation   // v1: first member (best/cover later)
                view.configure(thumbnail: hero.flatMap { thumbnail($0.uid) }, count: cluster.memberAnnotations.count)
                return view
            }
            guard let photo = annotation as? PhotoMapAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: PhotoAnnotationView.reuseID, for: annotation) as! PhotoAnnotationView
            view.setThumbnail(thumbnail(photo.uid))
            return view
        }

        public func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                let rect = boundingRect(of: cluster.memberAnnotations.map(\.coordinate))
                if !rect.isNull {
                    mapView.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 120, left: 120, bottom: 120, right: 120), animated: true)
                }
                mapView.deselectAnnotation(view.annotation, animated: false)
            } else if let photo = view.annotation as? PhotoMapAnnotation {
                onSelectPhoto(photo.uid)
                mapView.deselectAnnotation(view.annotation, animated: false)
            }
        }
    }
}
