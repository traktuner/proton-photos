#if canImport(UIKit)
import MapKit
import UIKit

private enum UIKitMapBadgeStyle {
    static let size: CGFloat = 54
    static let corner: CGFloat = 12
    static let border: CGFloat = 3
}

final class UIKitPhotoAnnotationView: MKAnnotationView {
    static let reuseID = "UIKitPhotoAnnotation"

    private let imageLayer = CALayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = "photo"
        frame = CGRect(x: 0, y: 0, width: UIKitMapBadgeStyle.size, height: UIKitMapBadgeStyle.size)
        centerOffset = CGPoint(x: 0, y: -UIKitMapBadgeStyle.size / 2)
        configureContainer(layer)
        imageLayer.frame = layer.bounds.insetBy(dx: UIKitMapBadgeStyle.border, dy: UIKitMapBadgeStyle.border)
        imageLayer.cornerRadius = UIKitMapBadgeStyle.corner - UIKitMapBadgeStyle.border
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        layer.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setThumbnail(_ image: UIImage?) {
        imageLayer.contentsScale = image?.scale ?? currentDisplayScale
        imageLayer.contents = image?.cgImage
        imageLayer.backgroundColor = image == nil ? UIColor.secondaryLabel.cgColor : nil
    }

    private func configureContainer(_ layer: CALayer) {
        layer.contentsScale = currentDisplayScale
        layer.cornerRadius = UIKitMapBadgeStyle.corner
        layer.backgroundColor = UIColor.white.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    private var currentDisplayScale: CGFloat {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        guard scale.isFinite, scale > 0 else { return 1 }
        return scale
    }
}

final class UIKitPhotoClusterAnnotationView: MKAnnotationView {
    private let imageLayer = CALayer()
    private let countLabel = UILabel()
    private let countBackground = CALayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let size = UIKitMapBadgeStyle.size + 8
        frame = CGRect(x: 0, y: 0, width: size, height: size)
        centerOffset = CGPoint(x: 0, y: -size / 2)
        collisionMode = .circle

        layer.cornerRadius = UIKitMapBadgeStyle.corner
        layer.backgroundColor = UIColor.white.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 1)

        imageLayer.frame = layer.bounds.insetBy(dx: UIKitMapBadgeStyle.border, dy: UIKitMapBadgeStyle.border)
        imageLayer.cornerRadius = UIKitMapBadgeStyle.corner - UIKitMapBadgeStyle.border
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        layer.addSublayer(imageLayer)

        countBackground.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
        countBackground.cornerRadius = 8
        layer.addSublayer(countBackground)

        countLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        countLabel.textColor = .white
        countLabel.backgroundColor = .clear
        addSubview(countLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(thumbnail: UIImage?, count: Int) {
        imageLayer.contentsScale = thumbnail?.scale ?? currentDisplayScale
        imageLayer.contents = thumbnail?.cgImage
        imageLayer.backgroundColor = thumbnail == nil ? UIColor.secondaryLabel.cgColor : nil
        countLabel.text = "\(count)"
        countLabel.sizeToFit()

        let pad: CGFloat = 6
        let width = countLabel.frame.width + pad * 2
        let height = countLabel.frame.height + 2
        let y = bounds.height - UIKitMapBadgeStyle.border - height - 1
        countLabel.frame = CGRect(
            x: UIKitMapBadgeStyle.border + pad + 1,
            y: y + 1,
            width: countLabel.frame.width,
            height: countLabel.frame.height
        )
        countBackground.frame = CGRect(
            x: UIKitMapBadgeStyle.border + 1,
            y: y,
            width: width,
            height: height
        )
    }

    private var currentDisplayScale: CGFloat {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        guard scale.isFinite, scale > 0 else { return 1 }
        return scale
    }
}
#endif
