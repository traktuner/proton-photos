import AppKit
import PhotosCore
import MediaCache

/// A grid cell: layer-backed aspect-fill thumbnail, loaded from the shared feed (cache-first).
final class PhotoGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoGridItem")

    private var loadTask: Task<Void, Never>?
    private var currentUID: PhotoUID?
    private let checkBadge = NSImageView()
    private let heartBadge = NSImageView()

    private var cropMode: GridCropMode = .aspectFit

    override func loadView() {
        let container = RoundedCellView()           // rounded corners so each photo is a distinct cell
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor   // letterbox shows the window bg, no gray box
        container.layer?.masksToBounds = true
        container.layer?.cornerCurve = .continuous
        container.layer?.contentsGravity = .resizeAspect   // FIT inside the uniform cell (overridden per crop mode)
        container.layer?.contents = GridThumbnailFallback.placeholderImage

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

        NSLayoutConstraint.activate([
            checkBadge.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5),
            checkBadge.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
            checkBadge.widthAnchor.constraint(equalToConstant: 22),
            checkBadge.heightAnchor.constraint(equalToConstant: 22),
            heartBadge.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
            heartBadge.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
        ])
        self.view = container
    }

    func setFavorite(_ isFavorite: Bool) { heartBadge.isHidden = !isFavorite }

    /// Shows/updates the selection badge. `mode` = selection mode active (badge visible at all);
    /// `isChecked` = this photo is selected.
    func setChecked(_ isChecked: Bool, mode: Bool) {
        checkBadge.isHidden = !mode
        guard mode else { view.layer?.opacity = 1; return }
        let name = isChecked ? "checkmark.circle.fill" : "circle"
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .bold)
        checkBadge.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        checkBadge.contentTintColor = isChecked ? .controlAccentColor : .white
        view.layer?.opacity = isChecked ? 0.82 : 1
    }

    /// Update only the crop mode (e.g. when the zoom level commits to a square-fill level) without
    /// reloading the cell — square-fill levels crop to fill, others letterbox.
    func setCropMode(_ mode: GridCropMode) {
        cropMode = mode
        view.layer?.contentsGravity = mode == .squareFill ? .resizeAspectFill : .resizeAspect
    }

    func configure(photo: PhotoItem, feed: ThumbnailFeed, cropMode: GridCropMode) {
        currentUID = photo.uid
        loadTask?.cancel()
        setCropMode(cropMode)
        let uid = photo.uid
        // Cache-first, SYNCHRONOUS: if the thumbnail is already decoded, show it immediately — no
        // clear-to-blank, no actor hop. This is what keeps the grid from flickering grey as cells
        // enter/leave during a live pinch re-justify.
        if let cached = feed.memoryImage(for: uid) {
            view.layer?.contents = cached.cgImage(forProposedRect: nil, context: nil, hints: nil)
            PhotoDiagnostics.shared.classifyThumbnail(ThumbnailVisualClassification(
                uid: uid,
                rect: view.bounds,
                state: .realImageDrawn,
                phase: "scroll",
                context: "normalCell.ramDecodedHit"
            ))
            return
        }
        view.layer?.contents = GridThumbnailFallback.placeholderImage
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
                        self.view.layer?.contents = cg
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
        view.layer?.contents = GridThumbnailFallback.placeholderImage
        view.layer?.opacity = 1
        checkBadge.isHidden = true
        heartBadge.isHidden = true
    }
}

/// A photo cell view that keeps a corner radius proportional to its size, so every thumbnail reads as
/// its own rounded cell (Apple-style) instead of merging into a gapless "Wurst".
final class RoundedCellView: NSView {
    override func layout() {
        super.layout()
        // One CONSISTENT radius (shared with the Metal overlay sprites), visible at rest and during zoom.
        layer?.cornerRadius = min(GridVisualConstants.thumbnailCornerRadius, bounds.height * 0.5)
        layer?.cornerCurve = .continuous
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
