import CoreGraphics

/// Visual constants for the Metal grid cells — one source of truth for corner radius so the rounded
/// corners match at rest and through a zoom.
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
