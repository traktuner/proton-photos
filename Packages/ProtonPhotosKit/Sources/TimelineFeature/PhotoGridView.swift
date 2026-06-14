import SwiftUI
import AppKit
import PhotosCore
import MediaCache

/// The photo grid, built on NSCollectionView (Apple Photos for Mac uses the same component) for a
/// truly native, performant justified grid with smooth pinch-zoom at 20k+ photos.
struct PhotoGridView: NSViewRepresentable {
    let sections: [TimelineSection]
    let allItems: [PhotoItem]
    let feed: ThumbnailFeed
    /// Aspect ratio (w/h) per item per section, precomputed by the parent (MainActor).
    let sectionAspects: [[CGFloat]]
    @Binding var cellZoom: CGFloat
    let onOpen: (PhotoItem, [PhotoItem]) -> Void

    private let baseRowHeight: CGFloat = 168

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = JustifiedCollectionLayout()
        layout.rowHeight = baseRowHeight * cellZoom

        let collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(PhotoGridItem.self, forItemWithIdentifier: PhotoGridItem.identifier)
        collectionView.register(
            DateHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: DateHeaderView.identifier
        )

        let magnify = NSMagnificationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMagnify(_:)))
        collectionView.addGestureRecognizer(magnify)

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        context.coordinator.collectionView = collectionView
        context.coordinator.layout = layout
        context.coordinator.baseRowHeight = baseRowHeight
        context.coordinator.apply(sections: sections, sectionAspects: sectionAspects)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(sections: sections, sectionAspects: sectionAspects)
        // Keep the layout row height in sync with the binding (e.g. the +/- toolbar buttons).
        let target = baseRowHeight * cellZoom
        if let layout = context.coordinator.layout, abs(layout.rowHeight - target) > 0.5,
           !context.coordinator.isPinching {
            layout.rowHeight = target
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: PhotoGridView
        weak var collectionView: NSCollectionView?
        weak var layout: JustifiedCollectionLayout?
        var baseRowHeight: CGFloat = 168
        var isPinching = false
        private var startRowHeight: CGFloat = 168
        private var sections: [TimelineSection] = []
        private var sectionItemCounts: [Int] = []

        init(_ parent: PhotoGridView) { self.parent = parent }

        func apply(sections: [TimelineSection], sectionAspects: [[CGFloat]]) {
            let counts = sections.map(\.items.count)
            let structureChanged = counts != sectionItemCounts
            self.sections = sections
            self.sectionItemCounts = counts
            layout?.sectionAspects = sectionAspects
            if structureChanged {
                collectionView?.reloadData()
            } else {
                layout?.invalidateLayout()
            }
        }

        // MARK: Data source

        func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            sections[section].items.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: PhotoGridItem.identifier, for: indexPath) as! PhotoGridItem
            let photo = sections[indexPath.section].items[indexPath.item]
            item.configure(photo: photo, feed: parent.feed)
            return item
        }

        func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
            let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: DateHeaderView.identifier, for: indexPath) as! DateHeaderView
            header.title = sections[indexPath.section].title
            return header
        }

        // MARK: Delegate

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard let indexPath = indexPaths.first else { return }
            let photo = sections[indexPath.section].items[indexPath.item]
            collectionView.deselectItems(at: indexPaths)
            parent.onOpen(photo, parent.allItems)
        }

        // MARK: Pinch zoom

        @objc func handleMagnify(_ recognizer: NSMagnificationGestureRecognizer) {
            guard let layout else { return }
            switch recognizer.state {
            case .began:
                isPinching = true
                startRowHeight = layout.rowHeight
            case .changed:
                let proposed = startRowHeight * (1 + recognizer.magnification)
                layout.rowHeight = min(max(proposed, baseRowHeight * 0.5), baseRowHeight * 2.6)
            case .ended, .cancelled, .failed:
                isPinching = false
                parent.cellZoom = layout.rowHeight / baseRowHeight
            default:
                break
            }
        }
    }
}
