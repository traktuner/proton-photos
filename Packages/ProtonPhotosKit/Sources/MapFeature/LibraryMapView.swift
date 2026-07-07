import SwiftUI
import MapKit
import AppKit
import MapCore
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
    private let onSelectCluster: ([PhotoUID], CLLocationCoordinate2D) -> Void

    public init(index: PhotoLocationIndex,
                thumbnail: @escaping (PhotoUID) -> NSImage?,
                loadThumbnail: @escaping (PhotoUID) async -> NSImage?,
                onSelectPhoto: @escaping (PhotoUID) -> Void,
                onSelectCluster: @escaping ([PhotoUID], CLLocationCoordinate2D) -> Void = { _, _ in }) {
        self.index = index
        self.thumbnail = thumbnail
        self.loadThumbnail = loadThumbnail
        self.onSelectPhoto = onSelectPhoto
        self.onSelectCluster = onSelectCluster
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
        context.coordinator.onSelectCluster = onSelectCluster
        context.coordinator.refreshIfChanged(revision: index.revision)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(index: index, thumbnail: thumbnail, loadThumbnail: loadThumbnail,
                    onSelectPhoto: onSelectPhoto, onSelectCluster: onSelectCluster)
    }

    @MainActor
    public final class Coordinator: NSObject, MKMapViewDelegate {
        private let index: PhotoLocationIndex
        var thumbnail: (PhotoUID) -> NSImage?
        var loadThumbnail: (PhotoUID) async -> NSImage?
        var onSelectPhoto: (PhotoUID) -> Void
        var onSelectCluster: ([PhotoUID], CLLocationCoordinate2D) -> Void
        private weak var map: MKMapView?
        private var thumbnailLoadTasks: [PhotoUID: Task<Void, Never>] = [:]
        /// Shared engine (MapCore): framing, off-main aggregation, diff, generation guard, add/remove.
        private var loader: PhotoMapAnnotationLoader!

        init(index: PhotoLocationIndex,
             thumbnail: @escaping (PhotoUID) -> NSImage?,
             loadThumbnail: @escaping (PhotoUID) async -> NSImage?,
             onSelectPhoto: @escaping (PhotoUID) -> Void,
             onSelectCluster: @escaping ([PhotoUID], CLLocationCoordinate2D) -> Void) {
            self.index = index
            self.thumbnail = thumbnail
            self.loadThumbnail = loadThumbnail
            self.onSelectPhoto = onSelectPhoto
            self.onSelectCluster = onSelectCluster
            super.init()
            self.loader = PhotoMapAnnotationLoader(
                index: index,
                policy: PhotoLocationVisibleCoordinatePolicy(
                    marginMultiplier: 1.6, maxCells: 400, cellDivisor: 12, minCellMeters: 80
                ),
                onRemoved: { [weak self] uids in
                    guard let self else { return }
                    for uid in uids { self.thumbnailLoadTasks.removeValue(forKey: uid)?.cancel() }
                }
            )
        }

        deinit {
            for (_, task) in thumbnailLoadTasks { task.cancel() }
        }

        func attach(_ map: MKMapView) {
            self.map = map
            loader.attach(map)
        }

        func refreshIfChanged(revision: Int) {
            loader.refreshIfChanged(revision: revision)
        }

        // MARK: MKMapViewDelegate

        public func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            loader.reloadVisible()
        }

        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier, for: annotation) as! PhotoClusterAnnotationView
                let hero = cluster.memberAnnotations.first as? PhotoMapAnnotation   // v1: first member (best/cover later)
                let image = hero.flatMap { thumbnail($0.uid) }
                // Sum each cell's memberCount so the badge shows every underlying photo the cluster
                // represents — not just the number of cell pins MapKit chose to show.
                let totalCount = cluster.memberAnnotations
                    .compactMap { $0 as? PhotoMapAnnotation }
                    .reduce(0) { $0 + $1.memberCount }
                view.configure(thumbnail: image, count: totalCount)
                if image == nil, let hero {
                    requestThumbnailIfNeeded(hero.uid)
                }
                return view
            }
            guard let photo = annotation as? PhotoMapAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: PhotoAnnotationView.reuseID, for: annotation) as! PhotoAnnotationView
            let image = thumbnail(photo.uid)
            view.setThumbnail(image)
            // A single cell can aggregate many photos (the minCellMeters floor merges a same-place
            // burst); show its true count so a multi-photo pin doesn't masquerade as a single picture.
            view.setCount(photo.memberCount)
            if image == nil {
                requestThumbnailIfNeeded(photo.uid)
            }
            return view
        }

        public func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                let uids = cluster.memberAnnotations
                    .compactMap { ($0 as? PhotoMapAnnotation)?.memberUIDs }
                    .flatMap { $0 }
                onSelectCluster(Self.unique(uids), cluster.coordinate)
                mapView.deselectAnnotation(view.annotation, animated: false)
            } else if let photo = view.annotation as? PhotoMapAnnotation {
                if photo.memberUIDs.count == 1 {
                    onSelectPhoto(photo.uid)
                } else {
                    onSelectCluster(photo.memberUIDs, photo.coordinate)
                }
                mapView.deselectAnnotation(view.annotation, animated: false)
            }
        }

        private func requestThumbnailIfNeeded(_ uid: PhotoUID) {
            guard thumbnailLoadTasks[uid] == nil else { return }
            let loadThumbnail = loadThumbnail
            thumbnailLoadTasks[uid] = Task { @MainActor [weak self] in
                let image = await loadThumbnail(uid)
                guard let self else { return }
                self.thumbnailLoadTasks.removeValue(forKey: uid)
                if Task.isCancelled { return }
                guard let image else { return }
                self.applyLoadedThumbnail(image, for: uid)
            }
        }

        private func applyLoadedThumbnail(_ image: NSImage, for uid: PhotoUID) {
            guard let map else { return }

            if let annotation = loader.annotation(for: uid),
               let view = map.view(for: annotation) as? PhotoAnnotationView {
                view.setThumbnail(image)
            }

            for cluster in map.annotations.compactMap({ $0 as? MKClusterAnnotation }) {
                guard cluster.memberAnnotations.contains(where: { ($0 as? PhotoMapAnnotation)?.uid == uid }),
                      let view = map.view(for: cluster) as? PhotoClusterAnnotationView,
                      let hero = cluster.memberAnnotations.first as? PhotoMapAnnotation else { continue }
                // Recompute the total count from memberCount (not memberAnnotations.count) so the badge
                // stays correct after a thumbnail refresh.
                let totalCount = cluster.memberAnnotations
                    .compactMap { $0 as? PhotoMapAnnotation }
                    .reduce(0) { $0 + $1.memberCount }
                view.configure(thumbnail: thumbnail(hero.uid) ?? (hero.uid == uid ? image : nil),
                               count: totalCount)
            }
        }

        private static func unique(_ uids: [PhotoUID]) -> [PhotoUID] {
            var seen = Set<PhotoUID>()
            return uids.filter { seen.insert($0).inserted }
        }
    }
}
