import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoViewerCore

final class ViewerFullImageDecoderTests: XCTestCase {
    func testDecodesGeneratedPNGAsCGImageWithoutPlatformImageWrapper() throws {
        let data = try pngData(width: 3, height: 2)

        let image = try XCTUnwrap(ViewerFullImageDecoder.decodeCGImage(data))

        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
    }

    func testInvalidDataReturnsNil() {
        XCTAssertNil(ViewerFullImageDecoder.decodeCGImage(Data("not image data".utf8)))
    }

    func testBoundedDecodeCapsLongestSideAndNeverUpscales() throws {
        let data = try pngData(width: 200, height: 100)   // 200×100 original

        // A cap below the original downsamples proportionally (longest side == cap).
        let bounded = try XCTUnwrap(ViewerFullImageDecoder.decodeCGImage(data, maxPixelSize: 50))
        XCTAssertEqual(max(bounded.width, bounded.height), 50)
        XCTAssertLessThanOrEqual(bounded.width, 50)
        XCTAssertLessThanOrEqual(bounded.height, 50)

        // A cap ABOVE the original never upscales - full resolution is preserved, not enlarged.
        let notUpscaled = try XCTUnwrap(ViewerFullImageDecoder.decodeCGImage(data, maxPixelSize: 4096))
        XCTAssertEqual(notUpscaled.width, 200)
        XCTAssertEqual(notUpscaled.height, 100)

        // nil cap == full resolution (the zoom/export path is unchanged).
        let full = try XCTUnwrap(ViewerFullImageDecoder.decodeCGImage(data))
        XCTAssertEqual(full.width, 200)
        XCTAssertEqual(full.height, 100)
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 255
            pixels[index + 3] = 255
        }
        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
