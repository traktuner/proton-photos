#if canImport(UIKit)
import CoreGraphics
import GridCore
import TimelineCore
import UIKit

@MainActor
public struct UIKitTimelineGridProfileAdapter {
    private let resolver: TimelineGridProfileResolver

    public init() {
        self.resolver = TimelineGridProfileConfiguration.production.resolver
    }

    package init(resolver: TimelineGridProfileResolver) {
        self.resolver = resolver
    }

    public func profile(for view: UIView, additionalInsets: UIEdgeInsets = .zero) -> GridLevelProfile {
        profile(
            forBounds: view.bounds,
            safeAreaInsets: view.safeAreaInsets,
            additionalInsets: additionalInsets
        )
    }

    public func profile(
        forBounds bounds: CGRect,
        safeAreaInsets: UIEdgeInsets = .zero,
        additionalInsets: UIEdgeInsets = .zero
    ) -> GridLevelProfile {
        let size = Self.layoutSize(
            forBounds: bounds,
            safeAreaInsets: safeAreaInsets,
            additionalInsets: additionalInsets
        )
        // UIKit surfaces are finger-driven → the touch profile ladders (tighter gaps, same level semantics).
        let viewport = TimelineGridViewport(layoutWidth: size.width, layoutHeight: size.height, inputAffinity: .touch)
        return resolver.profile(for: viewport)
    }

    public static func layoutSize(
        forBounds bounds: CGRect,
        safeAreaInsets: UIEdgeInsets = .zero,
        additionalInsets: UIEdgeInsets = .zero
    ) -> CGSize {
        CGSize(
            width: usableAxis(
                extent: bounds.width,
                leadingInset: safeAreaInsets.left + additionalInsets.left,
                trailingInset: safeAreaInsets.right + additionalInsets.right
            ),
            height: usableAxis(
                extent: bounds.height,
                leadingInset: safeAreaInsets.top + additionalInsets.top,
                trailingInset: safeAreaInsets.bottom + additionalInsets.bottom
            )
        )
    }

    private static func usableAxis(extent: CGFloat, leadingInset: CGFloat, trailingInset: CGFloat) -> CGFloat {
        guard extent.isFinite else { return 0 }
        let leading = leadingInset.isFinite ? max(0, leadingInset) : 0
        let trailing = trailingInset.isFinite ? max(0, trailingInset) : 0
        return max(0, extent - leading - trailing)
    }
}
#endif
