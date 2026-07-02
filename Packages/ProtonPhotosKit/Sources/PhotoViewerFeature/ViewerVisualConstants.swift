import SwiftUI
import AppKit

/// Shared visual constants for the full-screen photo/video viewer.
///
/// The viewer uses a single warm, Apple-Photos-like dark background everywhere - the viewer root, the
/// empty areas around an aspect-fit photo/video, the opaque top-bar background and any loading/placeholder
/// surface. Pure black is reserved for actual video letterboxing (the `AVPlayerView` draws its own black).
public enum ViewerVisualConstants {
    /// Warm dark background, RGB ≈ (40, 36, 32) / hex ≈ #282420. Matches Apple Photos' viewer chrome.
    public static let backgroundNSColor = NSColor(
        srgbRed: 40.0 / 255.0,
        green: 36.0 / 255.0,
        blue: 32.0 / 255.0,
        alpha: 1.0
    )

    /// SwiftUI surface color - use for the viewer root, areas around the media, and placeholder surfaces.
    public static let backgroundColor = Color(backgroundNSColor)
}
