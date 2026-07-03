import XCTest

/// Guards for the cleanup pass: prove the removed private-API experiment stays gone and the production
/// app source contains no private Apple API usage. These read the real source tree (located via
/// `#filePath`), so they fail CI if the experiment is reintroduced.
final class ProjectHygieneTests: XCTestCase {

    /// Repo root, derived from this file's location:
    /// …/Packages/ProtonPhotosKit/Tests/UploadFeatureTests/ProjectHygieneTests.swift  → up 5.
    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private var appDir: URL { repoRoot.appendingPathComponent("App") }
    private var mobileAppDir: URL { repoRoot.appendingPathComponent("iOSApp") }

    private func appSourceFiles() -> [URL] {
        sourceFiles(in: appDir)
    }

    private func mobileAppSourceFiles() -> [URL] {
        sourceFiles(in: mobileAppDir)
    }

    private func sourceFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { ["swift", "m", "h", "mm"].contains($0.pathExtension.lowercased()) }
    }

    private func targetBlock(named target: String, in projectYML: String) -> String {
        guard let start = projectYML.range(of: "  \(target):")?.lowerBound else { return "" }
        let tail = projectYML[start...]
        guard let next = tail.range(of: "\n  [A-Za-z0-9_]+:", options: .regularExpression)?.lowerBound,
              next != tail.startIndex else {
            return String(tail)
        }
        return String(tail[..<next])
    }

    // 11. CleanupSafetyTest - the excluded/deleted experiment is gone and unreferenced.
    func testPrivateAppleGridExperimentRemoved() {
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: appDir.appendingPathComponent("PrivateAppleGrid").path),
                       "App/PrivateAppleGrid should be deleted")
        XCTAssertFalse(fm.fileExists(atPath: appDir.appendingPathComponent("ProtonPhotos-Bridging-Header.h").path),
                       "the Obj-C bridging header should be deleted")

        for url in appSourceFiles() {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            XCTAssertFalse(text.contains("PrivateAppleGrid"),
                           "\(url.lastPathComponent) still references the removed experiment")
            XCTAssertFalse(text.contains("ProtonPhotos-Bridging-Header"),
                           "\(url.lastPathComponent) still references the removed bridging header")
        }

        // The build manifest must no longer exclude (or reference) the removed files.
        let projectYML = (try? String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)) ?? ""
        XCTAssertFalse(projectYML.contains("PrivateAppleGrid"))
        XCTAssertFalse(projectYML.contains("Bridging-Header"))
    }

    // 12. PrivateAPISafetyTest - production app target uses no known private Apple API / frameworks.
    func testNoPrivateAppleAPIInProductionTarget() {
        let banned = ["PPApplePrivate", "loadPrivateFrameworks", "filterWithType:", "CAFilterClassNames"]
        for url in appSourceFiles() {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for marker in banned {
                XCTAssertFalse(text.contains(marker),
                               "\(url.lastPathComponent) contains private-API marker “\(marker)”")
            }
        }
    }

    func testMobileShellTargetStaysUniversalAndUIKitOnly() {
        let projectYML = (try? String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)) ?? ""
        let mobileTarget = targetBlock(named: "ProtonPhotosMobile", in: projectYML)
        XCTAssertFalse(mobileTarget.isEmpty, "project.yml must define the ProtonPhotosMobile iOS shell target")

        for required in [
            "platform: iOS",
            "deploymentTarget: \"26.0\"",
            "TARGETED_DEVICE_FAMILY: \"1,2\"",
            "product: PhotosCore",
            "product: ProtonAuth",
            "product: TimelineUIKitAdapter",
            "product: TimelineUIKitFeature",
            "product: MediaCacheUIKitAdapter",
            "product: MetalGridTextureUIKitAdapter",
            "product: AlbumsFeature",
            "product: PhotoViewerCore",
            "product: PhotoViewerUIKitAdapter",
            "product: MapUIKitAdapter",
            "product: UploadCore",
            "product: UploadFeature"
        ] {
            XCTAssertTrue(mobileTarget.contains(required), "ProtonPhotosMobile target missing \(required)")
        }

        for forbidden in [
            "product: DesignSystem\n",
            "product: MediaCache\n",
            "product: TimelineFeature",
            "product: PhotoViewerFeature",
            "product: MapFeature",
            "product: ProtonDriveSDK"
        ] {
            XCTAssertFalse(mobileTarget.contains(forbidden), "iOS shell must not depend on \(forbidden)")
        }

        for url in mobileAppSourceFiles() {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let importLines = Set(
                text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("import ") }
            )
            for forbidden in [
                "import AppKit",
                "import TimelineFeature",
                "import PhotoViewerFeature",
                "import MapFeature",
                "NSView",
                "NSImage",
                "NSScrollView"
            ] {
                XCTAssertFalse(text.contains(forbidden), "\(url.lastPathComponent) leaks macOS feature/API \(forbidden)")
            }
            XCTAssertFalse(
                importLines.contains("import MediaCache"),
                "\(url.lastPathComponent) leaks macOS feature/API import MediaCache"
            )
        }

        let verifyScript = repoRoot.appendingPathComponent("scripts/verify-ios-app-shell.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: verifyScript.path), "iOS app shell build gate script is required")
        let rebuild = (try? String(contentsOf: repoRoot.appendingPathComponent("scripts/rebuild.sh"), encoding: .utf8)) ?? ""
        XCTAssertTrue(rebuild.contains("verify-ios-app-shell.sh"), "rebuild.sh must run the iOS app shell gate")
    }

    func testPlatformAppsUseSharedAuthLifecycleController() {
        let appModel = (try? String(
            contentsOf: repoRoot.appendingPathComponent("App/AppModel.swift"),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(appModel.contains("ProtonAuthController"), "macOS app must compose the shared auth lifecycle")
        XCTAssertFalse(
            appModel.contains("ProtonForkAuthenticator()"),
            "macOS app must not instantiate the concrete fork authenticator directly"
        )
        XCTAssertTrue(
            appModel.contains("ProtonForkAuthenticator(config: .externalDriveProtonPhotos)"),
            "macOS app must inject the documented Proton API client identity explicitly"
        )

        for url in mobileAppSourceFiles() {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            XCTAssertFalse(
                text.contains("ProtonForkAuthenticator()"),
                "\(url.lastPathComponent) must not instantiate the concrete fork authenticator directly"
            )
        }
        let mobileShell = mobileAppSourceFiles()
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertTrue(mobileShell.contains("ProtonAuthController"), "iOS app must compose the shared auth lifecycle")
        XCTAssertTrue(
            mobileShell.contains("ProtonForkAuthenticator(config: .externalDriveProtonPhotos)"),
            "iOS app must inject the documented Proton API client identity explicitly"
        )
    }
}
