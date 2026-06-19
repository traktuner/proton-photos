import AppKit
import PhotosCore

/// Minimal accessibility for the Metal grid. Because the Metal renderer has no per-cell `NSView`, this
/// synthesizes `NSAccessibilityElement`s for the currently-visible items (role image, a date/kind label,
/// selected state, and a press action that opens the viewer) and assigns them as the host's children,
/// rebuilding on each viewport change. This is a baseline — NOT full `NSCollectionView` parity — which is
/// why the NSCollectionView fallback is retained. See the report's accessibility section.
@MainActor
final class MetalGridAccessibilityProvider {
    private weak var host: NSView?
    private weak var coordinator: MetalGridCoordinator?
    var items: [PhotoItem] = []
    var selected: Set<PhotoUID> = []
    var onOpen: ((PhotoUID) -> Void)?

    init(host: NSView, coordinator: MetalGridCoordinator) {
        self.host = host
        self.coordinator = coordinator
        host.setAccessibilityElement(true)
        host.setAccessibilityRole(.group)
        host.setAccessibilityLabel("Photo library grid")
    }

    /// Rebuild the visible accessibility elements and assign them to the host.
    func invalidate() {
        guard let host, let coordinator, let window = host.window else { return }
        let hostHeight = host.bounds.height
        var elements: [NSAccessibilityElement] = []
        for cell in coordinator.visibleCells() {
            guard cell.flatIndex < items.count else { continue }
            let item = items[cell.flatIndex]
            let vp = MetalGridGeometry.viewportRect(contentRect: cell.rect, visibleOrigin: CGPoint(x: 0, y: coordinator.scrollOriginY))
            // viewport (top-left, y-down) → host-local (y-up) → window → screen.
            let localYUp = CGRect(x: vp.minX, y: hostHeight - vp.maxY, width: vp.width, height: vp.height)
            let screen = window.convertToScreen(host.convert(localYUp, to: nil))
            let element = MetalGridA11yElement()
            element.setAccessibilityParent(host)
            element.setAccessibilityRole(.image)
            element.setAccessibilityLabel(Self.label(for: item))
            element.setAccessibilityFrame(screen)
            element.setAccessibilitySelected(selected.contains(item.uid))
            element.uid = item.uid
            element.onOpen = onOpen
            elements.append(element)
        }
        host.setAccessibilityChildren(elements)
    }

    /// VoiceOver label for a photo: kind + capture date.
    static func label(for item: PhotoItem) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let kind = item.isVideo ? "Video" : "Photo"
        return "\(kind), \(df.string(from: item.captureTime))"
    }
}

/// An accessibility element whose press action opens the viewer for its photo.
final class MetalGridA11yElement: NSAccessibilityElement {
    var uid: PhotoUID?
    var onOpen: ((PhotoUID) -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let uid else { return false }
        onOpen?(uid)
        return true
    }
}
