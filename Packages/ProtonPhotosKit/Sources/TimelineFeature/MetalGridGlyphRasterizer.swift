import CoreGraphics

struct MetalGridGlyphRequest: Equatable, Hashable, Sendable {
    let symbol: String
    let pixelSize: Int
    let weight: MetalGridGlyphWeight
    let color: MetalGridGlyphColor

    init(symbol: String, pixelSize: Int = 44, weight: MetalGridGlyphWeight = .bold, color: MetalGridGlyphColor) {
        self.symbol = symbol
        self.pixelSize = pixelSize
        self.weight = weight
        self.color = color
    }
}

enum MetalGridGlyphWeight: String, Sendable {
    case regular
    case medium
    case semibold
    case bold
}

struct MetalGridGlyphColor: Equatable, Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    static let white = MetalGridGlyphColor(red: 1, green: 1, blue: 1, alpha: 1)
}

@MainActor
protocol MetalGridGlyphRasterizing: AnyObject {
    func image(for request: MetalGridGlyphRequest) -> CGImage?
}
