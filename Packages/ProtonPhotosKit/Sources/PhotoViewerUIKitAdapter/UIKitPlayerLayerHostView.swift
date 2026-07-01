#if canImport(UIKit)
import AVFoundation
import UIKit

public final class UIKitPlayerLayerHostView: UIView {
    public override class var layerClass: AnyClass { AVPlayerLayer.self }

    public var playerLayer: AVPlayerLayer {
        guard let layer = layer as? AVPlayerLayer else {
            preconditionFailure("UIKitPlayerLayerHostView must be backed by AVPlayerLayer")
        }
        return layer
    }

    public var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    public override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        configureLayer()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    public func configure(player: AVPlayer?, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        self.player = player
        playerLayer.videoGravity = videoGravity
    }

    private func configureLayer() {
        isOpaque = false
        backgroundColor = .clear
        playerLayer.videoGravity = .resizeAspect
    }
}
#endif
