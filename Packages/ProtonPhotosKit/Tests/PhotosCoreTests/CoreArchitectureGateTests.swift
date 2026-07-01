import Foundation
import XCTest

/// Central regression gate for universal Core targets.
///
/// Target-local purity tests still exist as focused unit tests, but this file is the
/// shared contract that every universal Core target must pass. Add a target here
/// before treating it as reusable Core.
final class CoreArchitectureGateTests: XCTestCase {
    private struct CoreTargetRule {
        let name: String
        let allowedImports: Set<String>
        let expectedDependencies: Set<String>
        let extraForbiddenTokens: [String]
    }

    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 { url.deleteLastPathComponent() }
        return url
    }

    private var packageManifest: URL {
        packageRoot.appendingPathComponent("Package.swift")
    }

    private var sourcesRoot: URL {
        packageRoot.appendingPathComponent("Sources")
    }

    private static let coreTargets: [CoreTargetRule] = [
        CoreTargetRule(
            name: "PhotosCore",
            allowedImports: ["AVFoundation", "CoreGraphics", "Foundation"],
            expectedDependencies: [],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "MediaByteCache",
            allowedImports: ["CryptoKit", "Foundation", "PhotosCore", "Security"],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: ["CGImage"]
        ),
        CoreTargetRule(
            name: "MediaDecodingCore",
            allowedImports: ["CoreGraphics", "Foundation", "ImageIO"],
            expectedDependencies: [],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "MediaFeedCore",
            allowedImports: ["Foundation", "MediaByteCache", "MediaDecodingCore", "PhotosCore"],
            expectedDependencies: ["MediaByteCache", "MediaDecodingCore", "PhotosCore"],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "MediaLocationCore",
            allowedImports: ["CryptoKit", "Foundation", "Observation", "PhotosCore"],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "GridCore",
            // QuartzCore intentionally NOT allowed (tightened in Phase 3.9): GridCore is pure value geometry
            // that takes injected clocks (never `CACurrentMediaTime`) and uses simd/`CGAffineTransform` (never
            // `CATransform3D`), so it needs no QuartzCore symbol. Excluding QuartzCore structurally closes the
            // render-surface hole where a QuartzCore-sourced `CAMetalDrawable`/`CAMetalLayer`/`CADisplayLink`
            // could otherwise enter Core past BOTH the import allowlist and the token gate. Re-add consciously
            // (with a value-math justification) if a legitimate need ever appears.
            allowedImports: ["CoreGraphics", "simd"],
            expectedDependencies: [],
            // CoreGraphics DRAWING/surface types — as opposed to the `CGRect`/`CGSize`/`CGPoint`/`CGFloat`
            // value types GridCore legitimately relies on — have no place in pure grid geometry. Scoped to
            // GridCore (not global) because `CGImage` IS a legitimate decoded-image type in MediaDecodingCore
            // and MediaFeedCore, so a global ban would wrongly fail those Core targets.
            extraForbiddenTokens: ["CGContext", "CGImage", "CGColorSpace", "CGLayer"]
        ),
    ]

    private static let forbiddenFrameworkImports: Set<String> = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "MapKit",
        "AVKit",
        // `Metal` (not just `MetalKit`): the renderer/drawable boundary (`MetalGridDrawableTarget`,
        // `MTLRenderPassDescriptor`, `MTLCommandBuffer`) is platform-adapter concern and must not be imported
        // by any universal Core target. See docs/metalgrid-boundary-audit.md Phase 3.9.
        "Metal",
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
        "MTKView",
        // Render/GPU-surface + presentation types (Phase 3.9). None is ever a legitimate universal-Core type;
        // they belong in platform adapters. `CAMetal*`/`CADisplayLink`/`CALayer` are QuartzCore-sourced (so a
        // ban is meaningful even if QuartzCore were re-allowed), and `MTL*` are Metal resource objects — banning
        // the concrete type names catches a fully-qualified reference or a re-exporting shim even if the `Metal`
        // import ban were bypassed.
        "CAMetalDrawable",
        "CAMetalLayer",
        "CAMetalDisplayLink",
        "CADisplayLink",
        "CALayer",
        "MTLDevice",
        "MTLTexture",
        "MTLBuffer",
        "MTLCommandQueue",
        "MTLCommandBuffer",
        "MTLRenderPassDescriptor",
        "MTLRenderCommandEncoder",
        "ProcessInfo.processInfo.physicalMemory",
        "ProcessInfo.processInfo.activeProcessorCount",
    ]

    private static let adapterAndFeatureModules: Set<String> = [
        "AlbumsFeature",
        "DesignSystem",
        "MapFeature",
        "MediaCache",
        "PhotoViewerFeature",
        "ProtonAuth",
        "TimelineFeature",
        "UploadFeature",
    ]

    private static let renderingCoreAllowedImports: Set<String> = [
        "CoreGraphics",
        "Metal",
        "QuartzCore",
        "simd",
    ]

    private static let renderingCoreForbiddenImports: Set<String> = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "MapKit",
        "AVKit",
        "MetalKit",
        "PhotosCore",
        "MediaCache",
        "TimelineFeature",
    ]

    private static let renderingCoreForbiddenTokens: [String] = [
        "MTKView",
        "NSView",
        "UIView",
        "NSImage",
        "UIImage",
        "NSScrollView",
        "UIScrollView",
        "NSEvent",
        "UIEvent",
        "NSGestureRecognizer",
        "UIGestureRecognizer",
        "NSAccessibility",
        "NSColor",
        "UIColor",
        "NSFont",
        "UIFont",
        "NSBezierPath",
        "UIBezierPath",
        "PhotoUID",
        "PhotoItem",
        "ThumbnailFeed",
        "MediaCache",
        "CAMetalLayer",
        "CAMetalDisplayLink",
        "CADisplayLink",
        "CALayer",
        "ProcessInfo.processInfo.physicalMemory",
        "ProcessInfo.processInfo.activeProcessorCount",
    ]

    func testUniversalCoreImportsStayOnTargetAllowlists() throws {
        var violations: [String] = []

        for rule in Self.coreTargets {
            let files = try swiftFiles(in: sourcesRoot.appendingPathComponent(rule.name))
            XCTAssertFalse(files.isEmpty, "Expected source files for \(rule.name)")

            for file in files {
                let imports = try importedModules(in: file)
                let unexpected = imports.subtracting(rule.allowedImports)
                if !unexpected.isEmpty {
                    violations.append("\(rule.name)/\(file.lastPathComponent): unexpected imports \(unexpected.sorted())")
                }

                let forbidden = imports.intersection(Self.forbiddenFrameworkImports)
                if !forbidden.isEmpty {
                    violations.append("\(rule.name)/\(file.lastPathComponent): forbidden platform imports \(forbidden.sorted())")
                }

                let featureImports = imports.intersection(Self.adapterAndFeatureModules)
                if !featureImports.isEmpty {
                    violations.append("\(rule.name)/\(file.lastPathComponent): Core must not import adapters/features \(featureImports.sorted())")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Universal Core import gate failed:
            \(violations.joined(separator: "\n"))

            Add reusable code to the correct Core target and update this shared
            rule only after confirming macOS, iOS, and iPadOS buildability.
            """
        )
    }

    func testUniversalCoreSourcesDoNotReferencePlatformUITypesOrHardwarePolicy() throws {
        var violations: [String] = []

        for rule in Self.coreTargets {
            let forbidden = Self.forbiddenTokens + rule.extraForbiddenTokens
            let files = try swiftFiles(in: sourcesRoot.appendingPathComponent(rule.name))
            XCTAssertFalse(files.isEmpty, "Expected source files for \(rule.name)")

            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                let code = stripCommentsAndStringLiterals(from: source)
                for token in forbidden where contains(token, in: code) {
                    violations.append("\(rule.name)/\(file.lastPathComponent): \(token)")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Universal Core token gate failed:
            \(violations.joined(separator: "\n"))

            Platform image/view types and hardware sizing policy belong in
            platform adapters, not in reusable Core targets.
            """
        )
    }

    func testPackageManifestKeepsUniversalCoreDependenciesOneWay() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        var violations: [String] = []

        for rule in Self.coreTargets {
            guard let dependencyLine = manifestLine(forTarget: rule.name, in: manifest) else {
                violations.append("\(rule.name): missing Package.swift target declaration")
                continue
            }
            let dependencies = Set(dependencies(inTargetLine: dependencyLine))
            if dependencies != rule.expectedDependencies {
                violations.append(
                    "\(rule.name): dependencies \(dependencies.sorted()) != expected \(rule.expectedDependencies.sorted())"
                )
            }
            let forbidden = dependencies.intersection(Self.adapterAndFeatureModules)
            if !forbidden.isEmpty {
                violations.append("\(rule.name): must not depend on adapters/features \(forbidden.sorted())")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Universal Core dependency gate failed:
            \(violations.joined(separator: "\n"))

            Core dependencies may point only toward lower-level Core targets.
            Adapters and feature/UI targets must depend on Core, never the reverse.
            """
        )
    }

    func testUniversalCoreProductsArePublishedByMatchingTargets() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let missing = Self.coreTargets
            .map(\.name)
            .filter { target in
                !manifest.contains(".library(name: \"\(target)\", targets: [\"\(target)\"])")
            }

        XCTAssertTrue(
            missing.isEmpty,
            "Universal Core targets must be published as matching library products: \(missing.sorted())"
        )
    }

    func testMetalRenderingCoreHasSeparatePackageBoundary() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        var violations: [String] = []

        if !manifest.contains(".library(name: \"MetalRenderingCore\", targets: [\"MetalRenderingCore\"])") {
            violations.append("MetalRenderingCore: missing matching library product")
        }

        guard let targetLine = manifestLine(forTarget: "MetalRenderingCore", in: manifest) else {
            XCTFail("MetalRenderingCore: missing Package.swift target declaration")
            return
        }

        let dependencies = Set(dependencies(inTargetLine: targetLine))
        if !dependencies.isEmpty {
            violations.append("MetalRenderingCore: dependencies \(dependencies.sorted()) != []")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            MetalRenderingCore package boundary regressed:
            \(violations.joined(separator: "\n"))

            Shared Metal rendering has its own target and gate; it is not Universal GridCore.
            """
        )
    }

    func testMetalRenderingCoreStaysRenderOnly() throws {
        let sourceRoot = sourcesRoot.appendingPathComponent("MetalRenderingCore")
        let files = try swiftFiles(in: sourceRoot)
        XCTAssertFalse(files.isEmpty, "Expected source files for MetalRenderingCore")

        var violations: [String] = []

        for file in files {
            let imports = try importedModules(in: file)
            let unexpected = imports.subtracting(Self.renderingCoreAllowedImports)
            if !unexpected.isEmpty {
                violations.append("MetalRenderingCore/\(file.lastPathComponent): unexpected imports \(unexpected.sorted())")
            }

            let forbiddenImports = imports.intersection(Self.renderingCoreForbiddenImports)
            if !forbiddenImports.isEmpty {
                violations.append("MetalRenderingCore/\(file.lastPathComponent): forbidden imports \(forbiddenImports.sorted())")
            }

            let source = try String(contentsOf: file, encoding: .utf8)
            let code = stripCommentsAndStringLiterals(from: source)
            for token in Self.renderingCoreForbiddenTokens where contains(token, in: code) {
                violations.append("MetalRenderingCore/\(file.lastPathComponent): forbidden token \(token)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            MetalRenderingCore render-only gate failed:
            \(violations.joined(separator: "\n"))

            MetalRenderingCore may own Metal draw primitives and draw targets, but platform views,
            scroll/gesture hosts, glyph rasterization, photo-domain IDs, media feeds, and hardware budgets
            belong in adapters.
            """
        )
    }

    func testSmallPureGridHelpersStayInUniversalGridCore() throws {
        let helperNames = ["GridVisualConstants.swift", "MetalGridGeometry.swift"]
        let gridCoreRoot = sourcesRoot.appendingPathComponent("GridCore")
        let timelineRoot = sourcesRoot.appendingPathComponent("TimelineFeature")
        var violations: [String] = []

        for helperName in helperNames {
            let coreFile = gridCoreRoot.appendingPathComponent(helperName)
            let timelineFile = timelineRoot.appendingPathComponent(helperName)

            if !FileManager.default.fileExists(atPath: coreFile.path) {
                violations.append("GridCore/\(helperName): missing pure helper")
                continue
            }

            if FileManager.default.fileExists(atPath: timelineFile.path) {
                violations.append("TimelineFeature/\(helperName): pure helper must stay out of the macOS adapter target")
            }

            let imports = try importedModules(in: coreFile)
            if imports != ["CoreGraphics"] {
                violations.append("GridCore/\(helperName): imports \(imports.sorted()) != [CoreGraphics]")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Phase 4.1 GridCore extraction regressed:
            \(violations.joined(separator: "\n"))

            Pure grid constants and coordinate math belong in universal Core.
            """
        )
    }

    func testGridZoomCommitBridgeStaysInUniversalGridCore() throws {
        let coreFile = sourcesRoot
            .appendingPathComponent("GridCore")
            .appendingPathComponent("GridZoomCommitBridge.swift")
        let timelineFile = sourcesRoot
            .appendingPathComponent("TimelineFeature")
            .appendingPathComponent("GridZoomCommit.swift")
        var violations: [String] = []

        guard FileManager.default.fileExists(atPath: coreFile.path) else {
            XCTFail("GridCore/GridZoomCommitBridge.swift: missing pure commit bridge")
            return
        }

        let imports = try importedModules(in: coreFile)
        if imports != ["CoreGraphics"] {
            violations.append("GridCore/GridZoomCommitBridge.swift: imports \(imports.sorted()) != [CoreGraphics]")
        }

        let coreSource = try String(contentsOf: coreFile, encoding: .utf8)
        let timelineSource = try String(contentsOf: timelineFile, encoding: .utf8)
        for symbol in ["GridZoomTrigger", "GridZoomCommitBridge", "GridZoomCommitDelta"] {
            if !coreSource.contains(symbol) {
                violations.append("GridCore/GridZoomCommitBridge.swift: missing \(symbol)")
            }
            if timelineSource.contains("public enum \(symbol)") || timelineSource.contains("public struct \(symbol)") {
                violations.append("TimelineFeature/GridZoomCommit.swift: \(symbol) must stay in universal Core")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Phase 4.2 GridCore commit-bridge extraction regressed:
            \(violations.joined(separator: "\n"))

            Pure zoom-trigger semantics and commit bridge geometry belong in universal Core.
            """
        )
    }

    func testGridProxySeamStaysGenericAndUniversal() throws {
        let gridCoreRoot = sourcesRoot.appendingPathComponent("GridCore")
        let timelineRoot = sourcesRoot.appendingPathComponent("TimelineFeature")
        let proxyFile = gridCoreRoot.appendingPathComponent("GridProxy.swift")
        let anchorFile = gridCoreRoot.appendingPathComponent("GridScrollAnchor.swift")
        var violations: [String] = []

        for file in [proxyFile, anchorFile] {
            if !FileManager.default.fileExists(atPath: file.path) {
                violations.append("GridCore/\(file.lastPathComponent): missing universal shell/grid seam")
                continue
            }

            let imports = try importedModules(in: file)
            if imports != ["CoreGraphics"] {
                violations.append("GridCore/\(file.lastPathComponent): imports \(imports.sorted()) != [CoreGraphics]")
            }

            let source = try String(contentsOf: file, encoding: .utf8)
            for forbidden in ["PhotosCore", "PhotoItem", "PhotoUID", "TimelineFeature"] where source.contains(forbidden) {
                violations.append("GridCore/\(file.lastPathComponent): must stay item-ID generic; found \(forbidden)")
            }
        }

        let proxySource = try String(contentsOf: proxyFile, encoding: .utf8)
        if !proxySource.contains("final class GridProxy<ItemID") {
            violations.append("GridCore/GridProxy.swift: GridProxy must stay generic over item ID")
        }
        if !proxySource.contains("GridScrollAnchor<ItemID>") {
            violations.append("GridCore/GridProxy.swift: currentScrollAnchor must use the generic GridScrollAnchor")
        }

        let anchorSource = try String(contentsOf: anchorFile, encoding: .utf8)
        if !anchorSource.contains("struct GridScrollAnchor<ItemID") || !anchorSource.contains("let itemID: ItemID") {
            violations.append("GridCore/GridScrollAnchor.swift: anchor must stay generic over item ID")
        }

        if FileManager.default.fileExists(atPath: timelineRoot.appendingPathComponent("GridProxy.swift").path) {
            violations.append("TimelineFeature/GridProxy.swift: generic proxy seam belongs in universal GridCore")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Phase 4.3 GridProxy seam extraction regressed:
            \(violations.joined(separator: "\n"))

            The shell/grid command seam must stay generic and platform-neutral in GridCore.
            """
        )
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

    private func importedModules(in file: URL) throws -> Set<String> {
        let source = try String(contentsOf: file, encoding: .utf8)
        var modules = Set<String>()

        for line in source.split(whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefix: String
            if trimmed.hasPrefix("@_exported import ") {
                prefix = "@_exported import "
            } else if trimmed.hasPrefix("@preconcurrency import ") {
                prefix = "@preconcurrency import "
            } else if trimmed.hasPrefix("import ") {
                prefix = "import "
            } else {
                continue
            }
            let remainder = trimmed.dropFirst(prefix.count)
            let moduleName = remainder.split(separator: " ").first.map(String.init) ?? String(remainder)
            modules.insert(moduleName)
        }

        return modules
    }

    private func manifestLine(forTarget target: String, in manifest: String) -> String? {
        manifest
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .first { $0.contains(".target(name: \"\(target)\"") }
    }

    private func dependencies(inTargetLine line: String) -> [String] {
        guard let dependenciesRange = line.range(of: #"dependencies:\s*\[(.*?)\]"#, options: .regularExpression) else {
            return []
        }
        let dependencies = String(line[dependenciesRange])
        let matches = dependencies.matches(of: #/\"([A-Za-z0-9_]+)\"/#)
        return matches.map { String($0.1) }
    }

    private func contains(_ token: String, in code: String) -> Bool {
        if token.contains(".") {
            return code.contains(token)
        }

        let pattern = #"\b\#(NSRegularExpression.escapedPattern(for: token))\b"#
        return code.range(of: pattern, options: .regularExpression) != nil
    }

    private func stripCommentsAndStringLiterals(from source: String) -> String {
        var result = ""
        var index = source.startIndex
        var inLineComment = false
        var inBlockComment = false
        var inString = false
        var escapingString = false

        func nextIndex(after index: String.Index) -> String.Index {
            source.index(after: index)
        }

        while index < source.endIndex {
            let character = source[index]
            let next = nextIndex(after: index)
            let nextCharacter = next < source.endIndex ? source[next] : nil

            if inLineComment {
                if character == "\n" {
                    inLineComment = false
                    result.append("\n")
                } else {
                    result.append(" ")
                }
                index = next
                continue
            }

            if inBlockComment {
                if character == "*", nextCharacter == "/" {
                    inBlockComment = false
                    result.append("  ")
                    index = nextIndex(after: next)
                } else {
                    result.append(character == "\n" ? "\n" : " ")
                    index = next
                }
                continue
            }

            if inString {
                if escapingString {
                    escapingString = false
                    result.append(" ")
                } else if character == "\\" {
                    escapingString = true
                    result.append(" ")
                } else if character == "\"" {
                    inString = false
                    result.append(" ")
                } else {
                    result.append(character == "\n" ? "\n" : " ")
                }
                index = next
                continue
            }

            if character == "/", nextCharacter == "/" {
                inLineComment = true
                result.append("  ")
                index = nextIndex(after: next)
            } else if character == "/", nextCharacter == "*" {
                inBlockComment = true
                result.append("  ")
                index = nextIndex(after: next)
            } else if character == "\"" {
                inString = true
                result.append(" ")
                index = next
            } else {
                result.append(character)
                index = next
            }
        }

        return result
    }
}
