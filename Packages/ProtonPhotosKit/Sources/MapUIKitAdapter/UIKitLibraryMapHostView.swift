#if canImport(UIKit)
import MapKit
import MediaLocationCore
import PhotosCore
import UIKit

@MainActor
public final class UIKitLibraryMapHostView: UIView {
    private let mapView = MKMapView()
    private let index: PhotoLocationIndex
    private let visibleCoordinatePolicy: PhotoLocationVisibleCoordinatePolicy
    private var thumbnail: (PhotoUID) -> UIImage?
    private var loadThumbnail: (PhotoUID) async -> UIImage?
    private var onSelectPhoto: (PhotoUID) -> Void
    private var shownUIDs = Set<PhotoUID>()
    private var thumbnailLoadsInFlight = Set<PhotoUID>()
    private var lastRevision = Int.min
    private var didFrame = false

    public init(
        index: PhotoLocationIndex,
        visibleCoordinatePolicy: PhotoLocationVisibleCoordinatePolicy,
        thumbnail: @escaping (PhotoUID) -> UIImage?,
        loadThumbnail: @escaping (PhotoUID) async -> UIImage?,
        onSelectPhoto: @escaping (PhotoUID) -> Void
    ) {
        self.index = index
        self.visibleCoordinatePolicy = visibleCoordinatePolicy
        self.thumbnail = thumbnail
        self.loadThumbnail = loadThumbnail
        self.onSelectPhoto = onSelectPhoto
        super.init(frame: .zero)
        configureMap()
        frameToDenseCoreIfNeeded()
        reloadVisible()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func configure(
        thumbnail: @escaping (PhotoUID) -> UIImage?,
        loadThumbnail: @escaping (PhotoUID) async -> UIImage?,
        onSelectPhoto: @escaping (PhotoUID) -> Void
    ) {
        self.thumbnail = thumbnail
        self.loadThumbnail = loadThumbnail
        self.onSelectPhoto = onSelectPhoto
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

        let stale = mapView.annotations
            .compactMap { $0 as? UIKitPhotoMapAnnotation }
            .filter { !wanted.contains($0.uid) }
        if !stale.isEmpty {
            mapView.removeAnnotations(stale)
            shownUIDs.subtract(stale.map(\.uid))
        }

        let fresh = visible.filter { !shownUIDs.contains($0.uid) }
        if !fresh.isEmpty {
            mapView.addAnnotations(fresh.map(UIKitPhotoMapAnnotation.init))
            shownUIDs.formUnion(fresh.map(\.uid))
        }
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
            let rect = boundingRect(of: cluster.memberAnnotations.map(\.coordinate))
            if !rect.isNull {
                mapView.setVisibleMapRect(
                    rect,
                    edgePadding: UIEdgeInsets(top: 120, left: 120, bottom: 120, right: 120),
                    animated: true
                )
            }
            mapView.deselectAnnotation(view.annotation, animated: false)
        } else if let photo = view.annotation as? UIKitPhotoMapAnnotation {
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

    private func applyLoadedThumbnail(_ image: UIImage, for uid: PhotoUID) {
        if let annotation = mapView.annotations
            .compactMap({ $0 as? UIKitPhotoMapAnnotation })
            .first(where: { $0.uid == uid }),
           let view = mapView.view(for: annotation) as? UIKitPhotoAnnotationView {
            view.setThumbnail(image)
        }

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
