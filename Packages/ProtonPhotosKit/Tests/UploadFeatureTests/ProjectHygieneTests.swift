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

    private func appSourceFiles() -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: appDir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { ["swift", "m", "h", "mm"].contains($0.pathExtension.lowercased()) }
    }

    // 11. CleanupSafetyTest — the excluded/deleted experiment is gone and unreferenced.
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

    // 12. PrivateAPISafetyTest — production app target uses no known private Apple API / frameworks.
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
}
