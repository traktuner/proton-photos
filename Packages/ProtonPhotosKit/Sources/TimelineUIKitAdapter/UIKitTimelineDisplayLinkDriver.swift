#if canImport(UIKit)
import QuartzCore
import UIKit

public final class UIKitTimelineDisplayLinkDriver {
    private final class CallbackTarget: NSObject {
        weak var owner: UIKitTimelineDisplayLinkDriver?

        init(owner: UIKitTimelineDisplayLinkDriver) {
            self.owner = owner
        }

        @MainActor
        @objc func tick(_ displayLink: CADisplayLink) {
            owner?.tick(displayLink)
        }
    }

    private lazy var callbackTarget = CallbackTarget(owner: self)
    private var displayLink: CADisplayLink?
    private var onFrame: ((CFTimeInterval) -> Void)?

    public private(set) var isRunning = false

    public init() {}

    deinit {
        displayLink?.invalidate()
    }

    @MainActor
    public func start(
        preferredFramesPerSecond: Int = 0,
        onFrame: @escaping (CFTimeInterval) -> Void
    ) {
        stop()
        self.onFrame = onFrame

        let link = CADisplayLink(target: callbackTarget, selector: #selector(CallbackTarget.tick(_:)))
        if preferredFramesPerSecond > 0 {
            link.preferredFramesPerSecond = preferredFramesPerSecond
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
        isRunning = true
    }

    @MainActor
    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
        onFrame = nil
        isRunning = false
    }

    @MainActor
    private func tick(_ displayLink: CADisplayLink) {
        onFrame?(displayLink.timestamp)
    }
}
#endif
