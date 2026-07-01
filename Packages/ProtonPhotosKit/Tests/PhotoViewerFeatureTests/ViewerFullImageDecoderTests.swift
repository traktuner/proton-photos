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
