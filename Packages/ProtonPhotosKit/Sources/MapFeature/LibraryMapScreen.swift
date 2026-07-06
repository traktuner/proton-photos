import SwiftUI
import AppKit
import PhotosCore
import MediaLocationCore

/// SwiftUI wrapper that keeps the map in sync with the location index as the background crawl fills it in.
///
/// Reading `index.revision` in the body establishes Observation tracking, so every crawl batch re-renders
/// this view and re-invokes the map's `updateNSView` to add the new pins - even while the user is sitting
/// on the Map tab (where nothing else would trigger a re-render).
public struct LibraryMapScreen: View {
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

    public var body: some View {
        let _ = index.revision   // observe → re-render (→ updateNSView) as the crawl adds coordinates
        LibraryMapView(index: index, thumbnail: thumbnail, loadThumbnail: loadThumbnail, onSelectPhoto: onSelectPhoto)
    }
}
