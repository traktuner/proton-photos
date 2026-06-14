import SwiftUI
import AppKit
import QuartzCore
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

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        // Native, GPU-smooth pinch zoom centred on the cursor. We re-justify the grid to the new
        // density only when the live magnify ends (see the notification below).
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.5
        scrollView.maxMagnification = 3.0

        context.coordinator.collectionView = collectionView
        context.coordinator.layout = layout
        context.coordinator.scrollView = scrollView
        context.coordinator.baseRowHeight = baseRowHeight
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.didEndLiveMagnify(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView
        )
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
        weak var scrollView: NSScrollView?
        var baseRowHeight: CGFloat = 168
        var isPinching = false
        private var sections: [TimelineSection] = []
        private var displayLink: CADisplayLink?
        private var settleStart: CFTimeInterval = 0
        private let settleDuration: CFTimeInterval = 0.42
        private var settleMagnification: CGFloat = 1
        private var settleRowHeight: CGFloat = 168
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

        /// During the pinch, NSScrollView magnifies the whole grid as one surface (GPU, cursor-
        /// anchored). When it ends, fold that magnification into the layout's row height so the grid
        /// re-justifies to the new density, and reset magnification to 1 — the cell size is
        /// unchanged across the swap, only the row packing updates.
        @MainActor @objc func didEndLiveMagnify(_ note: Notification) {
            guard let scrollView, let layout else { return }
            let magnification = scrollView.magnification
            guard abs(magnification - 1) > 0.02 else {
                scrollView.magnification = 1
                return
            }
            // Animate the settle: geometrically unwind magnification to 1 while growing the row
            // height, so the visual size stays constant and the grid continuously re-justifies into
            // the new density (cells reorganise smoothly — no snap, no size bulge).
            settleMagnification = magnification
            settleRowHeight = layout.rowHeight
            settleStart = CACurrentMediaTime()
            displayLink?.invalidate()
            let link = collectionView?.displayLink(target: self, selector: #selector(stepSettle(_:)))
            link?.add(to: .main, forMode: .common)
            displayLink = link
        }

        @MainActor @objc private func stepSettle(_ link: CADisplayLink) {
            guard let scrollView, let layout else { link.invalidate(); displayLink = nil; return }
            let t = min(1, max(0, (CACurrentMediaTime() - settleStart) / settleDuration))
            let eased = 1 - pow(1 - t, 3)                                   // ease-out cubic
            let m = Double(settleMagnification)
            scrollView.magnification = CGFloat(pow(m, 1 - eased))           // M → 1
            layout.rowHeight = CGFloat(Double(settleRowHeight) * pow(m, eased))  // old → old·M

            if t >= 1 {
                scrollView.magnification = 1
                let finalRowHeight = min(max(settleRowHeight * settleMagnification, baseRowHeight * 0.5), baseRowHeight * 2.6)
                layout.rowHeight = finalRowHeight
                parent.cellZoom = finalRowHeight / baseRowHeight
                link.invalidate()
                displayLink = nil
            }
        }
    }
}
