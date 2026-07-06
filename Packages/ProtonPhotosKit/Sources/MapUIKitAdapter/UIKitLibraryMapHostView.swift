#if canImport(UIKit)
import MapKit
import MediaLocationCore
import os
import PhotosCore
import UIKit

@MainActor
public final class UIKitLibraryMapHostView: UIView {
    /// Logger for measuring the cost of region changes and annotation updates, so the cap choice
    /// can be driven by measured density instead of guesses.
    private static let perfLog = OSLog(subsystem: "ch.protonmail.photos", category: "MapPerf")

    private let mapView = MKMapView()
    private let index: PhotoLocationIndex
    private let visibleCoordinatePolicy: PhotoLocationVisibleCoordinatePolicy
    private var thumbnail: (PhotoUID) -> UIImage?
    private var loadThumbnail: (PhotoUID) async -> UIImage?
    private var onSelectPhoto: (PhotoUID) -> Void
    private var onSelectCluster: (([PhotoUID], CLLocationCoordinate2D) -> Void)?
    private var shownUIDs = Set<PhotoUID>()
    /// UID → annotation, so `applyLoadedThumbnail` doesn't have to scan all mapView.annotations to
    /// find one UID (it was O(n) per loaded thumbnail — with 400 annotations during a pinch that
    /// is a real cost on the main thread). Rebuilt only when annotations are added/removed.
    private var annotationByUID: [PhotoUID: UIKitPhotoMapAnnotation] = [:]
    /// In-flight async thumbnail loads keyed by UID, so a region change can CANCEL stale loads for
    /// annotations that have been removed — otherwise every pinch-zoom in a dense region spawns hundreds
    /// of orphan tasks that all race to set thumbnails on views that no longer exist.
    private var thumbnailLoadTasks: [PhotoUID: Task<Void, Never>] = [:]
    private var lastRevision = Int.min
    private var didFrame = false

    public init(
        index: PhotoLocationIndex,
        visibleCoordinatePolicy: PhotoLocationVisibleCoordinatePolicy,
        thumbnail: @escaping (PhotoUID) -> UIImage?,
        loadThumbnail: @escaping (PhotoUID) async -> UIImage?,
        onSelectPhoto: @escaping (PhotoUID) -> Void,
        onSelectCluster: (([PhotoUID], CLLocationCoordinate2D) -> Void)? = nil
    ) {
        self.index = index
        self.visibleCoordinatePolicy = visibleCoordinatePolicy
        self.thumbnail = thumbnail
        self.loadThumbnail = loadThumbnail
        self.onSelectPhoto = onSelectPhoto
        self.onSelectCluster = onSelectCluster
        super.init(frame: .zero)
        configureMap()
        frameToDenseCoreIfNeeded()
        reloadVisible()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        // Cancel all in-flight thumbnail loads when the view is torn down so they don't try to
        // access a deallocated host after a region change or screen dismissal.
        for (_, task) in thumbnailLoadTasks {
            task.cancel()
        }
    }

    public func configure(
        thumbnail: @escaping (PhotoUID) -> UIImage?,
        loadThumbnail: @escaping (PhotoUID) async -> UIImage?,
        onSelectPhoto: @escaping (PhotoUID) -> Void,
        onSelectCluster: (([PhotoUID], CLLocationCoordinate2D) -> Void)? = nil
    ) {
        self.thumbnail = thumbnail
        self.loadThumbnail = loadThumbnail
        self.onSelectPhoto = onSelectPhoto
        self.onSelectCluster = onSelectCluster
        reloadVisible()
    }

    public func refreshIfChanged() {
        guard index.revision != lastRevision else { return }
        lastRevision = index.revision
        frameToDenseCoreIfNeeded()
        reloadVisible()
    }

    private func configureMap() {
        mapView.delegate = self
        mapView.showsUserLocation = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.register(UIKitPhotoAnnotationView.self, forAnnotationViewWithReuseIdentifier: UIKitPhotoAnnotationView.reuseID)
        mapView.register(
            UIKitPhotoClusterAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier
        )

        mapView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mapView)
        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mapView.topAnchor.constraint(equalTo: topAnchor),
            mapView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func frameToDenseCoreIfNeeded() {
        guard !didFrame, !index.coordinates.isEmpty else { return }
        // Frame where most of the photos are, not the bounds of every coordinate: one photo from a
        // trip abroad shouldn't drag the center out into the ocean.
        guard let box = PhotoLocationFraming.denseBoundingBox(for: index.coordinates) else { return }
        let rect = mapRect(for: box)
        guard !rect.isNull else { return }
        mapView.setVisibleMapRect(
            rect,
            edgePadding: UIEdgeInsets(top: 80, left: 80, bottom: 80, right: 80),
            animated: false
        )
        didFrame = true
    }

    private func mapRect(for box: GeoBoundingBox) -> MKMapRect {
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: box.minLatitude, longitude: box.minLongitude))
        let b = MKMapPoint(CLLocationCoordinate2D(latitude: box.maxLatitude, longitude: box.maxLongitude))
        return MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func reloadVisible() {
        let region = mapView.region
        let viewport = PhotoLocationViewport(
            centerLatitude: region.center.latitude,
            centerLongitude: region.center.longitude,
            latitudeDelta: region.span.latitudeDelta,
            longitudeDelta: region.span.longitudeDelta
        )
        let visible = index.coordinates(in: viewport, policy: visibleCoordinatePolicy)
        let wanted = Set(visible.map(\.uid))

        // Diff against the SHOWN set (not the mapView's full annotation array): iterating
        // `mapView.annotations` is O(n) and walks every MKClusterAnnotation too, which on a
        // 400-pin viewport during a pinch is enough to drop frames. The shown-UID set is the
        // authoritative tracker of what THIS host added.
        let toRemove = shownUIDs.subtracting(wanted)
        if !toRemove.isEmpty {
            let staleAnnotations = toRemove.compactMap { annotationByUID[$0] }
            if !staleAnnotations.isEmpty {
                mapView.removeAnnotations(staleAnnotations)
                for uid in toRemove { annotationByUID.removeValue(forKey: uid) }
                shownUIDs.subtract(toRemove)
            }
            // Cancel any in-flight thumbnail loads for the freshly-removed annotations so they
            // don't keep running (and then try to find a recycled view) after the pinch.
            for uid in toRemove {
                if let task = thumbnailLoadTasks.removeValue(forKey: uid) {
                    task.cancel()
                }
            }
        }

        let fresh = visible.filter { !shownUIDs.contains($0.uid) }
        if !fresh.isEmpty {
            let newAnnotations = fresh.map(UIKitPhotoMapAnnotation.init)
            for (i, coord) in fresh.enumerated() { annotationByUID[coord.uid] = newAnnotations[i] }
            mapView.addAnnotations(newAnnotations)
            shownUIDs.formUnion(fresh.map(\.uid))
        }

        // Perf logging: log the actual annotation density to measure where the bottleneck really is.
        // This helps decide if we need index-layer aggregation vs. just efficient diffing/cancellation.
        os_log("reloadVisible: visible=%{public}d wanted=%{public}d shown=%{public}d toRemove=%{public}d fresh=%{public}d thumbTasks=%{public}d",
               log: Self.perfLog, type: .debug,
               visible.count, wanted.count, shownUIDs.count, toRemove.count, fresh.count, thumbnailLoadTasks.count)
    }

    private func boundingRect(of coords: [CLLocationCoordinate2D]) -> MKMapRect {
        coords.reduce(MKMapRect.null) { result, coordinate in
            let point = MKMapPoint(coordinate)
            return result.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
    }
}

extension UIKitLibraryMapHostView: MKMapViewDelegate {
    public func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        reloadVisible()
    }

    public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if let cluster = annotation as? MKClusterAnnotation {
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier,
                for: annotation
            ) as! UIKitPhotoClusterAnnotationView
            let hero = cluster.memberAnnotations.first as? UIKitPhotoMapAnnotation
            let image = hero.flatMap { thumbnail($0.uid) }
            view.configure(thumbnail: image, count: cluster.memberAnnotations.count)
            if image == nil, let hero {
                requestThumbnailIfNeeded(hero.uid)
            }
            return view
        }

        guard let photo = annotation as? UIKitPhotoMapAnnotation else { return nil }
        let view = mapView.dequeueReusableAnnotationView(
            withIdentifier: UIKitPhotoAnnotationView.reuseID,
            for: annotation
        ) as! UIKitPhotoAnnotationView
        let image = thumbnail(photo.uid)
        view.setThumbnail(image)
        if image == nil {
            requestThumbnailIfNeeded(photo.uid)
        }
        return view
    }

    public func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
        if let cluster = view.annotation as? MKClusterAnnotation {
            if let handler = onSelectCluster {
                let uids = cluster.memberAnnotations.compactMap { ($0 as? UIKitPhotoMapAnnotation)?.uid }
                handler(uids, cluster.coordinate)
            } else {
                let rect = boundingRect(of: cluster.memberAnnotations.map(\.coordinate))
                if !rect.isNull {
                    mapView.setVisibleMapRect(
                        rect,
                        edgePadding: UIEdgeInsets(top: 120, left: 120, bottom: 120, right: 120),
                        animated: true
                    )
                }
            }
            mapView.deselectAnnotation(view.annotation, animated: false)
        } else if let photo = view.annotation as? UIKitPhotoMapAnnotation {
            onSelectPhoto(photo.uid)
            mapView.deselectAnnotation(view.annotation, animated: false)
        }
    }

    private func requestThumbnailIfNeeded(_ uid: PhotoUID) {
        // Skip if already in-flight OR already resident (the sync `thumbnail()` check in `viewFor`
        // covers the resident case, but the in-flight check here avoids queuing a duplicate load
        // for the same UID while the first one is still running).
        if thumbnailLoadTasks[uid] != nil { return }
        let loadThumbnail = loadThumbnail
        let task = Task { @MainActor [weak self] in
            let image = await loadThumbnail(uid)
            guard let self else { return }
            // Remove the task entry first — the load is done, the slot is free for a future re-request.
            self.thumbnailLoadTasks.removeValue(forKey: uid)
            // If the task was cancelled (annotation removed during a region change), don't bother
            // looking for the view — it's gone.
            if Task.isCancelled { return }
            guard let image else { return }
            self.applyLoadedThumbnail(image, for: uid)
        }
        thumbnailLoadTasks[uid] = task
    }

    private func applyLoadedThumbnail(_ image: UIImage, for uid: PhotoUID) {
        // Single-shot lookup via the index — O(1) instead of scanning all annotations.
        if let annotation = annotationByUID[uid],
           let view = mapView.view(for: annotation) as? UIKitPhotoAnnotationView {
            view.setThumbnail(image)
        }

        // Updating cluster thumbnails still requires scanning clusters, but with maxCoordinates=400
        // that's a tractable cost (the worst-case was 3000 × pinch, which was the real killer).
        for cluster in mapView.annotations.compactMap({ $0 as? MKClusterAnnotation }) {
            guard cluster.memberAnnotations.contains(where: { ($0 as? UIKitPhotoMapAnnotation)?.uid == uid }),
                  let view = mapView.view(for: cluster) as? UIKitPhotoClusterAnnotationView,
                  let hero = cluster.memberAnnotations.first as? UIKitPhotoMapAnnotation else { continue }
            view.configure(thumbnail: thumbnail(hero.uid) ?? (hero.uid == uid ? image : nil),
                           count: cluster.memberAnnotations.count)
        }
    }
}
#endif
