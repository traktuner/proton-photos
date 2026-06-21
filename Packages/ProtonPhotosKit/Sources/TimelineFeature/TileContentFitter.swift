import CoreGraphics
import simd

// MARK: - TileContentFitter — how a photo/video fills its (already-decided) square slot
//
// This is the ONLY place media aspect enters the picture, and it is explicitly OUTSIDE the grid engine.
// Photos/videos are PAYLOAD; grid slots are GEOMETRY. The fitter takes a slot rect (from
// `SquareTileGridEngine`) + the media's pixel size/aspect + a content mode, and returns the content rect
// (where the image draws) plus the UV crop window.
//
// CONTRACT (guarded by TileContentFitterTests):
//   • the output `contentRect` is ALWAYS contained inside `slotRect`;
//   • changing `mode` (or the media aspect) NEVER changes the slot, grid layout, hit testing, the visible
//     query, zoom, or content size — those live in the engine and never see aspect.
//
// The production renderer composes three independent inputs:
//   slotRect  ← SquareTileGridEngine
//   content   ← TileContentFitter   (this file)
//   texture   ← thumbnail cache

/// How the media fits inside its square slot.
public enum TileContentMode: Equatable, Sendable {
    /// Center-crop the media to COVER the whole square (the dense / Apple-style grid look). The content rect
    /// equals the slot; the crop happens in the UV window. No letterbox bars.
    case aspectFill
    /// Letterbox the whole media INSIDE the square (the full photo is shown, bars fill the rest of the slot).
    /// The content rect is the centered fitted rect; UV is the full texture.
    case aspectFit
}

/// The result: where to draw the image (`contentRect`, viewport/content coords matching the slot) and the
/// texture UV window to sample. Always contained in the slot it was fitted to.
public struct TileContentLayout: Equatable, Sendable {
    public let contentRect: CGRect
    public let uvMin: SIMD2<Float>
    public let uvMax: SIMD2<Float>

    public init(contentRect: CGRect, uvMin: SIMD2<Float>, uvMax: SIMD2<Float>) {
        self.contentRect = contentRect
        self.uvMin = uvMin
        self.uvMax = uvMax
    }
}

public enum TileContentFitter {
    /// Fit by explicit media pixel size.
    public static func fit(slotRect: CGRect, mediaPixelSize: CGSize, mode: TileContentMode) -> TileContentLayout {
        let aspect = mediaPixelSize.height > 0 ? mediaPixelSize.width / mediaPixelSize.height : 1
        return fit(slotRect: slotRect, mediaAspect: aspect, mode: mode)
    }

    /// Fit by media aspect ratio (width / height).
    public static func fit(slotRect: CGRect, mediaAspect: CGFloat, mode: TileContentMode) -> TileContentLayout {
        let mediaAR = max(mediaAspect, 0.0001)
        let slotAR = slotRect.height > 0 ? slotRect.width / slotRect.height : 1
        switch mode {
        case .aspectFill:
            // Cover: the content rect IS the slot; crop the longer media axis via the UV window so the
            // image fills the square edge-to-edge (no bars), clipped to the slot.
            var insetX: Float = 0, insetY: Float = 0
            if mediaAR > slotAR { insetX = Float((1 - slotAR / mediaAR) / 2) }
            else { insetY = Float((1 - mediaAR / slotAR) / 2) }
            return TileContentLayout(contentRect: slotRect,
                                     uvMin: SIMD2(insetX, insetY), uvMax: SIMD2(1 - insetX, 1 - insetY))
        case .aspectFit:
            // Letterbox: the largest centered rect with the media aspect that fits inside the slot.
            var w = slotRect.width, h = slotRect.height
            if mediaAR >= slotAR { h = w / mediaAR } else { w = h * mediaAR }
            let rect = CGRect(x: slotRect.midX - w / 2, y: slotRect.midY - h / 2, width: w, height: h)
            return TileContentLayout(contentRect: rect, uvMin: SIMD2(0, 0), uvMax: SIMD2(1, 1))
        }
    }
}
