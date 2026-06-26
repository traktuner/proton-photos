import AppKit
import PhotosCore

/// Month/year label overlay for the Metal production grid. Uses `MonthLabelView` (Liquid-Glass pill) and
/// positions one per visible month boundary, only at the zoomed-out levels that show labels
/// (`monthLabels == true`). Display-only: the overlay never intercepts events (`FlippedOverlayView.hitTest`
/// returns nil), so scrolling/clicks pass straight to the grid below.
@MainActor
final class MetalGridHeaderRenderer {
    /// Pinned over the grid viewport (flipped, top-left origin, transparent to events).
    let overlay = FlippedOverlayView()
    private weak var coordinator: MetalGridCoordinator?
    private var labels: [MonthLabelView] = []
    var markers: [(index: Int, text: String)] = [] { didSet { reposition() } }

    init(coordinator: MetalGridCoordinator) {
        self.coordinator = coordinator
        overlay.wantsLayer = true
        overlay.autoresizingMask = [.width, .height]
    }

    func reposition() {
        guard let coordinator, coordinator.showsMonthLabels, !markers.isEmpty else { hideAll(); return }
        let originY = coordinator.scrollOriginY
        let vh = coordinator.viewportSize.height
        while labels.count < markers.count {
            let v = MonthLabelView()
            overlay.addSubview(v)
            labels.append(v)
        }
        for (i, marker) in markers.enumerated() {
            let v = labels[i]
            guard let rect = coordinator.cellContentRect(forFlatIndex: marker.index) else { v.isHidden = true; continue }
            let y = rect.minY - originY
            guard y >= -42, y <= vh else { v.isHidden = true; continue }   // only labels whose row is on screen
            v.setText(marker.text)
            // The overlay is full-width; pin the label 6pt inside the unobscured layout area (right of the sidebar).
            v.frame = NSRect(x: 12 + coordinator.leadingObstructionInset, y: y + 8, width: v.fittingWidth, height: 34)
            v.isHidden = false
        }
        for i in markers.count ..< labels.count { labels[i].isHidden = true }
    }

    private func hideAll() { for v in labels { v.isHidden = true } }
}
