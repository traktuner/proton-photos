import CoreGraphics

/// Layout-invariant scroll position: the item at the top of the viewport plus how far its top sat below the
/// viewport top. Restoring re-resolves that item at the current zoom, width, and column phase, so route memory
/// survives layout changes without relying on a stale raw scroll offset.
public struct GridScrollAnchor<ItemID: Hashable & Sendable>: Equatable, Sendable {
    public let itemID: ItemID
    public let topOffset: CGFloat

    public init(itemID: ItemID, topOffset: CGFloat) {
        self.itemID = itemID
        self.topOffset = topOffset
    }
}
