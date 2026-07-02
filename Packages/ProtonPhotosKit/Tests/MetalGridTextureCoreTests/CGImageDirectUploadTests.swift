import Testing
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers
@testable import MetalGridTextureCore

/// Tests for the pure, GPU-free direct-upload decision that lets the Metal texture cache skip the
/// main-thread CGContext normalization redraw when a decoded thumbnail is already verbatim-compatible.
@Suite struct CGImageDirectUploadTests {

    // Convenience wrapper over the primitive decision with sensible "supported" defaults so each test
    // varies only the property under scrutiny.
    private func decide(
        bitsPerComponent: Int = 8,
        bitsPerPixel: Int = 32,
        alphaInfo: CGImageAlphaInfo = .noneSkipFirst,
        byteOrder: CGImageByteOrderInfo = .orderDefault,
        isFloat: Bool = false,
        colorSpaceModel: CGColorSpaceModel = .rgb,
        passesThroughDeviceRGB: Bool = true,
        source: (Int, Int) = (320, 240),
        target: (Int, Int) = (320, 240)
    ) -> CGImageDirectUpload.Swizzle? {
        CGImageDirectUpload.swizzle(
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            alphaInfo: alphaInfo,
            byteOrder: byteOrder,
            isFloat: isFloat,
            colorSpaceModel: colorSpaceModel,
            colorSpacePassesThroughDeviceRGB: passesThroughDeviceRGB,
            sourceWidth: source.0, sourceHeight: source.1,
            targetWidth: target.0, targetHeight: target.1
        )
    }

    // MARK: - Supported layouts → exact swizzle

    @Test func rgbaPremultipliedDefault_isIdentity() {
        #expect(decide(alphaInfo: .premultipliedLast, byteOrder: .orderDefault) == .identity)
        #expect(decide(alphaInfo: .premultipliedLast, byteOrder: .order32Big) == .identity)
    }

    @Test func rgbxOpaqueDefault_forcesAlphaOne() {
        // memory R,G,B,X → (red, green, blue, 1)
        #expect(decide(alphaInfo: .noneSkipLast, byteOrder: .orderDefault)
                == CGImageDirectUpload.Swizzle(red: .red, green: .green, blue: .blue, alpha: .one))
    }

    @Test func xrgbNoneSkipFirstDefault_theRealImageIOJPEGCase() {
        // memory X,R,G,B → sampled R=byte1(.green), G=byte2(.blue), B=byte3(.alpha), A=1
        #expect(decide(alphaInfo: .noneSkipFirst, byteOrder: .orderDefault)
                == CGImageDirectUpload.Swizzle(red: .green, green: .blue, blue: .alpha, alpha: .one))
    }

    @Test func argbPremultipliedFirstDefault_pullsRealAlpha() {
        // memory A,R,G,B → R=byte1(.green), G=byte2(.blue), B=byte3(.alpha), A=byte0(.red)
        #expect(decide(alphaInfo: .premultipliedFirst, byteOrder: .orderDefault)
                == CGImageDirectUpload.Swizzle(red: .green, green: .blue, blue: .alpha, alpha: .red))
    }

    @Test func bgraPremultipliedFirstLittle_classicBGRA() {
        // memory B,G,R,A → R=byte2(.blue), G=byte1(.green), B=byte0(.red), A=byte3(.alpha)
        #expect(decide(alphaInfo: .premultipliedFirst, byteOrder: .order32Little)
                == CGImageDirectUpload.Swizzle(red: .blue, green: .green, blue: .red, alpha: .alpha))
    }

    @Test func bgrxNoneSkipFirstLittle_opaqueBGRX() {
        // memory B,G,R,X → R=.blue, G=.green, B=.red, A=1
        #expect(decide(alphaInfo: .noneSkipFirst, byteOrder: .order32Little)
                == CGImageDirectUpload.Swizzle(red: .blue, green: .green, blue: .red, alpha: .one))
    }

    @Test func rgbaPremultipliedLittle_reversedWord() {
        // logical R,G,B,A reversed → memory A,B,G,R → R=byte3(.alpha), G=byte2(.blue), B=byte1(.green), A=byte0(.red)
        #expect(decide(alphaInfo: .premultipliedLast, byteOrder: .order32Little)
                == CGImageDirectUpload.Swizzle(red: .alpha, green: .blue, blue: .green, alpha: .red))
    }

    // MARK: - Rejections → nil (fall back to redraw)

    @Test func rejectsResampleNeeded() {
        #expect(decide(source: (640, 480), target: (320, 240)) == nil)
        #expect(decide(source: (320, 240), target: (320, 241)) == nil)
    }

    @Test func rejectsNon8Bit() {
        #expect(decide(bitsPerComponent: 16, bitsPerPixel: 64) == nil)
    }

    @Test func rejectsNon32bpp() {
        #expect(decide(bitsPerPixel: 24, alphaInfo: .none) == nil)
    }

    @Test func rejectsFloatComponents() {
        #expect(decide(isFloat: true) == nil)
    }

    @Test func rejectsNonRGBModels() {
        #expect(decide(colorSpaceModel: .monochrome) == nil)
        #expect(decide(colorSpaceModel: .cmyk) == nil)
        #expect(decide(colorSpaceModel: .indexed) == nil)
        #expect(decide(colorSpaceModel: .lab) == nil)
    }

    @Test func rejectsWideGamutColorspace() {
        // A Display-P3 thumbnail is gamut-converted by the redraw and must keep being converted.
        #expect(decide(passesThroughDeviceRGB: false) == nil)
    }

    @Test func rejectsStraightAndAbsentAlpha() {
        #expect(decide(alphaInfo: .last) == nil)          // straight (non-premultiplied) alpha
        #expect(decide(alphaInfo: .first) == nil)
        #expect(decide(alphaInfo: .none) == nil)
        #expect(decide(alphaInfo: .alphaOnly) == nil)
    }

    @Test func rejects16BitByteOrders() {
        #expect(decide(byteOrder: .order16Little) == nil)
        #expect(decide(byteOrder: .order16Big) == nil)
    }

    // MARK: - CGImage overload integration + colorspace gate

    @Test func sRGBOpaqueImageTakesFastPath() throws {
        let image = try Self.solidImage(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmap: CGImageAlphaInfo.noneSkipLast.rawValue)
        #expect(CGImageDirectUpload.swizzle(for: image, targetWidth: image.width, targetHeight: image.height) != nil)
    }

    @Test func p3ImageFallsBack() throws {
        let image = try Self.solidImage(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                                        bitmap: CGImageAlphaInfo.noneSkipLast.rawValue)
        #expect(CGImageDirectUpload.swizzle(for: image, targetWidth: image.width, targetHeight: image.height) == nil)
    }

    @Test func grayscaleImageFallsBack() throws {
        let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0.5, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = try #require(ctx.makeImage())
        #expect(CGImageDirectUpload.swizzle(for: image, targetWidth: 16, targetHeight: 16) == nil)
    }

    @Test func downsampleRequestFallsBack() throws {
        let image = try Self.solidImage(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmap: CGImageAlphaInfo.noneSkipLast.rawValue)
        #expect(CGImageDirectUpload.swizzle(for: image, targetWidth: image.width / 2, targetHeight: image.height / 2) == nil)
    }

    // MARK: - End-to-end correctness (GPU-free): swizzle reproduces the redraw output pixel-for-pixel

    /// The strongest guarantee: for the real ImageIO JPEG thumbnail (memory X,R,G,B), sampling the uploaded
    /// bytes through the returned swizzle yields exactly the pixels the CGContext(DeviceRGB) redraw produces.
    @Test func swizzleReproducesRedrawOutputForDecodedJPEG() throws {
        let jpeg = Self.makeJPEG(width: 640, height: 480,
                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 r: 0.85, g: 0.15, b: 0.35)
        let src = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let thumb = try #require(CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 320,
        ] as CFDictionary))

        let swizzle = try #require(CGImageDirectUpload.swizzle(for: thumb, targetWidth: thumb.width, targetHeight: thumb.height))

        // Path A: the current redraw into DeviceRGB premultipliedLast (the ground truth).
        let expected = Self.redrawFirstPixelRGBA(thumb)
        // Path B: the direct upload. Bytes are copied verbatim into rgba8Unorm, so stored channel k == memory byte k.
        let storedBytes = Self.firstPixelBytes(thumb)
        let sampled = [
            Self.sample(swizzle.red, stored: storedBytes),
            Self.sample(swizzle.green, stored: storedBytes),
            Self.sample(swizzle.blue, stored: storedBytes),
            Self.sample(swizzle.alpha, stored: storedBytes),
        ]
        #expect(sampled == expected)
    }

    // MARK: - Helpers

    private static func sample(_ channel: CGImageDirectUpload.Channel, stored: [UInt8]) -> UInt8 {
        switch channel {
        case .red: return stored[0]
        case .green: return stored[1]
        case .blue: return stored[2]
        case .alpha: return stored[3]
        case .one: return 255
        }
    }

    private static func firstPixelBytes(_ image: CGImage) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        return Array(data.prefix(4))
    }

    private static func redrawFirstPixelRGBA(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Array(pixels.prefix(4))
    }

    private static func solidImage(colorSpace: CGColorSpace, bitmap: UInt32) throws -> CGImage {
        let ctx = try #require(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: colorSpace, bitmapInfo: bitmap))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        return try #require(ctx.makeImage())
    }

    private static func makeJPEG(width: Int, height: Int, colorSpace: CGColorSpace, r: CGFloat, g: CGFloat, b: CGFloat) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
