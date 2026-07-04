import DesignSystemCore
import MapUIKitAdapter
import MediaLocationCore
import PhotosCore
import SwiftUI
import UIKit

/// Map tab. Presents the shared `UIKitLibraryMapHostView` over the library's GPS index, which a background crawl
/// fills. Shows a real, honest empty state until geotagged photos are found; tapping a pin opens the viewer.
struct MobileMapScreen: View {
    @Environment(MobileLibraryModel.self) private var model
    @State private var viewer: MobileViewerPresentation?

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
                } else {
                    MobileLibraryMap(
                        index: model.locationIndex,
                        revision: revision,
                        thumbnail: { model.thumbnailFeed?.memoryImage(for: $0) },
                        onSelectPhoto: openPhoto
                    )
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle(String(localized: "tab.map"))
            // Re-runs when the library finishes loading, so opening Map before the timeline is ready still starts
            // the crawl once items exist (the start is idempotent).
            .task(id: model.items.isEmpty) { model.startLocationCrawlIfNeeded() }
        }
        .fullScreenCover(item: $viewer) { presentation in
            MobilePhotoViewer(items: presentation.items, startIndex: presentation.index, libraryModel: model)
        }
    }

    private func openPhoto(_ uid: PhotoUID) {
        guard let index = model.index(of: uid) else { return }   // O(1) via the snapshot index
        viewer = MobileViewerPresentation(index: index, items: model.items)
    }
}

/// SwiftUI wrapper around the shared UIKit map host. `revision` is an input only so SwiftUI re-invokes
/// `updateUIView` (→ `refreshIfChanged`) as the crawl adds coordinates.
private struct MobileLibraryMap: UIViewRepresentable {
    let index: PhotoLocationIndex
    let revision: Int
    let thumbnail: (PhotoUID) -> UIImage?
    let onSelectPhoto: (PhotoUID) -> Void

    func makeUIView(context: Context) -> UIKitLibraryMapHostView {
        UIKitLibraryMapHostView(
            index: index,
            visibleCoordinatePolicy: PhotoLocationVisibleCoordinatePolicy(marginMultiplier: 1.6, maxCoordinates: 3000),
            thumbnail: thumbnail,
            onSelectPhoto: onSelectPhoto
        )
    }

    func updateUIView(_ view: UIKitLibraryMapHostView, context: Context) {
        view.configure(thumbnail: thumbnail, onSelectPhoto: onSelectPhoto)
        view.refreshIfChanged()
    }
}
