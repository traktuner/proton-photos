import CoreLocation
import DesignSystemCore
import MapUIKitAdapter
import MediaLocationCore
import PhotosCore
import SwiftUI
import UIKit

/// Map tab. Presents the shared `UIKitLibraryMapHostView` over the library's GPS index, which a background crawl
/// fills. Shows a real, honest empty state until geotagged photos are found; tapping a pin opens the viewer.
/// Tapping a cluster pushes `MobileMapClusterSeriesScreen`, which lists all member photos in the shared grid.
struct MobileMapScreen: View {
    @Environment(MobileLibraryModel.self) private var model
    @Environment(MobileViewerRouter.self) private var viewerRouter
    @State private var networkMonitor = NetworkMonitor.shared
    @State private var clusterPresentation: MobileMapClusterPresentation?

    var body: some View {
        NavigationStack {
            // Reading `revision` registers this view with the @Observable index so it re-renders (and re-frames
            // the map) as the crawl adds coordinates.
            let revision = model.locationIndex.revision

            Group {
                if model.locationIndex.coordinates.isEmpty {
                    // Honest empty states: "scanning" while the GPS crawl runs, "no geotagged photos"
                    // only once it COMPLETED with zero finds, and a real-failure state when every probe
                    // failed. Only `.idle` (crawl not started, e.g. library still loading) keeps the
                    // generic message.
                    if !networkMonitor.isOnline {
                        OfflineContentUnavailableView()
                    } else {
                        switch model.locationIndex.scanProgress.phase {
                        case .scanning:
                            let progress = model.locationIndex.scanProgress
                            ContentUnavailableView {
                                Label("map.scanning_title", systemImage: "location.magnifyingglass")
                            } description: {
                                Text("map.scanning_message \(progress.scanned) \(progress.total)")
                            }
                        case .failed:
                            ContentUnavailableView {
                                Label("map.scan_failed_title", systemImage: "exclamationmark.triangle")
                            } description: {
                                Text("map.scan_failed_message")
                            }
                        case .completed:
                            ContentUnavailableView {
                                Label("map.empty_title", systemImage: "mappin.slash")
                            } description: {
                                Text("map.no_places_found_message")
                            }
                        case .idle:
                            ContentUnavailableView {
                                Label("map.empty_title", systemImage: "mappin.slash")
                            } description: {
                                Text("map.empty_message")
                            }
                        }
                    }
                } else {
                    MobileLibraryMap(
                        index: model.locationIndex,
                        revision: revision,
                        thumbnail: { model.thumbnailFeed?.memoryImage(for: $0) },
                        loadThumbnail: { await model.thumbnailFeed?.cachedImage(for: $0) },
                        onSelectPhoto: openPhoto,
                        onSelectCluster: { uids, coordinate in
                            clusterPresentation = MobileMapClusterPresentation(uids: uids, coordinate: coordinate)
                        }
                    )
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle(String(localized: "tab.map"))
            .navigationDestination(item: $clusterPresentation) { presentation in
                MobileMapClusterSeriesScreen(uids: presentation.uids, coordinate: presentation.coordinate)
            }
            // Re-runs when the library finishes loading, so opening Map before the timeline is ready still starts
            // the crawl once items exist (the start is idempotent).
            .task(id: model.items.isEmpty) { model.startLocationCrawlIfNeeded() }
            .onChange(of: networkMonitor.didRecentlyRestoreConnection) { _, restored in
                if restored {
                    model.restartLocationCrawlIfNeeded()
                }
            }
        }
    }

    private func openPhoto(_ uid: PhotoUID) {
        guard let index = model.index(of: uid) else { return }   // O(1) via the snapshot index
        viewerRouter.presentation = MobileViewerPresentation(index: index, items: model.items)
    }
}

/// Identifiable payload for pushing the cluster series screen: the member UIDs and the cluster's center
/// coordinate (used for reverse-geocoding the title).
private struct MobileMapClusterPresentation: Identifiable, Hashable {
    let id = UUID()
    let uids: [PhotoUID]
    let coordinate: CLLocationCoordinate2D

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MobileMapClusterPresentation, rhs: MobileMapClusterPresentation) -> Bool {
        lhs.id == rhs.id
    }
}

/// SwiftUI wrapper around the shared UIKit map host. `revision` is an input only so SwiftUI re-invokes
/// `updateUIView` (→ `refreshIfChanged`) as the crawl adds coordinates.
private struct MobileLibraryMap: UIViewRepresentable {
    let index: PhotoLocationIndex
    let revision: Int
    let thumbnail: (PhotoUID) -> UIImage?
    let loadThumbnail: (PhotoUID) async -> UIImage?
    let onSelectPhoto: (PhotoUID) -> Void
    let onSelectCluster: ([PhotoUID], CLLocationCoordinate2D) -> Void

    func makeUIView(context: Context) -> UIKitLibraryMapHostView {
        // Aggregation: each grid cell becomes one pin carrying the true photo count, so MKMapView
        // never manages thousands of individual views. maxCells caps the pin count (not the photo
        // count); cellDivisor controls grid granularity. See MAP_PERF_NOTES.
        return UIKitLibraryMapHostView(
            index: index,
            visibleCoordinatePolicy: PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 1.6, maxCells: 400, cellDivisor: 12, minCellMeters: 80),
            thumbnail: thumbnail,
            loadThumbnail: loadThumbnail,
            onSelectPhoto: onSelectPhoto,
            onSelectCluster: onSelectCluster
        )
    }

    func updateUIView(_ view: UIKitLibraryMapHostView, context: Context) {
        view.configure(
            thumbnail: thumbnail,
            loadThumbnail: loadThumbnail,
            onSelectPhoto: onSelectPhoto,
            onSelectCluster: onSelectCluster
        )
        view.refreshIfChanged()
    }
}
