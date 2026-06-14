import AppKit
import PhotosCore
import MediaCache

/// A grid cell: layer-backed aspect-fill thumbnail, loaded from the shared feed (cache-first).
final class PhotoGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoGridItem")

    private var loadTask: Task<Void, Never>?
    private var currentUID: PhotoUID?

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
        container.layer?.masksToBounds = true
        container.layer?.contentsGravity = .resizeAspectFill
        self.view = container
    }

    func configure(photo: PhotoItem, feed: ThumbnailFeed) {
        currentUID = photo.uid
        view.layer?.contents = nil
        loadTask?.cancel()
        let uid = photo.uid
        loadTask = Task { [weak self] in
            while !Task.isCancelled {
                if let image = await feed.cachedImage(for: uid) {
                    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    await MainActor.run {
                        guard let self, self.currentUID == uid else { return }
                        self.view.layer?.contents = cg
                    }
                    return
                }
                await feed.requestPriority(uid)
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        currentUID = nil
        view.layer?.contents = nil
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
