import AppKit
import MapKit

/// Shared rounded-photo badge styling (Apple-Photos look): a thumbnail in a white-bordered rounded square
/// with a soft shadow. The cluster variant adds a count pill.
private enum BadgeStyle {
    static let size: CGFloat = 54
    static let corner: CGFloat = 12
    static let border: CGFloat = 3
}

/// A single photo on the map - a rounded thumbnail. Carries a `clusteringIdentifier` so MapKit merges
/// nearby photos into a `MKClusterAnnotation` as the user zooms out.
final class PhotoAnnotationView: MKAnnotationView {
    static let reuseID = "PhotoAnnotation"

    private let imageLayer = CALayer()
    private let countLabel = NSTextField(labelWithString: "")
    private let countBackground = CALayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = "photo"
        // MKAnnotationView defaults to displayPriority .required, and MapKit NEVER clusters
        // required-priority annotations (they are always shown). Without this, every photo pin
        // stays visible and overlaps instead of collapsing into a count badge. .defaultLow lets
        // MapKit merge overlapping pins; .circle matches the cluster view's collision shape.
        displayPriority = .defaultLow
        collisionMode = .circle
        frame = CGRect(x: 0, y: 0, width: BadgeStyle.size, height: BadgeStyle.size)
        centerOffset = CGPoint(x: 0, y: -BadgeStyle.size / 2)
        wantsLayer = true
        configureContainer(layer!)
        imageLayer.frame = layer!.bounds.insetBy(dx: BadgeStyle.border, dy: BadgeStyle.border)
        imageLayer.cornerRadius = BadgeStyle.corner - BadgeStyle.border
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        layer!.addSublayer(imageLayer)

        // Count badge — a single aggregated cell can stand for many photos (memberCount), so it needs
        // the same "N photos here" pill the cluster view has. Hidden for a cell of exactly one photo.
        countBackground.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        countBackground.cornerRadius = 8
        countBackground.isHidden = true
        layer!.addSublayer(countBackground)

        countLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        countLabel.textColor = .white
        countLabel.backgroundColor = .clear
        countLabel.isBezeled = false
        countLabel.isEditable = false
        countLabel.isHidden = true
        addSubview(countLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setThumbnail(_ image: NSImage?) {
        imageLayer.contents = image
        imageLayer.backgroundColor = image == nil ? NSColor.secondaryLabelColor.cgColor : nil
    }

    /// Show a "N" pill when the cell aggregates more than one photo; hide it for a single photo.
    func setCount(_ count: Int) {
        guard count > 1 else {
            countLabel.isHidden = true
            countBackground.isHidden = true
            return
        }
        countLabel.isHidden = false
        countBackground.isHidden = false
        countLabel.stringValue = "\(count)"
        countLabel.sizeToFit()
        let pad: CGFloat = 6
        let w = countLabel.frame.width + pad * 2
        let h = countLabel.frame.height + 2
        countLabel.frame = CGRect(x: BadgeStyle.border + pad + 1, y: BadgeStyle.border + 2, width: countLabel.frame.width, height: countLabel.frame.height)
        countBackground.frame = CGRect(x: BadgeStyle.border + 1, y: BadgeStyle.border + 1, width: w, height: h)
    }

    fileprivate func configureContainer(_ l: CALayer) {
        l.cornerRadius = BadgeStyle.corner
        l.backgroundColor = NSColor.white.cgColor
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.25
        l.shadowRadius = 4
        l.shadowOffset = CGSize(width: 0, height: -1)
    }
}

/// A cluster of photos - the hero thumbnail with a count pill (e.g. "52"), like Apple Photos. The hero is
/// the first member for now (a best/cover heuristic can replace `heroUID` later).
final class PhotoClusterAnnotationView: MKAnnotationView {
    private let imageLayer = CALayer()
    private let countLabel = NSTextField(labelWithString: "")
    private let countBackground = CALayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let s = BadgeStyle.size + 8
        frame = CGRect(x: 0, y: 0, width: s, height: s)
        centerOffset = CGPoint(x: 0, y: -s / 2)
        collisionMode = .circle
        wantsLayer = true
        layer!.cornerRadius = BadgeStyle.corner
        layer!.backgroundColor = NSColor.white.cgColor
        layer!.shadowColor = NSColor.black.cgColor
        layer!.shadowOpacity = 0.25
        layer!.shadowRadius = 4
        layer!.shadowOffset = CGSize(width: 0, height: -1)

        imageLayer.frame = layer!.bounds.insetBy(dx: BadgeStyle.border, dy: BadgeStyle.border)
        imageLayer.cornerRadius = BadgeStyle.corner - BadgeStyle.border
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        layer!.addSublayer(imageLayer)

        countBackground.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        countBackground.cornerRadius = 8
        layer!.addSublayer(countBackground)

        countLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        countLabel.textColor = .white
        countLabel.backgroundColor = .clear
        countLabel.isBezeled = false
        countLabel.isEditable = false
        addSubview(countLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(thumbnail: NSImage?, count: Int) {
        imageLayer.contents = thumbnail
        imageLayer.backgroundColor = thumbnail == nil ? NSColor.secondaryLabelColor.cgColor : nil
        countLabel.stringValue = "\(count)"
        countLabel.sizeToFit()
        let pad: CGFloat = 6
        let w = countLabel.frame.width + pad * 2
        let h = countLabel.frame.height + 2
        // Bottom-left pill, like the screenshot.
        countLabel.frame = CGRect(x: BadgeStyle.border + pad + 1, y: BadgeStyle.border + 2, width: countLabel.frame.width, height: countLabel.frame.height)
        countBackground.frame = CGRect(x: BadgeStyle.border + 1, y: BadgeStyle.border + 1, width: w, height: h)
    }
}
