import CoreGraphics

/// Visual constants shared by the real grid cells (`PhotoGridItem`) and the Metal zoom overlay
/// (`GridSpriteTransitionView`), so corners/cropping match at rest, during the pinch, in the target
/// fill, and in the settle preview — one source of truth, no drift between the two render paths.
enum GridVisualConstants {
    /// Subtle, CONSISTENT thumbnail corner radius (points). Applied to real cells AND overlay sprites
    /// so a thumbnail looks the same whether or not a zoom overlay is active. Kept small (3) so the dense
    /// nearly-gapless levels don't read as dark cracks between thumbnails.
    static let thumbnailCornerRadius: CGFloat = 3
}

/// How a zoom level fits a photo into its (square) cell.
///  • `aspectFit`  — letterbox the whole photo inside the cell (large/medium levels keep the photo).
///  • `squareFill` — center-crop the photo to fill a square cell, packed nearly gapless (the dense
///                   compact overview, like Apple Photos' most-zoomed-out grid).
enum GridCropMode: Equatable {
    case aspectFit
    case squareFill
}
