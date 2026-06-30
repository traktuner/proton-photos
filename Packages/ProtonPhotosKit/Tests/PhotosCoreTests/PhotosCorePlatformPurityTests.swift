import XCTest

/// Architectural guard tests that enforce the platform purity of `PhotosCore`.
///
/// `PhotosCore` MUST remain free of platform UI frameworks (AppKit, UIKit, SwiftUI,
/// AVKit, MetalKit view-hosting) and MUST NOT expose platform UI types (`NSImage`,
/// `UIImage`, `NSView`, `UIView`, `NSWorkspace`, `NSOpenPanel`, `UIApplication`,
/// `NSApplication`) in its public API surface. This keeps the target compilable and
/// consumable on macOS 26+, iOS 26+, and iPadOS 26+ without dragging in UI
/// dependencies.
///
/// These tests scan the source tree deterministically (via `#filePath`) so they
/// regress loudly the moment a forbidden import or token is introduced. They do
/// NOT modify any source file. `Foundation`, `CoreGraphics` (value types), and
/// `AVFoundation` (cross-platform media, not UI) are intentionally permitted.
final class PhotosCorePlatformPurityTests: XCTestCase {

    // MARK: Paths (via #filePath → up 3 = Packages/ProtonPhotosKit/)

    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private var photosCoreSources: URL {
        packageRoot.appendingPathComponent("Sources/PhotosCore")
    }

    // MARK: Helpers

    /// Recursively collects every `.swift` file under the given directory.
    private func swiftFiles(in directory: URL) throws -> [URL] {
        var results: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        guard let enumerator else { return [] }
        for case let url as URL in enumerator {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
               url.pathExtension == "swift" {
                results.append(url)
            }
        }
        return results.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }

    /// Reads the contents of a file as UTF-8 text.
    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Forbidden import scan

    /// Frameworks whose import would drag in platform UI / view-hosting concerns
    /// and break the universal-Core contract.
    private static let forbiddenFrameworkImports: [String] = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "AVKit",
        "MetalKit",
    ]

    func testNoForbiddenFrameworkImports() throws {
        let files = try swiftFiles(in: photosCoreSources)
        XCTAssertFalse(files.isEmpty, "Expected to find .swift files under \(photosCoreSources.path)")

        var violations: [String] = []
        for file in files {
            let source = try contents(of: file)
            for line in source.split(whereSeparator: { $0.isNewline }) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                for framework in Self.forbiddenFrameworkImports {
                    if trimmed.range(of: "\\b\(framework)\\b", options: .regularExpression) != nil {
                        violations.append("\(file.lastPathComponent): \(trimmed)")
                    }
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            PhotosCore must not import platform UI frameworks. Found forbidden imports:
            \(violations.joined(separator: "\n"))

            Allowed imports: Foundation, CoreGraphics (value types), AVFoundation \
            (cross-platform media). UI frameworks belong in Platform UI targets, not Core.
            """
        )
    }

    // MARK: Forbidden public-API token scan

    /// Tokens whose appearance anywhere in PhotosCore source would indicate a leaked
    /// platform UI type. Word-boundary matched to avoid false positives on substrings.
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

    func testNoForbiddenPublicAPITokens() throws {
        let files = try swiftFiles(in: photosCoreSources)
        XCTAssertFalse(files.isEmpty, "Expected to find .swift files under \(photosCoreSources.path)")

        var violations: [String] = []
        for file in files {
            let source = try contents(of: file)
            for token in Self.forbiddenTokens {
                let pattern = "\\b\(token)\\b"
                let range = NSRange(source.startIndex..., in: source)
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                regex.enumerateMatches(in: source, range: range) { match, _, _ in
                    guard let match else { return }
                    if let matchRange = Range(match.range, in: source) {
                        let line = source.lineNumber(for: matchRange.lowerBound)
                        violations.append("\(file.lastPathComponent):\(line) → \(token)")
                    }
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            PhotosCore must not reference platform UI types. Found forbidden tokens:
            \(violations.joined(separator: "\n"))

            These types belong in Platform UI targets (AppKit/UIKit bridges), not in \
            the universal Core layer.
            """
        )
    }

    // MARK: Allowed-import sanity (positive signal, not a purity check)

    /// Confirms the only frameworks imported by PhotosCore are the cross-platform
    /// allowlist: Foundation, CoreGraphics, AVFoundation. A new import here is a
    /// review trigger — the change should be intentional and documented.
    private static let allowedFrameworkImports: Set<String> = [
        "Foundation",
        "CoreGraphics",
        "AVFoundation",
    ]

    func testImportedFrameworksAreOnAllowlist() throws {
        let files = try swiftFiles(in: photosCoreSources)
        XCTAssertFalse(files.isEmpty, "Expected to find .swift files under \(photosCoreSources.path)")

        var seen: Set<String> = []
        for file in files {
            let source = try contents(of: file)
            for line in source.split(whereSeparator: { $0.isNewline }) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                // Strip `import ` prefix and any trailing attributes/module refs.
                let remainder = trimmed.dropFirst("import ".count)
                let moduleName = remainder.split(separator: " ").first.map(String.init) ?? String(remainder)
                seen.insert(moduleName)
            }
        }

        let unexpected = seen.subtracting(Self.allowedFrameworkImports)
        XCTAssertTrue(
            unexpected.isEmpty,
            """
            PhotosCore imports frameworks outside the cross-platform allowlist:
            \(unexpected.sorted().joined(separator: ", "))

            Allowed: Foundation, CoreGraphics, AVFoundation. Adding a new import \
            requires updating PhotosCorePlatformPurityTests.allowList AND confirming \
            the framework compiles on macOS 26+, iOS 26+, and iPadOS 26+.
            """
        )
    }
}

// MARK: - Line-number helper

private extension String {
    /// Returns the 1-based line number for the given character index.
    func lineNumber(for index: Index) -> Int {
        var line = 1
        var current = startIndex
        while current < index {
            if self[current] == "\n" { line += 1 }
            current = self.index(after: current)
        }
        return line
    }
}
