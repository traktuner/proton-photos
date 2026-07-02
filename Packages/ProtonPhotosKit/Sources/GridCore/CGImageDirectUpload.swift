import CoreGraphics

/// Pure, GPU-free decision for whether a decoded `CGImage` can be uploaded into an `rgba8Unorm` Metal
/// texture **directly from its pixel bytes** - skipping the per-upload `CGContext` RGBA8 normalization
/// redraw that the texture cache otherwise runs on the main thread inside `draw()`.
///
/// The redraw (`CGContext(...premultipliedLast, DeviceRGB)` + `ctx.draw` + `replaceRegion`) is a pure
/// format-normalization copy whenever the decoded thumbnail is already an 8-bit / 32-bit-per-pixel RGB(A)
/// image at the exact target size (the production feed decodes pre-sized ~320 px thumbnails, so no
/// resampling is needed). ImageIO, however, does not hand back a fixed byte order: a JPEG thumbnail decodes
/// to `noneSkipFirst` + default byte order (memory bytes `X,R,G,B`), not RGBA. Rather than change the
/// texture's pixel format, every supported layout is uploaded verbatim into one `rgba8Unorm` texture and its
/// channels are corrected by a GPU-side sampler swizzle (`MTLTextureSwizzleChannels`) - zero CPU cost.
///
/// This type is the platform-universal decision only (GridCore is CoreGraphics-only, no Metal): it returns a
/// neutral `Swizzle` description the Metal layer maps to `MTLTextureSwizzleChannels`. Anything that would
/// change pixel *values* if uploaded verbatim is refused (returns `nil`) so the caller keeps the
/// always-correct redraw:
/// - a colorspace that the redraw would gamut-convert (only sRGB / DeviceRGB pass through DeviceRGB
///   unchanged; a Display-P3 thumbnail is converted by the redraw and must keep being converted),
/// - straight (non-premultiplied) alpha (the redraw premultiplies it; the grid shader expects premultiplied),
/// - non-RGB models (CMYK, grayscale, indexed, Lab), 16-bit / float components, or a size mismatch that
///   still needs resampling.
package enum CGImageDirectUpload {

    /// The source channel one output channel of the sampled texel is read from. `one` forces a constant 1
    /// (used to make an opaque *skip*-alpha source read as fully opaque, exactly as the redraw does).
    package enum Channel: Equatable, Sendable {
        case red, green, blue, alpha, one
    }

    /// Sampler channel remap so an `rgba8Unorm` texture loaded with arbitrary-ordered bytes still samples as
    /// straight `(R, G, B, A-or-1)`. `identity` means the stored bytes are already `R,G,B,A` (no remap).
    package struct Swizzle: Equatable, Sendable {
        package let red: Channel
        package let green: Channel
        package let blue: Channel
        package let alpha: Channel

        package init(red: Channel, green: Channel, blue: Channel, alpha: Channel) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        package static let identity = Swizzle(red: .red, green: .green, blue: .blue, alpha: .alpha)
        package var isIdentity: Bool { self == .identity }
    }

    /// The direct-upload swizzle for an image with these bitmap properties uploaded at `target` size, or `nil`
    /// when the normalization redraw is required. Pure over primitives so the whole decision matrix is
    /// unit-testable with no images and no GPU.
    ///
    /// - Parameters:
    ///   - colorSpaceModel: `image.colorSpace?.model` (`.rgb` required).
    ///   - colorSpacePassesThroughDeviceRGB: true only when the colorspace is sRGB or DeviceRGB - i.e. the
    ///     redraw's `DeviceRGB` context would not change the pixel values. The `CGImage` overload computes this.
    package static func swizzle(
        bitsPerComponent: Int,
        bitsPerPixel: Int,
        alphaInfo: CGImageAlphaInfo,
        byteOrder: CGImageByteOrderInfo,
        isFloat: Bool,
        colorSpaceModel: CGColorSpaceModel,
        colorSpacePassesThroughDeviceRGB: Bool,
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> Swizzle? {
        // Direct upload cannot resample: target must equal source exactly (a downsample goes through redraw).
        guard sourceWidth == targetWidth, sourceHeight == targetHeight else { return nil }
        // Only 8-bit, 32bpp, non-float RGB maps onto rgba8Unorm.
        guard bitsPerComponent == 8, bitsPerPixel == 32, !isFloat else { return nil }
        guard colorSpaceModel == .rgb, colorSpacePassesThroughDeviceRGB else { return nil }
        // Only byte orders we can reason about at 32bpp (16-bit orders are malformed here).
        switch byteOrder {
        case .orderDefault, .order32Big, .order32Little: break
        default: return nil
        }

        // Classify the alpha: only premultiplied or opaque (skip) are safe. Straight `.first`/`.last` alpha
        // would blend wrong (the redraw premultiplies them); `.none`/`.alphaOnly` are not 32bpp RGB(A).
        let opaque: Bool          // true ⇒ the 4th logical component is a skip byte ⇒ force sampled alpha to 1
        let alphaFirst: Bool      // true ⇒ logical order is A,R,G,B ; false ⇒ R,G,B,A
        switch alphaInfo {
        case .premultipliedLast:  opaque = false; alphaFirst = false
        case .premultipliedFirst: opaque = false; alphaFirst = true
        case .noneSkipLast:       opaque = true;  alphaFirst = false
        case .noneSkipFirst:      opaque = true;  alphaFirst = true
        default:                  return nil      // .none, .last, .first (straight), .alphaOnly ⇒ redraw
        }

        // In-memory byte positions (index 0 = lowest address = the texture's `.red` channel, 1 = `.green`,
        // 2 = `.blue`, 3 = `.alpha`). The logical component order is serialized big-endian for
        // default/32Big (as written) and reversed for 32Little.
        let logical: [Symbol] = alphaFirst ? [.a, .r, .g, .b] : [.r, .g, .b, .a]
        let memory: [Symbol] = (byteOrder == .order32Little) ? logical.reversed() : logical

        func storedChannel(of symbol: Symbol) -> Channel {
            switch memory.firstIndex(of: symbol)! {
            case 0: return .red
            case 1: return .green
            case 2: return .blue
            default: return .alpha
            }
        }

        return Swizzle(
            red: storedChannel(of: .r),
            green: storedChannel(of: .g),
            blue: storedChannel(of: .b),
            alpha: opaque ? .one : storedChannel(of: .a)
        )
    }

    private enum Symbol { case r, g, b, a }
}

#if canImport(CoreGraphics)
extension CGImageDirectUpload {
    /// Convenience over a live `CGImage`. Extracts the bitmap properties and the sRGB/DeviceRGB colorspace
    /// gate, then defers to the pure primitive decision. Returns `nil` (⇒ redraw) for anything unsupported or
    /// for a `nil` colorspace.
    package static func swizzle(for image: CGImage, targetWidth: Int, targetHeight: Int) -> Swizzle? {
        guard let colorSpace = image.colorSpace else { return nil }
        let byteOrder = image.byteOrderInfo
        let isFloat = image.bitmapInfo.contains(.floatComponents)
        return swizzle(
            bitsPerComponent: image.bitsPerComponent,
            bitsPerPixel: image.bitsPerPixel,
            alphaInfo: image.alphaInfo,
            byteOrder: byteOrder,
            isFloat: isFloat,
            colorSpaceModel: colorSpace.model,
            colorSpacePassesThroughDeviceRGB: colorSpacePassesThroughDeviceRGB(colorSpace),
            sourceWidth: image.width,
            sourceHeight: image.height,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
    }

    /// True when uploading `colorSpace` bytes verbatim yields the same pixels the redraw's `DeviceRGB` context
    /// would produce - i.e. no gamut conversion. Only sRGB and DeviceRGB qualify; wide-gamut (Display P3) is
    /// converted by the redraw and must keep being converted, so it is refused here.
    private static func colorSpacePassesThroughDeviceRGB(_ colorSpace: CGColorSpace) -> Bool {
        if CFEqual(colorSpace, deviceRGB) { return true }
        if let sRGB = sRGB, CFEqual(colorSpace, sRGB) { return true }
        return false
    }

    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
}
#endif
