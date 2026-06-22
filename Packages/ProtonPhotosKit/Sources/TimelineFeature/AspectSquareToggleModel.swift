import AppKit

// MARK: - AspectSquareToggleModel — presentation model for the aspect/square toolbar toggle
//
// The toolbar button is a thin SwiftUI shell over this model so the symbol-resolution, vector-fallback and
// accessibility logic is UNIT-TESTABLE without building the toolbar. STRICT asset policy (guarded by tests):
//   • every glyph is an SF Symbol (system) probed via `NSImage(systemSymbolName:)`, OR an in-app CoreGraphics
//     vector fallback — NEVER a bundled raster, asset-catalog image, or a copy of Apple's Photos icon.
//   • the button shows the symbol for the CURRENT content mode; tapping switches to the other mode.
@MainActor
public enum AspectSquareToggleModel {
    /// Candidate SF Symbols per mode, best first (probed at runtime; first existing wins). All are SYSTEM
    /// symbols — `aspectratio` reads as "show full aspect ratio", a filled square as "crop to square".
    public static let symbolCandidates: [TileContentDisplayMode: [String]] = [
        .squareFillCrop:        ["aspectratio", "rectangle.expand.vertical", "arrow.up.left.and.arrow.down.right"],
        .aspectFitInsideSquare: ["square.fill", "square", "arrow.down.right.and.arrow.up.left"],
    ]

    /// The first candidate SF Symbol that actually exists on this OS, or nil if none (→ use `fallbackImage`).
    public static func resolvedSymbolName(for mode: TileContentDisplayMode) -> String? {
        for name in symbolCandidates[mode] ?? [] where NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return name
        }
        return nil
    }

    /// True when a native SF Symbol resolves for BOTH modes (so the vector fallback is never needed).
    public static var hasNativeSymbols: Bool {
        resolvedSymbolName(for: .squareFillCrop) != nil && resolvedSymbolName(for: .aspectFitInsideSquare) != nil
    }

    /// A simple in-app vector glyph (CoreGraphics) used ONLY when no SF Symbol resolves: a square outline with
    /// a wide inner rectangle (aspect-fit) or an inner square (square-fill). Template image → tints natively.
    public static func fallbackImage(for mode: TileContentDisplayMode, side: CGFloat = 16) -> NSImage {
        let img = NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
            NSColor.labelColor.setStroke()
            let outer = NSBezierPath(rect: rect.insetBy(dx: 1.5, dy: 1.5)); outer.lineWidth = 1.5; outer.stroke()
            let inner = mode == .aspectFitInsideSquare
                ? rect.insetBy(dx: 3, dy: rect.height * 0.3)   // letterboxed wide rect inside the square
                : rect.insetBy(dx: 4.5, dy: 4.5)               // inner square (the crop)
            let p = NSBezierPath(rect: inner); p.lineWidth = 1.2; p.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    /// The image for the CURRENT mode: the resolved SF Symbol if available, else the CoreGraphics fallback.
    public static func image(for mode: TileContentDisplayMode) -> NSImage {
        if let name = resolvedSymbolName(for: mode),
           let img = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityLabel(for: mode)) {
            img.isTemplate = true
            return img
        }
        return fallbackImage(for: mode)
    }

    /// Accessibility label + tooltip describing the ACTION the button performs from the current mode.
    public static func accessibilityLabel(for currentMode: TileContentDisplayMode) -> String {
        currentMode == .squareFillCrop ? "Show full aspect ratio thumbnails" : "Crop thumbnails to squares"
    }

    /// The mode the toggle switches to from the current one.
    public static func toggled(_ mode: TileContentDisplayMode) -> TileContentDisplayMode {
        mode == .squareFillCrop ? .aspectFitInsideSquare : .squareFillCrop
    }
}
