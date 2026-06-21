import CoreGraphics

/// Visual constants shared by the real grid cells (`PhotoGridItem`) and the Metal zoom overlay
/// (`GridSpriteTransitionView`), so corners/cropping match at rest, during the pinch, in the target
/// fill, and in the settle preview — one source of truth, no drift between the two render paths.
enum GridVisualConstants {
    /// Shared thumbnail corner radius in points. The reference capture's rounded image corner measures
    /// about 20-22 px, which is 10-11 pt on a Retina screenshot, so the live grid and Metal overlay use 11.
    static let thumbnailCornerRadius: CGFloat = 11
}

/// How a zoom level fits a photo into its (square) cell.
///  • `aspectFit`  — letterbox the whole photo inside the cell (large/medium levels keep the photo).
///  • `squareFill` — center-crop the photo to fill a square cell, packed nearly gapless (the dense
///                   compact overview, like Apple Photos' most-zoomed-out grid).
public enum GridCropMode: Equatable, Sendable {
    case aspectFit
    case squareFill
}
