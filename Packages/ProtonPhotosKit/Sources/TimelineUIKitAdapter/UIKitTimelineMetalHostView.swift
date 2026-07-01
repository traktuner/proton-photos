#if canImport(UIKit)
import Metal
import QuartzCore
import UIKit

public final class UIKitTimelineMetalHostView: UIView {
    public override class var layerClass: AnyClass { CAMetalLayer.self }

    public var metalLayer: CAMetalLayer {
        guard let layer = layer as? CAMetalLayer else {
            preconditionFailure("UIKitTimelineMetalHostView must be backed by CAMetalLayer")
        }
        return layer
    }

    public var viewportSize: CGSize { bounds.size }

    public override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        configureDefaults()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureDefaults()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableSize()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateDrawableSize()
    }

    public func configure(
        device: MTLDevice?,
        pixelFormat: MTLPixelFormat = .bgra8Unorm,
        isOpaque: Bool = true,
        presentsWithTransaction: Bool = false
    ) {
        self.isOpaque = isOpaque
        backgroundColor = isOpaque ? .black : .clear
        metalLayer.device = device
        metalLayer.pixelFormat = pixelFormat
        metalLayer.isOpaque = isOpaque
        metalLayer.presentsWithTransaction = presentsWithTransaction
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        updateDrawableSize()
    }

    public func updateDrawableSize(additionalScale: CGFloat = 1) {
        let scale = max(1, currentDisplayScale * max(1, additionalScale))
        metalLayer.contentsScale = scale
        contentScaleFactor = scale
        metalLayer.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
    }

    private var currentDisplayScale: CGFloat {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        guard scale.isFinite, scale > 0 else { return 1 }
        return scale
    }

    private func configureDefaults() {
        isOpaque = true
        backgroundColor = .black
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        updateDrawableSize()
    }
}
#endif
