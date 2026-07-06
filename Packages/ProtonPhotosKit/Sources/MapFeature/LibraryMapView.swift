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
/// (the `revision` binding). macOS UI layer - an iOS/iPad variant reuses the same `PhotoLocationIndex`.
public struct LibraryMapView: NSViewRepresentable {
    private let index: PhotoLocationIndex
    private let thumbnail: (PhotoUID) -> NSImage?
    private let loadThumbnail: (PhotoUID) async -> NSImage?
    private let onSelectPhoto: (PhotoUID) -> Void

    public init(index: PhotoLocationIndex,
                thumbnail: @escaping (PhotoUID) -> NSImage?,
                loadThumbnail: @escaping (PhotoUID) async -> NSImage?,
                onSelectPhoto: @escaping (PhotoUID) -> Void) {
        self.index = index
        self.thumbnail = thumbnail
        self.loadThumbnail = loadThumbnail
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
        context.coordinator.loadThumbnail = loadThumbnail
        context.coordinator.onSelectPhoto = onSelectPhoto
        context.coordinator.refreshIfChanged(revision: index.revision)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(index: index, thumbnail: thumbnail, loadThumbnail: loadThumbnail, onSelectPhoto: onSelectPhoto)
    }

    @MainActor
    public final class Coordinator: NSObject, MKMapViewDelegate {
        private let index: PhotoLocationIndex
        var thumbnail: (PhotoUID) -> NSImage?
        var loadThumbnail: (PhotoUID) async -> NSImage?
        var onSelectPhoto: (PhotoUID) -> Void
        private weak var map: MKMapView?
        private var shownUIDs = Set<PhotoUID>()
        private var thumbnailLoadsInFlight = Set<PhotoUID>()
        private var lastRevision = Int.min
        private var didFrame = false
        private let visibleCoordinatePolicy = PhotoLocationVisibleCoordinatePolicy(
            marginMultiplier: 1.6,
            maxCoordinates: 3000
        )

        init(index: PhotoLocationIndex,
             thumbnail: @escaping (PhotoUID) -> NSImage?,
             loadThumbnail: @escaping (PhotoUID) async -> NSImage?,
             onSelectPhoto: @escaping (PhotoUID) -> Void) {
            self.index = index
            self.thumbnail = thumbnail
            self.loadThumbnail = loadThumbnail
            self.onSelectPhoto = onSelectPhoto
        }

        func attach(_ map: MKMapView) {
            self.map = map
            frameToDenseCoreIfNeeded()
            reloadVisible()
        }

        func refreshIfChanged(revision: Int) {
            guard revision != lastRevision else { return }
            lastRevision = revision
            frameToDenseCoreIfNeeded()
            reloadVisible()
        }

        /// Land the user where most of their photos are (once, when the first coordinates arrive).
        /// Frames the dense core, not the bounds of every coordinate, so a single photo from a trip
        /// abroad doesn't drag the center out into the ocean. Re-runs until there is data so the very
        /// first crawl batch frames it.
        private func frameToDenseCoreIfNeeded() {
            guard !didFrame, let map, !index.coordinates.isEmpty else { return }
            guard let box = PhotoLocationFraming.denseBoundingBox(for: index.coordinates) else { return }
            let a = MKMapPoint(CLLocationCoordinate2D(latitude: box.minLatitude, longitude: box.minLongitude))
            let b = MKMapPoint(CLLocationCoordinate2D(latitude: box.maxLatitude, longitude: box.maxLongitude))
            let rect = MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            guard !rect.isNull else { return }
            map.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 80, left: 80, bottom: 80, right: 80), animated: false)
            didFrame = true
        }

        /// Region-based loading: keep only the annotations whose photos are in the visible rect (+ margin),
        /// so the map never holds more than the on-screen subset. MapKit clusters that subset.
        private func reloadVisible() {
            guard let map else { return }
            let r = map.region
            let viewport = PhotoLocationViewport(
                centerLatitude: r.center.latitude,
                centerLongitude: r.center.longitude,
                latitudeDelta: r.span.latitudeDelta,
                longitudeDelta: r.span.longitudeDelta
            )
            let capped = index.coordinates(in: viewport, policy: visibleCoordinatePolicy)
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
                let image = hero.flatMap { thumbnail($0.uid) }
                view.configure(thumbnail: image, count: cluster.memberAnnotations.count)
                if image == nil, let hero {
                    requestThumbnailIfNeeded(hero.uid)
                }
                return view
            }
            guard let photo = annotation as? PhotoMapAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: PhotoAnnotationView.reuseID, for: annotation) as! PhotoAnnotationView
            let image = thumbnail(photo.uid)
            view.setThumbnail(image)
            if image == nil {
                requestThumbnailIfNeeded(photo.uid)
            }
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

        private func requestThumbnailIfNeeded(_ uid: PhotoUID) {
            guard !thumbnailLoadsInFlight.contains(uid) else { return }
            thumbnailLoadsInFlight.insert(uid)
            let loadThumbnail = loadThumbnail
            Task { @MainActor [weak self] in
                let image = await loadThumbnail(uid)
                guard let self else { return }
                self.thumbnailLoadsInFlight.remove(uid)
                guard let image else { return }
                self.applyLoadedThumbnail(image, for: uid)
            }
        }

        private func applyLoadedThumbnail(_ image: NSImage, for uid: PhotoUID) {
            guard let map else { return }

            if let annotation = map.annotations
                .compactMap({ $0 as? PhotoMapAnnotation })
                .first(where: { $0.uid == uid }),
               let view = map.view(for: annotation) as? PhotoAnnotationView {
                view.setThumbnail(image)
            }

            for cluster in map.annotations.compactMap({ $0 as? MKClusterAnnotation }) {
                guard cluster.memberAnnotations.contains(where: { ($0 as? PhotoMapAnnotation)?.uid == uid }),
                      let view = map.view(for: cluster) as? PhotoClusterAnnotationView,
                      let hero = cluster.memberAnnotations.first as? PhotoMapAnnotation else { continue }
                view.configure(thumbnail: thumbnail(hero.uid) ?? (hero.uid == uid ? image : nil),
                               count: cluster.memberAnnotations.count)
            }
        }
    }
}
