import CoreGraphics

package struct MetalGridGlyphRequest: Equatable, Hashable, Sendable {
    package let symbol: String
    package let pixelSize: Int
    package let weight: MetalGridGlyphWeight
    package let color: MetalGridGlyphColor

    package init(symbol: String, pixelSize: Int = 44, weight: MetalGridGlyphWeight = .bold, color: MetalGridGlyphColor) {
        self.symbol = symbol
        self.pixelSize = pixelSize
        self.weight = weight
        self.color = color
    }
}

package enum MetalGridGlyphWeight: String, Sendable {
    case regular
    case medium
    case semibold
    case bold
}

package struct MetalGridGlyphColor: Equatable, Hashable, Sendable {
    package let red: Double
    package let green: Double
    package let blue: Double
    package let alpha: Double

    package init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    package static let white = MetalGridGlyphColor(red: 1, green: 1, blue: 1, alpha: 1)
}

@MainActor
package protocol MetalGridGlyphRasterizing: AnyObject {
    func image(for request: MetalGridGlyphRequest) -> CGImage?
}
