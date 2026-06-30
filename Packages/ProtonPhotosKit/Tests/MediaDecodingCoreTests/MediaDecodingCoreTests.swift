import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MediaDecodingCore

@Suite("MediaDecodingCore")
struct MediaDecodingCoreTests {
    @Test func downsampleProducesBoundedCGImageAndMetadata() throws {
        let decoded = try #require(ThumbnailImageDecoder.downsample(Self.pngData(width: 32, height: 16), maxPixelSize: 8))

        #expect(max(decoded.pixelWidth, decoded.pixelHeight) <= 8)
        #expect(decoded.pixelWidth > 0)
        #expect(decoded.pixelHeight > 0)
        #expect(abs(decoded.aspectRatio - 2.0) < 0.2)
        #expect(decoded.decodedCostBytes == decoded.pixelWidth * decoded.pixelHeight * 4)
    }

    @Test func invalidBytesReturnNil() {
        #expect(ThumbnailImageDecoder.downsample(Data([0x01, 0x02, 0x03]), maxPixelSize: 8) == nil)
    }

    private static func pngData(width: Int, height: Int) -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = 160
            pixels[offset + 1] = 90
            pixels[offset + 2] = 50
            pixels[offset + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

@Suite("MediaDecodingCore platform purity")
struct MediaDecodingCorePlatformPurityTests {
    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 { url.deleteLastPathComponent() }
        return url
    }

    private var sources: URL {
        packageRoot.appendingPathComponent("Sources/MediaDecodingCore")
    }

    private static let forbiddenFrameworkImports: [String] = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "AVKit",
        "MetalKit",
    ]

    private static let forbiddenTokens: [String] = [
        "NSImage",
        "UIImage",
        "NSView",
        "UIView",
        "NSWorkspace",
        "NSOpenPanel",
        "UIApplication",
        "NSApplication",
    ]

    private static let allowedFrameworkImports: Set<String> = [
        "CoreGraphics",
        "Foundation",
        "ImageIO",
    ]

    @Test func hasNoPlatformFrameworkImports() throws {
        let files = try swiftFiles(in: sources)
        #expect(!files.isEmpty)

        var violations: [String] = []
        var seen: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(whereSeparator: { $0.isNewline }) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let remainder = trimmed.dropFirst("import ".count)
                let moduleName = remainder.split(separator: " ").first.map(String.init) ?? String(remainder)
                seen.insert(moduleName)
                if Self.forbiddenFrameworkImports.contains(moduleName) {
                    violations.append("\(file.lastPathComponent): \(trimmed)")
                }
            }
        }

        #expect(violations.isEmpty, "MediaDecodingCore must not import platform UI frameworks:\n\(violations.joined(separator: "\n"))")
        #expect(seen.subtracting(Self.allowedFrameworkImports).isEmpty, "Unexpected MediaDecodingCore imports: \(seen.subtracting(Self.allowedFrameworkImports).sorted())")
    }

    @Test func hasNoPlatformImageTokens() throws {
        let files = try swiftFiles(in: sources)
        #expect(!files.isEmpty)

        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in Self.forbiddenTokens where source.range(of: "\\b\(token)\\b", options: .regularExpression) != nil {
                violations.append("\(file.lastPathComponent): \(token)")
            }
        }

        #expect(violations.isEmpty, "MediaDecodingCore must not reference platform UI image/view types:\n\(violations.joined(separator: "\n"))")
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  url.pathExtension == "swift" else { continue }
            results.append(url)
        }
        return results.sorted { $0.path < $1.path }
    }
}

@Suite("MediaCache decoder boundary")
struct MediaCacheDecoderBoundaryTests {
    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 { url.deleteLastPathComponent() }
        return url
    }

    @Test func thumbnailFeedDoesNotOwnImageIODecodeImplementation() throws {
        let feedURL = packageRoot.appendingPathComponent("Sources/MediaCache/ThumbnailFeed.swift")
        let source = try String(contentsOf: feedURL, encoding: .utf8)

        #expect(!source.contains("import ImageIO"))
        #expect(!source.contains("CGImageSourceCreate"))
        #expect(!source.contains("kCGImageSource"))
        #expect(!source.contains("CreateThumbnailAtIndex"))
    }
}
