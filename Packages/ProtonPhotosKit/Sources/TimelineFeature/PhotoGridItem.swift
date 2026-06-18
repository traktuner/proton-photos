import AppKit
import PhotosCore
import MediaCache

/// A grid cell: layer-backed aspect-fill thumbnail, loaded from the shared feed (cache-first).
final class PhotoGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoGridItem")

    private var loadTask: Task<Void, Never>?
    private var currentUID: PhotoUID?
    private var roundedView: RoundedCellView? { view as? RoundedCellView }
    private let checkBadge = NSImageView()
    private let heartBadge = NSImageView()
    private let durationBadge = NSView()
    private let durationLabel = NSTextField(labelWithString: "")

    private var cropMode: GridCropMode = .aspectFit

    override func loadView() {
        let container = RoundedCellView()           // rounded corners so each photo is a distinct cell
        container.thumbnailImage = GridThumbnailFallback.placeholderImage
        container.showsPlaceholder = true

        checkBadge.translatesAutoresizingMaskIntoConstraints = false
        checkBadge.isHidden = true
        checkBadge.imageScaling = .scaleProportionallyUpOrDown
        checkBadge.wantsLayer = true
        checkBadge.shadow = { let s = NSShadow(); s.shadowColor = .black.withAlphaComponent(0.5); s.shadowBlurRadius = 2; s.shadowOffset = .zero; return s }()
        container.addSubview(checkBadge)

        heartBadge.translatesAutoresizingMaskIntoConstraints = false
        heartBadge.isHidden = true
        heartBadge.image = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .bold))
        heartBadge.contentTintColor = .white
        heartBadge.shadow = { let s = NSShadow(); s.shadowColor = .black.withAlphaComponent(0.55); s.shadowBlurRadius = 2.5; s.shadowOffset = .zero; return s }()
        container.addSubview(heartBadge)

        durationBadge.translatesAutoresizingMaskIntoConstraints = false
        durationBadge.isHidden = true
        durationBadge.wantsLayer = true
        durationBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.64).cgColor
        durationBadge.layer?.cornerCurve = .continuous
        durationBadge.layer?.masksToBounds = true
        durationBadge.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(durationBadge)

        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.alignment = .center
        durationBadge.addSubview(durationLabel)

        NSLayoutConstraint.activate([
            checkBadge.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5),
            checkBadge.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
            checkBadge.widthAnchor.constraint(equalToConstant: 22),
            checkBadge.heightAnchor.constraint(equalToConstant: 22),
            heartBadge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
            heartBadge.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
            durationLabel.leadingAnchor.constraint(equalTo: durationBadge.leadingAnchor, constant: 12),
            durationLabel.trailingAnchor.constraint(equalTo: durationBadge.trailingAnchor, constant: -12),
            durationLabel.centerYAnchor.constraint(equalTo: durationBadge.centerYAnchor),
        ])
        self.view = container
    }

    func setFavorite(_ isFavorite: Bool) { heartBadge.isHidden = !isFavorite }

    func setDuration(_ seconds: Double?) {
        guard let seconds, seconds > 0, seconds.isFinite else {
            durationBadge.isHidden = true
            durationLabel.stringValue = ""
            return
        }
        durationLabel.stringValue = Self.durationString(seconds)
        durationBadge.isHidden = false
        layoutDurationBadge()
    }

    /// Shows/updates the selection badge. `mode` = selection mode active (badge visible at all);
    /// `isChecked` = this photo is selected.
    func setChecked(_ isChecked: Bool, mode: Bool) {
        checkBadge.isHidden = !mode
        guard mode else { view.alphaValue = 1; return }
        let name = isChecked ? "checkmark.circle.fill" : "circle"
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .bold)
        checkBadge.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        checkBadge.contentTintColor = isChecked ? .controlAccentColor : .white
        view.alphaValue = isChecked ? 0.82 : 1
    }

    /// Update only the crop mode (e.g. when the zoom level commits to a square-fill level) without
    /// reloading the cell — square-fill levels crop to fill, others letterbox.
    func setCropMode(_ mode: GridCropMode) {
        cropMode = mode
        roundedView?.cropMode = mode
        layoutDurationBadge()
    }

    func configure(photo: PhotoItem, feed: ThumbnailFeed, cropMode: GridCropMode) {
        currentUID = photo.uid
        loadTask?.cancel()
        setCropMode(cropMode)
        setDuration(photo.durationSeconds)
        let uid = photo.uid
        // Cache-first, SYNCHRONOUS: if the thumbnail is already decoded, show it immediately — no
        // clear-to-blank, no actor hop. This is what keeps the grid from flickering grey as cells
        // enter/leave during a live pinch re-justify.
        if let cached = feed.memoryImage(for: uid) {
            roundedView?.showsPlaceholder = false
            roundedView?.thumbnailImage = cached.cgImage(forProposedRect: nil, context: nil, hints: nil)
            layoutDurationBadge()
            PhotoDiagnostics.shared.classifyThumbnail(ThumbnailVisualClassification(
                uid: uid,
                rect: view.bounds,
                state: .realImageDrawn,
                phase: "scroll",
                context: "normalCell.ramDecodedHit"
            ))
            return
        }
        roundedView?.showsPlaceholder = true
        roundedView?.thumbnailImage = GridThumbnailFallback.placeholderImage
        layoutDurationBadge()
        let placeholderState: ThumbnailVisualState
        switch feed.knownDiskThumbnailPresent(for: uid) {
        case .some(true): placeholderState = .diskHitRamMissing
        case .some(false): placeholderState = .diskMissing
        case .none: placeholderState = .placeholderDrawn
        }
        PhotoDiagnostics.shared.classifyThumbnail(ThumbnailVisualClassification(
            uid: uid,
            rect: view.bounds,
            state: placeholderState,
            phase: "scroll",
            context: "normalCell.placeholderVisible"
        ))
        loadTask = Task { [weak self] in
            while !Task.isCancelled {
                if let image = await feed.cachedImage(for: uid) {
                    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    await MainActor.run {
                        guard let self, self.currentUID == uid else { return }
                        self.roundedView?.showsPlaceholder = false
                        self.roundedView?.thumbnailImage = cg
                        self.layoutDurationBadge()
                        PhotoDiagnostics.shared.classifyThumbnail(ThumbnailVisualClassification(
                            uid: uid,
                            rect: self.view.bounds,
                            state: .realImageDrawn,
                            phase: "scroll",
                            context: "normalCell.asyncSwapInPlace"
                        ))
                    }
                    return
                }
                await feed.requestPriority(uid, priority: .visibleNow)
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        currentUID = nil
        roundedView?.showsPlaceholder = true
        roundedView?.thumbnailImage = GridThumbnailFallback.placeholderImage
        view.alphaValue = 1
        checkBadge.isHidden = true
        heartBadge.isHidden = true
        durationBadge.isHidden = true
        durationLabel.stringValue = ""
    }

    private static func durationString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    var thumbnailImage: CGImage? {
        roundedView?.thumbnailImage
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutDurationBadge()
    }

    private func layoutDurationBadge() {
        guard !durationBadge.isHidden, let imageRect = roundedView?.displayedImageRect, imageRect.width > 1, imageRect.height > 1 else { return }
        let textWidth = ceil(durationLabel.intrinsicContentSize.width)
        let height: CGFloat = 26
        let width = max(48, textWidth + 24)
        durationBadge.frame = CGRect(
            x: imageRect.maxX - width,
            y: imageRect.maxY - height,
            width: width,
            height: height
        )
        durationBadge.layer?.cornerRadius = min(9, height * 0.5)
    }
}

/// A photo cell view that keeps a corner radius proportional to its size, so every thumbnail reads as
/// its own rounded cell (Apple-style) instead of merging into a gapless "Wurst".
final class RoundedCellView: NSView {
    var thumbnailImage: CGImage? {
        didSet { needsDisplay = true }
    }
    var cropMode: GridCropMode = .aspectFit {
        didSet {
            guard oldValue != cropMode else { return }
            needsDisplay = true
        }
    }
    var showsPlaceholder = true {
        didSet {
            guard oldValue != showsPlaceholder else { return }
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    var displayedImageRect: CGRect? {
        guard let image = thumbnailImage else { return nil }
        if showsPlaceholder { return bounds }
        return displayedImageRect(imageSize: CGSize(width: image.width, height: image.height))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        thumbnailImage = GridThumbnailFallback.placeholderImage
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image = thumbnailImage,
              bounds.width > 0,
              bounds.height > 0,
              let context = NSGraphicsContext.current?.cgContext else { return }

        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let target = showsPlaceholder ? bounds : displayedImageRect(imageSize: imageSize)
        let radius = min(GridVisualConstants.thumbnailCornerRadius, target.width * 0.5, target.height * 0.5)

        context.saveGState()
        context.addPath(CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.interpolationQuality = .high

        // The view is flipped for AppKit layout; flip only the Quartz image draw so the bitmap is upright.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let flippedTarget = CGRect(x: target.minX, y: bounds.height - target.maxY, width: target.width, height: target.height)
        context.draw(image, in: flippedTarget)
        context.restoreGState()
    }

    private func displayedImageRect(imageSize: CGSize) -> CGRect {
        let scale: CGFloat
        switch cropMode {
        case .aspectFit:
            scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        case .squareFill:
            scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        }
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width * 0.5,
            y: bounds.midY - size.height * 0.5,
            width: size.width,
            height: size.height
        ).intersection(bounds)
    }
}

/// Sticky date section header with a Liquid-Glass-style blurred background.
final class DateHeaderView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("DateHeaderView")

    private let label = NSTextField(labelWithString: "")
    var title: String = "" { didSet { label.stringValue = title } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
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
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
