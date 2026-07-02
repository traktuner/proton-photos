import AppKit

// Small AppKit overlay views used by the Metal production grid's header layer (`MetalGridHeaderRenderer`).
// Pure display views for the month-label overlay - no grid geometry.

/// A flipped (top-left origin) overlay container that is transparent to events, so scrolling/clicks pass
/// straight through to the grid below it.
final class FlippedOverlayView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Liquid-Glass pill showing the month + year, overlaid on the dense square overview levels.
final class MonthLabelView: NSView {
    private let blur = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.zPosition = 100          // stay above the photo cells
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)
        label.font = .systemFont(ofSize: 22, weight: .bold)
        label.textColor = .white
        label.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = CGSize(width: 0, height: -1)
            return shadow
        }()
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setText(_ t: String) { label.stringValue = t }
    var fittingWidth: CGFloat { label.intrinsicContentSize.width + 24 }
}
