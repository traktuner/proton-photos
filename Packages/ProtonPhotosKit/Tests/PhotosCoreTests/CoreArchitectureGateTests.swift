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
        CoreTargetRule(
            name: "UploadCore",
            allowedImports: ["Foundation", "Observation", "PhotosCore"],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "TimelineCore",
            allowedImports: ["CoreGraphics", "Foundation", "GridCore", "PhotosCore"],
            expectedDependencies: ["GridCore", "PhotosCore"],
            extraForbiddenTokens: []
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
        "DesignSystemAppKitAdapter",
        "DesignSystemCore",
        "MapFeature",
        "MediaCache",
        "MetalGridTextureAppKitAdapter",
        "MetalGridTextureUIKitAdapter",
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

    private static let textureCoreAllowedImports: Set<String> = [
        "CoreGraphics",
        "GridCore",
        "Metal",
    ]

    private static let textureCoreForbiddenImports: Set<String> = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "MapKit",
        "AVKit",
        "MetalKit",
        "PhotosCore",
        "MediaCache",
        "TimelineFeature",
        "MetalRenderingCore",
        "DesignSystem",
    ]

    private static let textureCoreForbiddenTokens: [String] = [
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
        "PhotoUID",
        "PhotoItem",
        "ThumbnailFeed",
        "MediaCache",
        "MetalGridRenderer",
        "MetalGridDrawableTarget",
        "CAMetalDrawable",
        "CAMetalLayer",
        "CAMetalDisplayLink",
        "CADisplayLink",
        "CALayer",
        "MTLCommandQueue",
        "MTLCommandBuffer",
        "MTLRenderPassDescriptor",
        "MTLRenderCommandEncoder",
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

    func testDesignSystemKeepsSharedAndAppKitBoundariesSeparate() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let coreRoot = sourcesRoot.appendingPathComponent("DesignSystemCore")
        let appKitRoot = sourcesRoot.appendingPathComponent("DesignSystemAppKitAdapter")
        let compatRoot = sourcesRoot.appendingPathComponent("DesignSystem")
        var violations: [String] = []

        for product in ["DesignSystemCore", "DesignSystemAppKitAdapter", "DesignSystem"] {
            if !manifest.contains(".library(name: \"\(product)\", targets: [\"\(product)\"])") {
                violations.append("\(product): missing matching product")
            }
        }

        for file in ["ProtonComponents.swift", "ProtonColors.swift"] {
            if !FileManager.default.fileExists(atPath: coreRoot.appendingPathComponent(file).path) {
                violations.append("DesignSystemCore/\(file): missing shared SwiftUI file")
            }
        }
        if !FileManager.default.fileExists(atPath: appKitRoot.appendingPathComponent("LoadingVeil.swift").path) {
            violations.append("DesignSystemAppKitAdapter/LoadingVeil.swift: missing AppKit launch-veil adapter")
        }
        if !FileManager.default.fileExists(atPath: appKitRoot.appendingPathComponent("Resources").path) {
            violations.append("DesignSystemAppKitAdapter/Resources: branding assets must live with the adapter that uses them")
        }

        let coreFiles = try swiftFiles(in: coreRoot)
        for file in coreFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            let code = stripCommentsAndStringLiterals(from: source)
            for token in ["NSViewRepresentable", "NSVisualEffectView", "NSView", "FrostedGlassBackground", "LoadingMark"] where contains(token, in: code) {
                violations.append("DesignSystemCore/\(file.lastPathComponent): AppKit launch-veil symbol leaked into shared UI core (\(token))")
            }
        }

        let adapterFile = appKitRoot.appendingPathComponent("LoadingVeil.swift")
        if FileManager.default.fileExists(atPath: adapterFile.path) {
            let adapterSource = try String(contentsOf: adapterFile, encoding: .utf8)
            for required in ["import AppKit", "NSViewRepresentable", "NSVisualEffectView", "import DesignSystemCore"] where !adapterSource.contains(required) {
                violations.append("DesignSystemAppKitAdapter/LoadingVeil.swift: missing \(required)")
            }
        }

        let exportsFile = compatRoot.appendingPathComponent("DesignSystemExports.swift")
        if FileManager.default.fileExists(atPath: exportsFile.path) {
            let exports = try String(contentsOf: exportsFile, encoding: .utf8)
            for required in ["@_exported import DesignSystemCore", "@_exported import DesignSystemAppKitAdapter"] where !exports.contains(required) {
                violations.append("DesignSystem/DesignSystemExports.swift: missing \(required)")
            }
        } else {
            violations.append("DesignSystem/DesignSystemExports.swift: missing compatibility exports")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            DesignSystem shared/AppKit split regressed:
            \(violations.joined(separator: "\n"))

            Cross-platform SwiftUI tokens/components belong in DesignSystemCore. Behind-window AppKit
            material and branding resources belong in DesignSystemAppKitAdapter. The legacy DesignSystem
            target is only a compatibility facade for macOS import sites.
            """
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

    func testMetalGridRendererLivesBehindRenderingCoreGate() throws {
        let renderingRoot = sourcesRoot.appendingPathComponent("MetalRenderingCore")
        let timelineRoot = sourcesRoot.appendingPathComponent("TimelineFeature")
        let rendererFile = renderingRoot.appendingPathComponent("MetalGridRenderer.swift")
        let oldRendererFile = timelineRoot.appendingPathComponent("MetalGridRenderer.swift")
        let adapterFile = timelineRoot.appendingPathComponent("MetalGridRenderer+MTKView.swift")
        var violations: [String] = []

        if !FileManager.default.fileExists(atPath: rendererFile.path) {
            violations.append("MetalRenderingCore/MetalGridRenderer.swift: missing shared renderer")
        }
        if FileManager.default.fileExists(atPath: oldRendererFile.path) {
            violations.append("TimelineFeature/MetalGridRenderer.swift: renderer must stay out of the platform adapter")
        }
        if !FileManager.default.fileExists(atPath: adapterFile.path) {
            violations.append("TimelineFeature/MetalGridRenderer+MTKView.swift: missing MTKView adapter seam")
        }

        if FileManager.default.fileExists(atPath: rendererFile.path) {
            let imports = try importedModules(in: rendererFile)
            if imports.contains("MetalKit") {
                violations.append("MetalRenderingCore/MetalGridRenderer.swift: must not import MetalKit")
            }

            let source = try String(contentsOf: rendererFile, encoding: .utf8)
            let code = stripCommentsAndStringLiterals(from: source)
            for forbidden in ["MTKView", "MetalGridPalette", "PhotosCore", "MediaCache", "PhotoUID"] where contains(forbidden, in: code) {
                violations.append("MetalRenderingCore/MetalGridRenderer.swift: forbidden adapter/domain reference \(forbidden)")
            }
            if !source.contains("package final class MetalGridRenderer") {
                violations.append("MetalRenderingCore/MetalGridRenderer.swift: renderer must be package-visible to adapters")
            }
            if !source.contains("package func render(to target: MetalGridDrawableTarget") {
                violations.append("MetalRenderingCore/MetalGridRenderer.swift: renderer must expose drawable-target render entry")
            }
        }

        if FileManager.default.fileExists(atPath: adapterFile.path) {
            let source = try String(contentsOf: adapterFile, encoding: .utf8)
            if !source.contains("import MetalKit") || !source.contains("init?(view: MTKView)") {
                violations.append("TimelineFeature/MetalGridRenderer+MTKView.swift: MTKView conversion belongs only in adapter")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Phase 4.5 MetalGridRenderer split regressed:
            \(violations.joined(separator: "\n"))

            Shared shader/pipeline/command encoding belongs in MetalRenderingCore; MTKView conversion remains
            in the TimelineFeature adapter.
            """
        )
    }

    func testMetalGridTextureCoreHasSeparatePackageBoundary() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        var violations: [String] = []

        if !manifest.contains(".library(name: \"MetalGridTextureCore\", targets: [\"MetalGridTextureCore\"])") {
            violations.append("MetalGridTextureCore: missing matching library product")
        }

        guard let targetLine = manifestLine(forTarget: "MetalGridTextureCore", in: manifest) else {
            XCTFail("MetalGridTextureCore: missing Package.swift target declaration")
            return
        }

        let dependencies = Set(dependencies(inTargetLine: targetLine))
        if dependencies != ["GridCore"] {
            violations.append("MetalGridTextureCore: dependencies \(dependencies.sorted()) != [GridCore]")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            MetalGridTextureCore package boundary regressed:
            \(violations.joined(separator: "\n"))

            Shared Metal texture caching is separate from render command encoding and may depend only on
            GridCore's portable texture policies.
            """
        )
    }

    func testMetalGridTextureCoreStaysTextureOnly() throws {
        let sourceRoot = sourcesRoot.appendingPathComponent("MetalGridTextureCore")
        let files = try swiftFiles(in: sourceRoot)
        XCTAssertFalse(files.isEmpty, "Expected source files for MetalGridTextureCore")

        var violations: [String] = []

        for file in files {
            let imports = try importedModules(in: file)
            let unexpected = imports.subtracting(Self.textureCoreAllowedImports)
            if !unexpected.isEmpty {
                violations.append("MetalGridTextureCore/\(file.lastPathComponent): unexpected imports \(unexpected.sorted())")
            }

            let forbiddenImports = imports.intersection(Self.textureCoreForbiddenImports)
            if !forbiddenImports.isEmpty {
                violations.append("MetalGridTextureCore/\(file.lastPathComponent): forbidden imports \(forbiddenImports.sorted())")
            }

            let source = try String(contentsOf: file, encoding: .utf8)
            let code = stripCommentsAndStringLiterals(from: source)
            for token in Self.textureCoreForbiddenTokens where contains(token, in: code) {
                violations.append("MetalGridTextureCore/\(file.lastPathComponent): forbidden token \(token)")
            }
        }

        let cacheFile = sourceRoot.appendingPathComponent("MetalGridTextureCache.swift")
        let glyphFile = sourceRoot.appendingPathComponent("MetalGridGlyphRasterizer.swift")
        for file in [cacheFile, glyphFile] where !FileManager.default.fileExists(atPath: file.path) {
            violations.append("MetalGridTextureCore/\(file.lastPathComponent): missing shared texture-core file")
        }

        if FileManager.default.fileExists(atPath: cacheFile.path) {
            let source = try String(contentsOf: cacheFile, encoding: .utf8)
            for symbol in ["package final class MetalGridTextureCache", "GridTextureResidencyPolicy<ID>", "GridTextureBudget", "uploadVisible(wanted: [ID]"] where !source.contains(symbol) {
                violations.append("MetalGridTextureCore/MetalGridTextureCache.swift: missing \(symbol)")
            }
        }

        if FileManager.default.fileExists(atPath: glyphFile.path) {
            let source = try String(contentsOf: glyphFile, encoding: .utf8)
            for symbol in ["package struct MetalGridGlyphRequest", "package struct MetalGridGlyphColor", "package protocol MetalGridGlyphRasterizing"] where !source.contains(symbol) {
                violations.append("MetalGridTextureCore/MetalGridGlyphRasterizer.swift: missing \(symbol)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            MetalGridTextureCore texture-only gate failed:
            \(violations.joined(separator: "\n"))

            This target may own reusable Metal texture resources and upload/cache mechanics. Platform views,
            glyph rasterization implementations, render command encoding, photo-domain IDs, media feeds, and
            hardware-budget defaults remain outside this target.
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

    func testGridTextureBudgetShapeIsUniversalButDefaultsStayInAdapter() throws {
        let gridCoreRoot = sourcesRoot.appendingPathComponent("GridCore")
        let timelineRoot = sourcesRoot.appendingPathComponent("TimelineFeature")
        let appKitAdapterRoot = sourcesRoot.appendingPathComponent("MetalGridTextureAppKitAdapter")
        let budgetFile = gridCoreRoot.appendingPathComponent("GridTextureBudget.swift")
        let timelineTypesFile = timelineRoot.appendingPathComponent("MetalGridTypes.swift")
        let appKitPolicyFile = appKitAdapterRoot.appendingPathComponent("AppKitMetalGridTexturePolicy.swift")
        var violations: [String] = []

        guard FileManager.default.fileExists(atPath: budgetFile.path) else {
            XCTFail("GridCore/GridTextureBudget.swift: missing platform-injected texture budget shape")
            return
        }

        let budgetImports = try importedModules(in: budgetFile)
        if budgetImports != ["CoreGraphics"] {
            violations.append("GridCore/GridTextureBudget.swift: imports \(budgetImports.sorted()) != [CoreGraphics]")
        }

        let budgetSource = try String(contentsOf: budgetFile, encoding: .utf8)
        let budgetCode = stripCommentsAndStringLiterals(from: budgetSource)
        for symbol in ["GridTextureBudget", "maxUploadsPerFrame", "maxCachedTextures", "overscanFraction"] {
            if !budgetCode.contains(symbol) {
                violations.append("GridCore/GridTextureBudget.swift: missing \(symbol)")
            }
        }
        for forbidden in ["PhotosCore", "PhotoUID", "MTLTexture", "MetalGridBudget", "static let `default`"] where budgetCode.contains(forbidden) {
            violations.append("GridCore/GridTextureBudget.swift: universal budget shape must not contain \(forbidden)")
        }

        let timelineImports = try importedModules(in: timelineTypesFile)
        if timelineImports.contains("PhotosCore") {
            violations.append("TimelineFeature/MetalGridTypes.swift: budget/stats value types must not import PhotosCore")
        }
        let timelineSource = try String(contentsOf: timelineTypesFile, encoding: .utf8)
        if timelineSource.contains("struct MetalGridBudget") {
            violations.append("TimelineFeature/MetalGridTypes.swift: MetalGridBudget must stay a typealias to GridTextureBudget")
        }
        if !timelineSource.contains("typealias MetalGridBudget = GridTextureBudget") {
            violations.append("TimelineFeature/MetalGridTypes.swift: missing adapter compatibility typealias")
        }
        for forbidden in ["static let `default`", "GridTextureBudget(maxUploadsPerFrame:", "maxCachedTextures: 4096"] where timelineSource.contains(forbidden) {
            violations.append("TimelineFeature/MetalGridTypes.swift: platform texture budget default must stay in an adapter, found \(forbidden)")
        }

        if FileManager.default.fileExists(atPath: appKitPolicyFile.path) {
            let appKitSource = try String(contentsOf: appKitPolicyFile, encoding: .utf8)
            for symbol in [
                "AppKitMetalGridTexturePolicies",
                "GridTextureBudget(maxUploadsPerFrame: 96, maxCachedTextures: 4096, overscanFraction: 1.2)",
                "package extension GridTextureBudget",
                "static let `default` = AppKitMetalGridTexturePolicies.default.budget"
            ] where !appKitSource.contains(symbol) {
                violations.append("MetalGridTextureAppKitAdapter/AppKitMetalGridTexturePolicy.swift: missing adapter-owned macOS default \(symbol)")
            }
        } else {
            violations.append("MetalGridTextureAppKitAdapter/AppKitMetalGridTexturePolicy.swift: missing adapter-owned macOS default")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Phase 4.6 grid texture budget boundary regressed:
            \(violations.joined(separator: "\n"))

            Universal Core owns the portable budget shape; platform adapters own concrete default values.
            """
        )
    }

    func testMetalGridTextureCacheUsesInjectedGlyphRasterizer() throws {
        let appKitAdapterRoot = sourcesRoot.appendingPathComponent("MetalGridTextureAppKitAdapter")
        let textureRoot = sourcesRoot.appendingPathComponent("MetalGridTextureCore")
        let timelineRoot = sourcesRoot.appendingPathComponent("TimelineFeature")
        let cacheFile = textureRoot.appendingPathComponent("MetalGridTextureCache.swift")
        let glyphContractFile = textureRoot.appendingPathComponent("MetalGridGlyphRasterizer.swift")
        let appKitRasterizerFile = appKitAdapterRoot.appendingPathComponent("AppKitMetalGridGlyphRasterizer.swift")
        let appKitFactoryFile = appKitAdapterRoot.appendingPathComponent("AppKitMetalGridTextureCacheFactory.swift")
        let coordinatorFile = timelineRoot.appendingPathComponent("MetalGridCoordinator.swift")
        var violations: [String] = []

        for file in [cacheFile, glyphContractFile, appKitRasterizerFile, appKitFactoryFile] where !FileManager.default.fileExists(atPath: file.path) {
            violations.append("\(file.deletingLastPathComponent().lastPathComponent)/\(file.lastPathComponent): missing glyph/cache boundary file")
        }

        if FileManager.default.fileExists(atPath: cacheFile.path) {
            let imports = try importedModules(in: cacheFile)
            if imports.contains("AppKit") {
                violations.append("MetalGridTextureCore/MetalGridTextureCache.swift: texture cache must not import AppKit")
            }
            let source = try String(contentsOf: cacheFile, encoding: .utf8)
            let code = stripCommentsAndStringLiterals(from: source)
            for forbidden in ["NSImage", "NSColor", "NSFont", "lockFocus", "systemSymbolName", "renderGlyph"] where contains(forbidden, in: code) {
                violations.append("MetalGridTextureCore/MetalGridTextureCache.swift: glyph rasterization leaked into cache via \(forbidden)")
            }
            if !source.contains("glyphRasterizer: any MetalGridGlyphRasterizing") {
                violations.append("MetalGridTextureCore/MetalGridTextureCache.swift: missing injected glyph rasterizer dependency")
            }
            if !source.contains("glyphRasterizer.image(for: request)") {
                violations.append("MetalGridTextureCore/MetalGridTextureCache.swift: glyph image must come from injected rasterizer")
            }
        }

        if FileManager.default.fileExists(atPath: glyphContractFile.path) {
            let imports = try importedModules(in: glyphContractFile)
            if imports != ["CoreGraphics"] {
                violations.append("MetalGridTextureCore/MetalGridGlyphRasterizer.swift: imports \(imports.sorted()) != [CoreGraphics]")
            }
            let source = try String(contentsOf: glyphContractFile, encoding: .utf8)
            for symbol in ["MetalGridGlyphRequest", "MetalGridGlyphColor", "MetalGridGlyphRasterizing"] where !source.contains(symbol) {
                violations.append("MetalGridTextureCore/MetalGridGlyphRasterizer.swift: missing \(symbol)")
            }
        }

        if FileManager.default.fileExists(atPath: appKitRasterizerFile.path) {
            let source = try String(contentsOf: appKitRasterizerFile, encoding: .utf8)
            if !source.contains("import AppKit") || !source.contains("import MetalGridTextureCore") || !source.contains("package final class AppKitMetalGridGlyphRasterizer") {
                violations.append("MetalGridTextureAppKitAdapter/AppKitMetalGridGlyphRasterizer.swift: AppKit implementation must own native glyph rasterization")
            }
            if !source.contains("NSImage(systemSymbolName:") || !source.contains("NSImage.SymbolConfiguration") {
                violations.append("MetalGridTextureAppKitAdapter/AppKitMetalGridGlyphRasterizer.swift: expected AppKit SF Symbol path")
            }
        }

        if FileManager.default.fileExists(atPath: appKitFactoryFile.path) {
            let source = try String(contentsOf: appKitFactoryFile, encoding: .utf8)
            if !source.contains("glyphRasterizer: any MetalGridGlyphRasterizing = AppKitMetalGridGlyphRasterizer()") {
                violations.append("MetalGridTextureAppKitAdapter/AppKitMetalGridTextureCacheFactory.swift: AppKit cache factory must inject the default AppKit rasterizer")
            }
            if !source.contains("MetalGridTextureCache(") || !source.contains("glyphRasterizer: glyphRasterizer") {
                violations.append("MetalGridTextureAppKitAdapter/AppKitMetalGridTextureCacheFactory.swift: factory must pass the injected rasterizer into the shared cache")
            }
        }

        if FileManager.default.fileExists(atPath: coordinatorFile.path) {
            let source = try String(contentsOf: coordinatorFile, encoding: .utf8)
            if !source.contains("import MetalGridTextureCore") {
                violations.append("TimelineFeature/MetalGridCoordinator.swift: macOS adapter must import the texture core explicitly")
            }
            if !source.contains("import MetalGridTextureAppKitAdapter") {
                violations.append("TimelineFeature/MetalGridCoordinator.swift: macOS adapter must import the AppKit texture adapter explicitly")
            }
            if !source.contains("AppKitMetalGridTextureCacheFactory.makeCache") {
                violations.append("TimelineFeature/MetalGridCoordinator.swift: macOS adapter must assemble the texture cache through the AppKit factory")
            }
            if source.contains("glyphRasterizer: AppKitMetalGridGlyphRasterizer()") {
                violations.append("TimelineFeature/MetalGridCoordinator.swift: direct glyph injection belongs in the AppKit cache factory")
            }
            if !source.contains("MetalGridGlyphColor(.controlAccentColor)") {
                violations.append("TimelineFeature/MetalGridCoordinator.swift: AppKit colors must convert at adapter edge")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Phase 4.7 glyph rasterizer boundary regressed:
            \(violations.joined(separator: "\n"))

            Texture upload/cache code may own Metal texture residency; native SF Symbol rasterization belongs
            behind an injected platform adapter so iOS/iPadOS can provide UIKit glyphs later.
            """
        )
    }

    func testAppKitGlyphRasterizerStaysInPlatformAdapter() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let adapterRoot = sourcesRoot.appendingPathComponent("MetalGridTextureAppKitAdapter")
        let timelineRoot = sourcesRoot.appendingPathComponent("TimelineFeature")
        let adapterFile = adapterRoot.appendingPathComponent("AppKitMetalGridGlyphRasterizer.swift")
        let coordinatorFile = timelineRoot.appendingPathComponent("MetalGridCoordinator.swift")
        var violations: [String] = []

        if !manifest.contains(".library(name: \"MetalGridTextureAppKitAdapter\", targets: [\"MetalGridTextureAppKitAdapter\"])") {
            violations.append("MetalGridTextureAppKitAdapter: missing matching library product")
        }

        if let targetLine = manifestLine(forTarget: "MetalGridTextureAppKitAdapter", in: manifest) {
            let dependencies = Set(dependencies(inTargetLine: targetLine))
            if dependencies != ["GridCore", "MetalGridTextureCore"] {
                violations.append("MetalGridTextureAppKitAdapter: dependencies \(dependencies.sorted()) != [GridCore, MetalGridTextureCore]")
            }
        } else {
            violations.append("MetalGridTextureAppKitAdapter: missing Package.swift target declaration")
        }

        guard FileManager.default.fileExists(atPath: adapterFile.path) else {
            XCTFail("MetalGridTextureAppKitAdapter/AppKitMetalGridGlyphRasterizer.swift: missing AppKit glyph adapter")
            return
        }

        let imports = try importedModules(in: adapterFile)
        let expectedImports: Set<String> = ["AppKit", "CoreGraphics", "MetalGridTextureCore"]
        if imports != expectedImports {
            violations.append("MetalGridTextureAppKitAdapter/AppKitMetalGridGlyphRasterizer.swift: imports \(imports.sorted()) != \(expectedImports.sorted())")
        }
        for forbidden in ["UIKit", "SwiftUI", "MetalKit", "PhotosCore", "MediaCache", "TimelineFeature"] where imports.contains(forbidden) {
            violations.append("MetalGridTextureAppKitAdapter/AppKitMetalGridGlyphRasterizer.swift: must not import \(forbidden)")
        }

        let source = try String(contentsOf: adapterFile, encoding: .utf8)
        for symbol in [
            "package final class AppKitMetalGridGlyphRasterizer",
            "MetalGridGlyphRasterizing",
            "NSImage.SymbolConfiguration",
            "NSImage(systemSymbolName:",
            "NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill(using: .sourceAtop)",
            "package extension MetalGridGlyphColor"
        ] where !source.contains(symbol) {
            violations.append("MetalGridTextureAppKitAdapter/AppKitMetalGridGlyphRasterizer.swift: missing \(symbol)")
        }

        if FileManager.default.fileExists(atPath: timelineRoot.appendingPathComponent("AppKitMetalGridGlyphRasterizer.swift").path) {
            violations.append("TimelineFeature/AppKitMetalGridGlyphRasterizer.swift: AppKit glyph rasterization belongs in MetalGridTextureAppKitAdapter")
        }

        if FileManager.default.fileExists(atPath: coordinatorFile.path) {
            let coordinator = try String(contentsOf: coordinatorFile, encoding: .utf8)
            if !coordinator.contains("import MetalGridTextureAppKitAdapter") {
                violations.append("TimelineFeature/MetalGridCoordinator.swift: missing AppKit texture adapter import")
            }
            if !coordinator.contains("AppKitMetalGridTextureCacheFactory.makeCache") {
                violations.append("TimelineFeature/MetalGridCoordinator.swift: must use the AppKit texture cache factory")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Phase 5.5 AppKit glyph adapter boundary regressed:
            \(violations.joined(separator: "\n"))

            macOS SF Symbol rasterization belongs in its AppKit texture adapter target; TimelineFeature may
            inject it but must not own the implementation.
            """
        )
    }

    func testAppKitTextureBudgetsStayAdapterOwned() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let adapterRoot = sourcesRoot.appendingPathComponent("MetalGridTextureAppKitAdapter")
        let timelineRoot = sourcesRoot.appendingPathComponent("TimelineFeature")
        let policyFile = adapterRoot.appendingPathComponent("AppKitMetalGridTexturePolicy.swift")
        let timelineTypesFile = timelineRoot.appendingPathComponent("MetalGridTypes.swift")
        var violations: [String] = []

        if let targetLine = manifestLine(forTarget: "MetalGridTextureAppKitAdapter", in: manifest) {
            let dependencies = Set(dependencies(inTargetLine: targetLine))
            if dependencies != ["GridCore", "MetalGridTextureCore"] {
                violations.append("MetalGridTextureAppKitAdapter: dependencies \(dependencies.sorted()) != [GridCore, MetalGridTextureCore]")
            }
        } else {
            violations.append("MetalGridTextureAppKitAdapter: missing Package.swift target declaration")
        }

        guard FileManager.default.fileExists(atPath: policyFile.path) else {
            XCTFail("MetalGridTextureAppKitAdapter/AppKitMetalGridTexturePolicy.swift: missing AppKit texture budget policy")
            return
        }

        let imports = try importedModules(in: policyFile)
        if imports != ["CoreGraphics", "GridCore"] {
            violations.append("MetalGridTextureAppKitAdapter/AppKitMetalGridTexturePolicy.swift: imports \(imports.sorted()) != [CoreGraphics, GridCore]")
        }

        let source = try String(contentsOf: policyFile, encoding: .utf8)
        let code = stripCommentsAndStringLiterals(from: source)
        for symbol in [
            "AppKitMetalGridTexturePolicy",
            "AppKitMetalGridTexturePolicies",
            "defaultMaxTexturePixels",
            "maxTexturePixels",
            "GridTextureBudget(maxUploadsPerFrame: 96, maxCachedTextures: 4096, overscanFraction: 1.2)",
            "maxTexturePixels: defaultMaxTexturePixels",
            "package extension GridTextureBudget",
            "static let `default` = AppKitMetalGridTexturePolicies.default.budget"
        ] where !source.contains(symbol) {
            violations.append("MetalGridTextureAppKitAdapter/AppKitMetalGridTexturePolicy.swift: missing \(symbol)")
        }
        for forbidden in ["ProcessInfo.processInfo.physicalMemory", "activeProcessorCount", "UIDevice", "userInterfaceIdiom", "PhotoUID", "PhotoItem", "TimelineFeature"] where contains(forbidden, in: code) {
            violations.append("MetalGridTextureAppKitAdapter/AppKitMetalGridTexturePolicy.swift: platform policy must not bind hardware probes or photo-domain types, found \(forbidden)")
        }

        let timelineSource = try String(contentsOf: timelineTypesFile, encoding: .utf8)
        for forbidden in ["static let `default`", "GridTextureBudget(maxUploadsPerFrame:", "maxCachedTextures: 4096"] where timelineSource.contains(forbidden) {
            violations.append("TimelineFeature/MetalGridTypes.swift: AppKit texture policy must stay adapter-owned, found \(forbidden)")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Phase 5.6 AppKit texture budget boundary regressed:
            \(violations.joined(separator: "\n"))

            macOS can keep aggressive desktop texture budgets, but those defaults belong to the AppKit texture
            adapter. GridCore may define only the portable shape and TimelineFeature may only consume it.
            """
        )
    }

    func testAppKitTextureCacheFactoryUsesSharedTextureCore() throws {
        let adapterRoot = sourcesRoot.appendingPathComponent("MetalGridTextureAppKitAdapter")
        let timelineRoot = sourcesRoot.appendingPathComponent("TimelineFeature")
        let factoryFile = adapterRoot.appendingPathComponent("AppKitMetalGridTextureCacheFactory.swift")
        let coordinatorFile = timelineRoot.appendingPathComponent("MetalGridCoordinator.swift")
        var violations: [String] = []

        guard FileManager.default.fileExists(atPath: factoryFile.path) else {
            XCTFail("MetalGridTextureAppKitAdapter/AppKitMetalGridTextureCacheFactory.swift: missing AppKit cache factory")
            return
        }

        let imports = try importedModules(in: factoryFile)
        let expectedImports: Set<String> = ["Metal", "MetalGridTextureCore"]
        if imports != expectedImports {
            violations.append("MetalGridTextureAppKitAdapter/AppKitMetalGridTextureCacheFactory.swift: imports \(imports.sorted()) != \(expectedImports.sorted())")
        }
        for forbidden in ["UIKit", "SwiftUI", "MetalKit", "PhotosCore", "MediaCache", "TimelineFeature"] where imports.contains(forbidden) {
            violations.append("MetalGridTextureAppKitAdapter/AppKitMetalGridTextureCacheFactory.swift: must not import \(forbidden)")
        }

        let source = try String(contentsOf: factoryFile, encoding: .utf8)
        let code = stripCommentsAndStringLiterals(from: source)
        for symbol in [
            "#if canImport(AppKit)",
            "AppKitMetalGridTextureCacheFactory",
            "makeCache<ID: Hashable & Sendable>",
            "MetalGridTextureCache<ID>",
            "AppKitMetalGridTexturePolicy",
            "AppKitMetalGridGlyphRasterizer()",
            "budget: policy.budget",
            "maxTexturePixels: policy.maxTexturePixels",
            "glyphRasterizer: glyphRasterizer"
        ] where !source.contains(symbol) {
            violations.append("MetalGridTextureAppKitAdapter/AppKitMetalGridTextureCacheFactory.swift: missing \(symbol)")
        }
        for forbidden in ["PhotoUID", "PhotoItem", "MetalGridBudget.default", "GridTextureBudget(", "maxUploadsPerFrame:", "maxCachedTextures:"] where contains(forbidden, in: code) {
            violations.append("MetalGridTextureAppKitAdapter/AppKitMetalGridTextureCacheFactory.swift: factory must use injected AppKit policy and generic IDs, found \(forbidden)")
        }

        if FileManager.default.fileExists(atPath: coordinatorFile.path) {
            let coordinator = try String(contentsOf: coordinatorFile, encoding: .utf8)
            if !coordinator.contains("AppKitMetalGridTexturePolicies.policy(budget: budget)") {
                violations.append("TimelineFeature/MetalGridCoordinator.swift: macOS coordinator must wrap its budget in an AppKit texture policy")
            }
            if !coordinator.contains("AppKitMetalGridTextureCacheFactory.makeCache") {
                violations.append("TimelineFeature/MetalGridCoordinator.swift: macOS coordinator must use the AppKit texture cache factory")
            }
            if coordinator.contains("MetalGridTextureCache<PhotoUID>(") {
                violations.append("TimelineFeature/MetalGridCoordinator.swift: direct cache construction should stay behind the AppKit factory")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Phase 5.7 AppKit texture cache factory boundary regressed:
            \(violations.joined(separator: "\n"))

            The macOS host may bind the shared cache to `PhotoUID`, but platform glyph/default-policy assembly
            belongs in the AppKit texture adapter factory.
            """
        )
    }

    func testUIKitGlyphRasterizerStaysInPlatformAdapter() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let adapterRoot = sourcesRoot.appendingPathComponent("MetalGridTextureUIKitAdapter")
        let adapterFile = adapterRoot.appendingPathComponent("UIKitMetalGridGlyphRasterizer.swift")
        let textureRoot = sourcesRoot.appendingPathComponent("MetalGridTextureCore")
        var violations: [String] = []

        if !manifest.contains(".library(name: \"MetalGridTextureUIKitAdapter\", targets: [\"MetalGridTextureUIKitAdapter\"])") {
            violations.append("MetalGridTextureUIKitAdapter: missing matching library product")
        }

        if let targetLine = manifestLine(forTarget: "MetalGridTextureUIKitAdapter", in: manifest) {
            let dependencies = Set(dependencies(inTargetLine: targetLine))
            if dependencies != ["GridCore", "MetalGridTextureCore"] {
                violations.append("MetalGridTextureUIKitAdapter: dependencies \(dependencies.sorted()) != [GridCore, MetalGridTextureCore]")
            }
        } else {
            violations.append("MetalGridTextureUIKitAdapter: missing Package.swift target declaration")
        }

        guard FileManager.default.fileExists(atPath: adapterFile.path) else {
            XCTFail("MetalGridTextureUIKitAdapter/UIKitMetalGridGlyphRasterizer.swift: missing UIKit glyph adapter")
            return
        }

        let imports = try importedModules(in: adapterFile)
        let expectedImports: Set<String> = ["CoreGraphics", "MetalGridTextureCore", "UIKit"]
        if imports != expectedImports {
            violations.append("MetalGridTextureUIKitAdapter/UIKitMetalGridGlyphRasterizer.swift: imports \(imports.sorted()) != \(expectedImports.sorted())")
        }
        for forbidden in ["AppKit", "SwiftUI", "MetalKit", "PhotosCore", "MediaCache", "TimelineFeature"] where imports.contains(forbidden) {
            violations.append("MetalGridTextureUIKitAdapter/UIKitMetalGridGlyphRasterizer.swift: must not import \(forbidden)")
        }

        let source = try String(contentsOf: adapterFile, encoding: .utf8)
        for symbol in [
            "#if canImport(UIKit)",
            "package final class UIKitMetalGridGlyphRasterizer",
            "MetalGridGlyphRasterizing",
            "UIImage.SymbolConfiguration",
            "UIImage(systemName:",
            "UIGraphicsImageRenderer",
            "image.cgImage"
        ] where !source.contains(symbol) {
            violations.append("MetalGridTextureUIKitAdapter/UIKitMetalGridGlyphRasterizer.swift: missing \(symbol)")
        }

        for file in try swiftFiles(in: textureRoot) {
            let textureSource = try String(contentsOf: file, encoding: .utf8)
            let code = stripCommentsAndStringLiterals(from: textureSource)
            for token in ["UIKitMetalGridGlyphRasterizer", "UIImage", "UIColor", "UIGraphicsImageRenderer"] where contains(token, in: code) {
                violations.append("MetalGridTextureCore/\(file.lastPathComponent): UIKit adapter leaked into texture core via \(token)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Phase 5.2 UIKit glyph adapter boundary regressed:
            \(violations.joined(separator: "\n"))

            UIKit SF Symbol rasterization belongs in an iOS/iPadOS adapter target. MetalGridTextureCore owns
            only the shared cache and glyph request contract.
            """
        )
    }

    func testUIKitTextureBudgetsStayAdapterOwnedAndConservative() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let adapterRoot = sourcesRoot.appendingPathComponent("MetalGridTextureUIKitAdapter")
        let policyFile = adapterRoot.appendingPathComponent("UIKitMetalGridTexturePolicy.swift")
        let timelineTypesFile = sourcesRoot
            .appendingPathComponent("TimelineFeature")
            .appendingPathComponent("MetalGridTypes.swift")
        var violations: [String] = []

        if let targetLine = manifestLine(forTarget: "MetalGridTextureUIKitAdapter", in: manifest) {
            let dependencies = Set(dependencies(inTargetLine: targetLine))
            if dependencies != ["GridCore", "MetalGridTextureCore"] {
                violations.append("MetalGridTextureUIKitAdapter: dependencies \(dependencies.sorted()) != [GridCore, MetalGridTextureCore]")
            }
        } else {
            violations.append("MetalGridTextureUIKitAdapter: missing Package.swift target declaration")
        }

        guard FileManager.default.fileExists(atPath: policyFile.path) else {
            XCTFail("MetalGridTextureUIKitAdapter/UIKitMetalGridTexturePolicy.swift: missing UIKit texture budget policy")
            return
        }

        let imports = try importedModules(in: policyFile)
        if imports != ["CoreGraphics", "GridCore"] {
            violations.append("MetalGridTextureUIKitAdapter/UIKitMetalGridTexturePolicy.swift: imports \(imports.sorted()) != [CoreGraphics, GridCore]")
        }

        let source = try String(contentsOf: policyFile, encoding: .utf8)
        let code = stripCommentsAndStringLiterals(from: source)
        for symbol in [
            "UIKitMetalGridTextureSurfaceClass",
            "resolving(viewportSize:",
            "UIKitMetalGridTexturePolicy",
            "UIKitMetalGridTexturePolicies",
            "GridTextureBudget",
            "maxTexturePixels"
        ] where !code.contains(symbol) {
            violations.append("MetalGridTextureUIKitAdapter/UIKitMetalGridTexturePolicy.swift: missing \(symbol)")
        }
        for forbidden in ["ProcessInfo.processInfo.physicalMemory", "activeProcessorCount", "UIDevice", "userInterfaceIdiom", "MetalGridBudget.default"] where code.contains(forbidden) {
            violations.append("MetalGridTextureUIKitAdapter/UIKitMetalGridTexturePolicy.swift: budget policy must be viewport/capability injected, found \(forbidden)")
        }
        for macValue in [
            "maxUploadsPerFrame: 96",
            "maxCachedTextures: 4096",
            "overscanFraction: 1.2",
            "maxTexturePixels: 320"
        ] where source.contains(macValue) {
            violations.append("MetalGridTextureUIKitAdapter/UIKitMetalGridTexturePolicy.swift: UIKit policy must not copy macOS default \(macValue)")
        }

        let timelineSource = try String(contentsOf: timelineTypesFile, encoding: .utf8)
        if timelineSource.contains("static let `default` = GridTextureBudget(") {
            violations.append("TimelineFeature/MetalGridTypes.swift: macOS default budget belongs in MetalGridTextureAppKitAdapter")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Phase 5.3 UIKit texture budget boundary regressed:
            \(violations.joined(separator: "\n"))

            iOS/iPadOS texture budgets must stay in the UIKit adapter and must not inherit aggressive macOS
            cache/upload defaults.
            """
        )
    }

    func testUIKitTextureCacheFactoryUsesSharedTextureCore() throws {
        let adapterRoot = sourcesRoot.appendingPathComponent("MetalGridTextureUIKitAdapter")
        let factoryFile = adapterRoot.appendingPathComponent("UIKitMetalGridTextureCacheFactory.swift")
        var violations: [String] = []

        guard FileManager.default.fileExists(atPath: factoryFile.path) else {
            XCTFail("MetalGridTextureUIKitAdapter/UIKitMetalGridTextureCacheFactory.swift: missing UIKit cache factory")
            return
        }

        let imports = try importedModules(in: factoryFile)
        let expectedImports: Set<String> = ["CoreGraphics", "Metal", "MetalGridTextureCore"]
        if imports != expectedImports {
            violations.append("MetalGridTextureUIKitAdapter/UIKitMetalGridTextureCacheFactory.swift: imports \(imports.sorted()) != \(expectedImports.sorted())")
        }
        for forbidden in ["AppKit", "SwiftUI", "MetalKit", "PhotosCore", "MediaCache", "TimelineFeature"] where imports.contains(forbidden) {
            violations.append("MetalGridTextureUIKitAdapter/UIKitMetalGridTextureCacheFactory.swift: must not import \(forbidden)")
        }

        let source = try String(contentsOf: factoryFile, encoding: .utf8)
        let code = stripCommentsAndStringLiterals(from: source)
        for symbol in [
            "#if canImport(UIKit)",
            "UIKitMetalGridTextureCacheFactory",
            "makeCache<ID: Hashable & Sendable>",
            "MetalGridTextureCache<ID>",
            "UIKitMetalGridTexturePolicy",
            "UIKitMetalGridTexturePolicies.policy(forViewportSize:",
            "UIKitMetalGridGlyphRasterizer()",
            "budget: policy.budget",
            "maxTexturePixels: policy.maxTexturePixels"
        ] where !source.contains(symbol) {
            violations.append("MetalGridTextureUIKitAdapter/UIKitMetalGridTextureCacheFactory.swift: missing \(symbol)")
        }
        for forbidden in ["PhotoUID", "PhotoItem", "MetalGridBudget.default", "GridTextureBudget(", "maxUploadsPerFrame:", "maxCachedTextures:"] where contains(forbidden, in: code) {
            violations.append("MetalGridTextureUIKitAdapter/UIKitMetalGridTextureCacheFactory.swift: factory must use injected UIKit policy and generic IDs, found \(forbidden)")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Phase 5.4 UIKit texture cache factory boundary regressed:
            \(violations.joined(separator: "\n"))

            The iOS/iPadOS adapter may assemble the shared cache from a platform policy and glyph rasterizer,
            but it must not fork cache logic or bind photo-domain IDs.
            """
        )
    }

    func testMetalGridTextureCacheStaysItemIDGeneric() throws {
        let textureRoot = sourcesRoot.appendingPathComponent("MetalGridTextureCore")
        let timelineRoot = sourcesRoot.appendingPathComponent("TimelineFeature")
        let cacheFile = textureRoot.appendingPathComponent("MetalGridTextureCache.swift")
        let coordinatorFile = timelineRoot.appendingPathComponent("MetalGridCoordinator.swift")
        var violations: [String] = []

        guard FileManager.default.fileExists(atPath: cacheFile.path) else {
            XCTFail("MetalGridTextureCore/MetalGridTextureCache.swift: missing texture cache")
            return
        }

        let imports = try importedModules(in: cacheFile)
        for forbidden in ["PhotosCore", "AppKit", "UIKit", "SwiftUI", "MetalKit"] where imports.contains(forbidden) {
            violations.append("MetalGridTextureCore/MetalGridTextureCache.swift: cache must not import \(forbidden)")
        }

        let source = try String(contentsOf: cacheFile, encoding: .utf8)
        let code = stripCommentsAndStringLiterals(from: source)
        for forbidden in ["PhotoUID", "PhotoItem", "PhotosCore"] where contains(forbidden, in: code) {
            violations.append("MetalGridTextureCore/MetalGridTextureCache.swift: cache must stay item-ID generic; found \(forbidden)")
        }
        if !source.contains("package final class MetalGridTextureCache<ID: Hashable & Sendable>") {
            violations.append("MetalGridTextureCore/MetalGridTextureCache.swift: cache must be package-visible and generic over a sendable hashable item ID")
        }
        if !source.contains("GridTextureResidencyPolicy<ID>") || !source.contains("[ID: MTLTexture]") {
            violations.append("MetalGridTextureCore/MetalGridTextureCache.swift: cache storage and residency policy must use the generic ID")
        }
        if !source.contains("func uploadVisible(wanted: [ID], provideImage: (ID) -> CGImage?)") {
            violations.append("MetalGridTextureCore/MetalGridTextureCache.swift: upload seam must not re-specialize to a photo-domain ID")
        }
        if FileManager.default.fileExists(atPath: timelineRoot.appendingPathComponent("MetalGridTextureCache.swift").path) {
            violations.append("TimelineFeature/MetalGridTextureCache.swift: shared generic cache belongs in MetalGridTextureCore")
        }
        if FileManager.default.fileExists(atPath: timelineRoot.appendingPathComponent("MetalGridGlyphRasterizer.swift").path) {
            violations.append("TimelineFeature/MetalGridGlyphRasterizer.swift: shared glyph contract belongs in MetalGridTextureCore")
        }

        guard FileManager.default.fileExists(atPath: coordinatorFile.path) else {
            violations.append("TimelineFeature/MetalGridCoordinator.swift: missing macOS cache binding")
            return
        }
        let coordinator = try String(contentsOf: coordinatorFile, encoding: .utf8)
        if !coordinator.contains("MetalGridTextureCache<PhotoUID>") {
            violations.append("TimelineFeature/MetalGridCoordinator.swift: macOS adapter must bind the generic cache to PhotoUID explicitly")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Phase 4.8 texture-cache ID boundary regressed:
            \(violations.joined(separator: "\n"))

            Real Metal texture caching may remain adapter-owned, but item identity must be generic so the
            same cache implementation can be reused by iOS/iPadOS adapters with their own platform bindings.
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
