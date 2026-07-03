import CoreGraphics

/// Pure geometry for restoring the main window across launches. Kept out of AppKit so it can be unit-tested with
/// synthetic screen rects.
public enum WindowFramePolicy {
    /// A restored window must have at least this much of itself on some screen, otherwise the user
    /// can't grab the title bar to move it. If less is visible we re-centre on the primary screen.
    public static let minVisibleExtent: CGFloat = 120

    /// True when `frame` overlaps any screen by at least `minVisibleExtent` in both axes.
    public static func isSufficientlyVisible(_ frame: CGRect, on screens: [CGRect]) -> Bool {
        for screen in screens {
            let overlap = screen.intersection(frame)
            if overlap.width >= minVisibleExtent && overlap.height >= minVisibleExtent { return true }
        }
        return false
    }

    /// A frame of `size` centred within `area` (clamped so it never exceeds the screen).
    public static func centered(size: CGSize, in area: CGRect) -> CGRect {
        let w = min(size.width, area.width)
        let h = min(size.height, area.height)
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    /// Validates a persisted `frame` against the current `screens` (visible frames). Returns it
    /// unchanged when it's still reachable; otherwise returns a safely centred frame on the primary
    /// screen keeping the saved size. Falls back to `fallbackSize` at the origin when there are no
    /// screens (headless/test) or the saved frame was empty.
    public static func validate(_ frame: CGRect, screens: [CGRect], fallbackSize: CGSize) -> CGRect {
        guard let primary = screens.first else {
            return CGRect(origin: .zero, size: frame.isEmpty ? fallbackSize : frame.size)
        }
        if !frame.isEmpty, isSufficientlyVisible(frame, on: screens) { return frame }
        let size = frame.isEmpty ? fallbackSize : frame.size
        return centered(size: size, in: primary)
    }
}
