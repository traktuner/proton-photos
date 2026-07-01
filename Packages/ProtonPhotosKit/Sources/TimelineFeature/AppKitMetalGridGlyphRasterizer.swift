import AppKit
import CoreGraphics

@MainActor
final class AppKitMetalGridGlyphRasterizer: MetalGridGlyphRasterizing {
    func image(for request: MetalGridGlyphRequest) -> CGImage? {
        guard request.pixelSize > 0 else { return nil }
        let pixelSize = request.pixelSize
        let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(pixelSize) * 0.72, weight: request.weight.nsFontWeight)
        guard let base = NSImage(systemSymbolName: request.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        else { return nil }

        let canvas = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
        canvas.lockFocus()
        let size = base.size
        let rect = NSRect(
            x: (CGFloat(pixelSize) - size.width) / 2,
            y: (CGFloat(pixelSize) - size.height) / 2,
            width: size.width,
            height: size.height
        )
        base.draw(in: rect)
        request.color.nsColor.set()
        NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill(using: .sourceAtop)
        canvas.unlockFocus()
        return canvas.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

extension MetalGridGlyphColor {
    init(_ color: NSColor) {
        let rgba = color.usingColorSpace(.sRGB) ?? color
        self.init(
            red: rgba.redComponent,
            green: rgba.greenComponent,
            blue: rgba.blueComponent,
            alpha: rgba.alphaComponent
        )
    }

    fileprivate var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

private extension MetalGridGlyphWeight {
    var nsFontWeight: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}
