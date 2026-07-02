import CoreGraphics

/// Per-level mapping between engine layout space and render space.
///
/// Platform adapters decide the insets from their current scene/sidebar/safe-area
/// state. Core grid/transition code can then stay generic: build a level's
/// `GridFramePlan` in `layoutWidth`, and translate its slots by `leadingInset`
/// exactly once at the render boundary.
public struct GridRenderBounds: Equatable, Sendable {
    public let fullWidth: CGFloat
    public let leadingInset: CGFloat
    public let trailingInset: CGFloat

    public init(fullWidth: CGFloat, leadingInset: CGFloat = 0, trailingInset: CGFloat = 0) {
        self.fullWidth = max(1, fullWidth)
        self.leadingInset = max(0, leadingInset)
        self.trailingInset = max(0, trailingInset)
    }

    public var layoutWidth: CGFloat {
        max(1, fullWidth - leadingInset - trailingInset)
    }

    public func viewport(height: CGFloat) -> CGSize {
        CGSize(width: layoutWidth, height: height)
    }

    public func translate(_ rect: CGRect) -> CGRect {
        leadingInset == 0 ? rect : rect.offsetBy(dx: leadingInset, dy: 0)
    }

    public func translate(_ slots: [GridRenderSlot]) -> [GridRenderSlot] {
        guard leadingInset != 0 else { return slots }
        return slots.map {
            GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.rect.offsetBy(dx: leadingInset, dy: 0))
        }
    }
}
