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
    private var uploadCoreDir: URL {
        repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/UploadCore")
    }

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
            "product: ProtonDriveBackend",
            "product: TimelineUIKitAdapter",
            "product: TimelineUIKitFeature",
            "product: MediaCacheUIKitAdapter",
            "product: MediaCacheCore",
            "product: MetalGridTextureUIKitAdapter",
            "product: AlbumsFeature",
            "product: PhotoViewerCore",
            "product: PhotoViewerUIKitAdapter",
            "product: MapUIKitAdapter",
            "product: UploadCore",
            "product: UploadFeature",
            "product: PhotoLibraryBackupAdapter"
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

        let mobileShell = mobileAppSourceFiles()
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertTrue(
            mobileShell.contains("import MediaCacheCore"),
            "iOS app must import the shared thumbnail crawl policy module"
        )
        XCTAssertTrue(
            mobileShell.contains("ThumbnailCrawlOrder.newestToOldest(items)"),
            "iOS app must crawl thumbnails newest-to-oldest like macOS"
        )
        XCTAssertFalse(
            mobileShell.contains("feed.startPrefetch(items.map(\\.uid))"),
            "iOS app must not crawl thumbnails in raw timeline order"
        )
    }

    func testMobileShellUsesAdaptiveIPadSidebarWithoutFeatureForking() throws {
        let mobileApp = try String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/ProtonPhotosMobileApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            mobileApp.contains("@Environment(\\.horizontalSizeClass)"),
            "mobile navigation must adapt from size class, not fixed device assumptions"
        )
        XCTAssertTrue(
            mobileApp.contains("MobilePhoneTabShell(selection: $selection)") &&
            mobileApp.contains("MobilePadSidebarShell(selection: $selection)"),
            "iPhone and iPad shells must share one route selection state"
        )
        XCTAssertTrue(
            mobileApp.contains("NavigationSplitView(columnVisibility: $columnVisibility)"),
            "iPadOS regular-width shell must use the native split-view sidebar"
        )
        XCTAssertTrue(
            mobileApp.contains(".navigationSplitViewColumnWidth(") &&
            mobileApp.contains("SidebarMetrics.minWidth") &&
            mobileApp.contains("SidebarMetrics.maxWidth"),
            "iPad sidebar width policy must use shared sidebar metrics"
        )
        XCTAssertTrue(
            mobileApp.contains("private struct MobileRouteScreen: View"),
            "feature screens must be routed through one shared mobile route surface"
        )
        XCTAssertTrue(
            // Prefix match (no closing paren) so the shared screen may take extra pass-through inputs - e.g.
            // the Fotos-tab-retap `scrollToLatestSignal` - without forking the iPad route to a different screen.
            mobileApp.contains("MobileTimelineScreen(isActive: isPhotosActive") &&
            mobileApp.contains("MobileCollectionsScreen()") &&
            mobileApp.contains("MobileMapScreen()") &&
            mobileApp.contains("MobileSettingsScreen()"),
            "iPadOS must reuse the same platform-shared feature screens as iPhone"
        )
        XCTAssertFalse(
            mobileApp.contains(".tabViewStyle(.sidebarAdaptable)"),
            "iPadOS sidebar must not depend on TabView's adaptive promotion"
        )
        XCTAssertFalse(
            mobileApp.contains("Image(systemName: \"sidebar.left\")"),
            """
            iPad detail must not add a manual sidebar toggle on top of NavigationSplitView's built-in
            control — that produced the duplicate landscape toggle. Rely on the single native control.
            """
        )
    }

    func testPlatformAppsUseSharedProtonDriveBackend() {
        let projectYML = (try? String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)) ?? ""
        let macTarget = targetBlock(named: "ProtonPhotos", in: projectYML)
        let mobileTarget = targetBlock(named: "ProtonPhotosMobile", in: projectYML)
        XCTAssertTrue(macTarget.contains("product: ProtonDriveBackend"), "macOS app must use the shared Proton backend product")
        XCTAssertTrue(mobileTarget.contains("product: ProtonDriveBackend"), "iOS app must use the shared Proton backend product")
        XCTAssertFalse(macTarget.contains("product: ProtonDriveSDK"), "macOS app must not wire the Drive SDK directly")
        XCTAssertFalse(mobileTarget.contains("product: ProtonDriveSDK"), "iOS app must not wire the Drive SDK directly")

        let manifest = (try? String(
            contentsOf: repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Package.swift"),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(
            manifest.contains(".library(name: \"ProtonDriveBackend\", targets: [\"ProtonDriveBackend\"])"),
            "ProtonDriveBackend must be a shared package product"
        )
        XCTAssertTrue(
            manifest.contains(".product(name: \"ProtonDriveSDK\", package: \"ProtonDriveSDK\")"),
            "Only the shared backend package target should depend on ProtonDriveSDK"
        )

        for url in appSourceFiles() + mobileAppSourceFiles() {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            XCTAssertFalse(text.contains("import ProtonDriveSDK"), "\(url.lastPathComponent) must not import ProtonDriveSDK")
            XCTAssertFalse(text.contains("DriveSDKBridge("), "\(url.lastPathComponent) must not instantiate the SDK bridge directly")
            XCTAssertFalse(text.contains("MobileSyntheticThumbnailLoader"), "\(url.lastPathComponent) must not use fake mobile thumbnails")
            XCTAssertFalse(text.contains("demoItems"), "\(url.lastPathComponent) must not use fake mobile timeline items")
        }

        let appSwiftFiles = appSourceFiles().map(\.path)
        XCTAssertFalse(
            appSwiftFiles.contains { $0.contains("/App/Drive/") },
            "SDK/HTTP backend Swift files must live in ProtonDriveBackend, not App/Drive"
        )
    }

    func testPhotoLibraryBackupAdapterStaysUIAndSDKFree() {
        let adapterDir = repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/PhotoLibraryBackupAdapter")
        let files = sourceFiles(in: adapterDir)
        XCTAssertFalse(files.isEmpty, "the PhotoKit adapter target must exist")
        for url in files {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let importLines = Set(
                text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("import ") }
            )
            // Photos IS this target's purpose; UI frameworks, OS scheduling, and the SDK are not.
            for forbidden in [
                "import UIKit",
                "import AppKit",
                "import SwiftUI",
                "import BackgroundTasks",
                "import ProtonDriveSDK",
                "import ProtonCore"
            ] {
                XCTAssertFalse(importLines.contains(forbidden),
                               "\(url.lastPathComponent) must keep \(forbidden) out of the shared PhotoKit adapter")
            }
        }
    }

    func testAlbumSyncCoreStaysPureSwift() {
        let coreDir = repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/AlbumSyncCore")
        let files = sourceFiles(in: coreDir)
        XCTAssertFalse(files.isEmpty, "the AlbumSyncCore target must exist")
        for url in files {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let importLines = Set(
                text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("import ") }
            )
            // The sync engine is universal: platform frameworks, PhotoKit, and the SDK live in
            // adapters only.
            for forbidden in [
                "import UIKit",
                "import AppKit",
                "import SwiftUI",
                "import Photos",
                "import PhotosUI",
                "import BackgroundTasks",
                "import ProtonDriveSDK",
                "import ProtonCore"
            ] {
                XCTAssertFalse(importLines.contains(forbidden),
                               "\(url.lastPathComponent) must keep \(forbidden) out of AlbumSyncCore")
            }
        }
    }

    func testAlbumSyncRefreshAndChangeObservationStayShared() throws {
        let controller = try String(
            contentsOf: repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/PhotoLibraryBackupAdapter/AlbumSyncController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(controller.contains("private let changeMonitor: PhotoLibraryChangeMonitor"))
        XCTAssertTrue(controller.contains("changeMonitor.startObserving"))
        XCTAssertTrue(controller.contains("scheduleChangeDrivenSync()"))
        XCTAssertTrue(controller.contains("syncSelected()"))
        XCTAssertTrue(controller.contains("setRemoteAlbumsChangedHandler"))
        XCTAssertTrue(controller.contains("onRemoteAlbumsChanged?()"))

        let appModel = try String(contentsOf: repoRoot.appendingPathComponent("App/AppModel.swift"), encoding: .utf8)
        XCTAssertTrue(appModel.contains("private(set) var albumCatalogRevision"))
        XCTAssertTrue(appModel.contains("albumSync.setRemoteAlbumsChangedHandler"))

        let mainView = try String(contentsOf: repoRoot.appendingPathComponent("App/Views/MainView.swift"), encoding: .utf8)
        XCTAssertTrue(mainView.contains(".task(id: model.albumCatalogRevision) { await loadAlbums() }"))

        let mobileModel = try String(contentsOf: repoRoot.appendingPathComponent("iOSApp/MobileLibraryModel.swift"), encoding: .utf8)
        XCTAssertTrue(mobileModel.contains("private(set) var albumCatalogRevision"))
        XCTAssertTrue(mobileModel.contains("albumSync.setRemoteAlbumsChangedHandler"))

        let mobileAlbums = try String(contentsOf: repoRoot.appendingPathComponent("iOSApp/MobileAlbumsScreen.swift"), encoding: .utf8)
        XCTAssertTrue(mobileAlbums.contains("AlbumsReloadKey(backendReady: model.backend != nil, revision: model.albumCatalogRevision)"))
    }

    func testPhotoBackupIdempotencyGuardsStayLoadBearing() throws {
        let monitor = try String(
            contentsOf: repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/PhotoLibraryBackupAdapter/PhotoLibraryChangeMonitor.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(monitor.contains("public func prepareChanges() -> PreparedChangeSet"))
        XCTAssertTrue(monitor.contains("public func commit(_ prepared: PreparedChangeSet)"))
        XCTAssertFalse(monitor.contains("func consumeChanges()"),
                       "PhotoKit change tokens must never be consumed before scan/enqueue durability is proven")

        let controller = try String(
            contentsOf: repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/PhotoLibraryBackupAdapter/PhotoLibraryBackupController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(controller.contains("let preparedChanges = monitor.prepareChanges()"))
        XCTAssertTrue(controller.contains("monitor.commit(preparedChanges)"))
        XCTAssertTrue(controller.contains("L10n.string(\"backup.error_execution_lock_unavailable\")"))
        XCTAssertFalse(controller.contains("degrade to unlocked"),
                       "execution-lock failure must be fail-closed, not best-effort")
        XCTAssertTrue(controller.contains("changes.changedIdentifiers + changes.deletedIdentifiers"),
                      "targeted PhotoKit changes must include deletes so the catalog cannot stay stale")
        XCTAssertTrue(controller.contains("pendingSyncAfterStop = true"),
                      "re-enabling after disabling during a stop must schedule a fresh pass instead of inheriting pause")
        XCTAssertTrue(controller.contains("monitor.stopObserving()"),
                      "disabling photo backup must tear down live change observation")
        XCTAssertTrue(controller.contains("if shouldRestart { syncNow() }"),
                      "the queued re-enable pass must run after the previous stop fully settles")

        let runner = try String(
            contentsOf: repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/UploadCore/Backup/BackupSyncRunner.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(runner.contains("queue.claimRunnable(limit: claimLimit"),
                      "drainers must atomically reserve rows in Core before processing")
        XCTAssertFalse(runner.contains("queue.nextRunnable(limit: configuration.batchSize)"),
                       "the runner must not drain from a read-only runnable query")
    }

    /// GPL-contamination guard: the Proton Drive iOS app (GPL-3.0) may be consulted as a
    /// BEHAVIORAL reference only. Its distinctive type/module names must never appear in our
    /// production sources - their presence would indicate copied code rather than clean-room work.
    func testNoGPLProtonDriveSymbolsInProductionSources() {
        let productionDirs = [
            "App", "iOSApp", "Packages/ProtonPhotosKit/Sources",
        ].map { repoRoot.appendingPathComponent($0) }
        let gplMarkers = [
            "PDCore", "PDPhotos", "PDClient", "PDUploadVerifier",
            "CreateAlbumInteractor", "AddPhotosToOwnAlbumInteractor",
            "NodeHashKeyDecryption", "SignersKit", "CloudSlot",
        ]
        for dir in productionDirs {
            for url in sourceFiles(in: dir) {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                for marker in gplMarkers {
                    XCTAssertFalse(
                        text.contains(marker),
                        "\(url.lastPathComponent) contains GPL Proton Drive symbol '\(marker)' - production code must stay clean-room"
                    )
                }
            }
        }
    }

    func testPhotoBackupPermissionAndBackgroundDeclarations() throws {
        // iOS: usage description + BG processing declarations must stay consistent with the
        // registered task identifier.
        let infoData = try Data(contentsOf: repoRoot.appendingPathComponent("iOSApp/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        )
        XCTAssertNotNil(info["NSPhotoLibraryUsageDescription"],
                        "photo backup needs a usage description on iOS")
        let identifiers = try XCTUnwrap(info["BGTaskSchedulerPermittedIdentifiers"] as? [String])
        XCTAssertTrue(identifiers.contains("me.protonphotos.ios.photo-backup.processing"))
        let modes = try XCTUnwrap(info["UIBackgroundModes"] as? [String])
        XCTAssertTrue(modes.contains("processing"))
        XCTAssertFalse(modes.contains("audio") || modes.contains("location") || modes.contains("voip"),
                       "no keep-alive background-mode abuse")

        let mobileApp = (try? String(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/ProtonPhotosMobileApp.swift"),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(mobileApp.contains("me.protonphotos.ios.photo-backup.processing"),
                      "the registered BG task identifier must match Info.plist")

        // macOS: usage description via project.yml.
        let projectYML = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(projectYML.contains("INFOPLIST_KEY_NSPhotoLibraryUsageDescription"),
                      "photo backup needs a usage description on macOS")
    }

    func testMobileAppStoreDeviceCapabilitiesDeclareRendererFloor() throws {
        let infoData = try Data(contentsOf: repoRoot.appendingPathComponent("iOSApp/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        )
        let capabilities = try XCTUnwrap(info["UIRequiredDeviceCapabilities"] as? [String])

        XCTAssertTrue(capabilities.contains("arm64"))
        XCTAssertTrue(capabilities.contains("metal"))
        XCTAssertTrue(
            capabilities.contains("iphone-ipad-minimum-performance-a12"),
            "App Store distribution must exclude devices below the shared mobile renderer floor"
        )
    }

    func testUploadCoreStaysPlatformAndSDKAgnostic() {
        for url in sourceFiles(in: uploadCoreDir) {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let importLines = Set(
                text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("import ") }
            )
            for forbidden in [
                "import AppKit",
                "import UIKit",
                "import Photos",
                "import PhotosUI",
                "import BackgroundTasks",
                "import ProtonDriveSDK",
                "import ProtonCore"
            ] {
                XCTAssertFalse(importLines.contains(forbidden), "\(url.lastPathComponent) must keep platform/API adapters out of UploadCore")
            }
        }
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

    func testMacAppEntitlementsStaySandboxedAndMinimal() throws {
        let entitlementsURL = repoRoot.appendingPathComponent("App/ProtonPhotos.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            "macOS entitlements must remain a dictionary plist"
        )

        for required in [
            "com.apple.security.app-sandbox",
            "com.apple.security.network.client",
            "com.apple.security.files.user-selected.read-write",
            // Folder backup persists the user's chosen folders as security-scoped bookmarks.
            "com.apple.security.files.bookmarks.app-scope",
            // Photos-library backup reads originals through PhotoKit.
            "com.apple.security.personal-information.photos-library"
        ] {
            XCTAssertEqual(plist[required] as? Bool, true, "missing required entitlement \(required)")
        }

        for forbidden in [
            "com.apple.security.cs.disable-library-validation",
            "com.apple.security.cs.allow-unsigned-executable-memory",
            "com.apple.security.cs.allow-jit",
            "com.apple.security.files.downloads.read-write",
            "com.apple.security.files.pictures.read-write",
            "com.apple.security.temporary-exception.files.absolute-path.read-write",
            "com.apple.security.temporary-exception.files.home-relative-path.read-write"
        ] {
            XCTAssertNil(plist[forbidden], "entitlement \(forbidden) must not be present without a documented need")
        }
    }

    func testPlatformAppsShipPrivacyManifestsForRequiredReasonAPIs() throws {
        for relativePath in ["App/PrivacyInfo.xcprivacy", "iOSApp/PrivacyInfo.xcprivacy"] {
            let url = repoRoot.appendingPathComponent(relativePath)
            let data = try Data(contentsOf: url)
            let plist = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                "\(relativePath) must be a dictionary plist"
            )

            XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false, "\(relativePath) must not declare tracking")
            XCTAssertEqual((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0)

            let apiTypes = try XCTUnwrap(
                plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
                "\(relativePath) must declare required-reason API use"
            )
            let reasonsByType = Dictionary(
                uniqueKeysWithValues: apiTypes.compactMap { entry -> (String, Set<String>)? in
                    guard let type = entry["NSPrivacyAccessedAPIType"] as? String,
                          let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] else { return nil }
                    return (type, Set(reasons))
                }
            )

            XCTAssertEqual(reasonsByType["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
            XCTAssertEqual(reasonsByType["NSPrivacyAccessedAPICategoryDiskSpace"], ["E174.1"])
            XCTAssertEqual(
                reasonsByType["NSPrivacyAccessedAPICategoryFileTimestamp"],
                ["C617.1", "3B52.1"]
            )
        }
    }

    func testVisibleProductNameStaysCentralized() throws {
        let projectYML = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(projectYML.contains("APP_DISPLAY_NAME: \"Proton Photos\""))
        XCTAssertTrue(projectYML.contains("INFOPLIST_KEY_CFBundleDisplayName: $(APP_DISPLAY_NAME)"))

        let infoData = try Data(contentsOf: repoRoot.appendingPathComponent("iOSApp/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "$(APP_DISPLAY_NAME)")

        let brandSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/PhotosCore/ProductBrand.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(brandSource.contains("brand.product_name"))

        for relativePath in [
            "App/Views/LoginView.swift",
            "iOSApp/MobileLoginView.swift",
            "iOSApp/MobileLibraryStateViews.swift",
            "iOSApp/MobileAlbumsScreen.swift",
            "iOSApp/MobileSettingsScreen.swift",
            "iOSApp/ProtonPhotosMobileApp.swift"
        ] {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
            XCTAssertTrue(text.contains("ProductBrand.displayName"), "\(relativePath) must use the centralized visible product name")
        }
    }

    func testDebugLogUsesSandboxCompatibleLibraryDirectory() {
        let debugLog = (try? String(
            contentsOf: repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/ProtonDriveBackend/DebugLog.swift"),
            encoding: .utf8
        )) ?? ""
        XCTAssertTrue(debugLog.contains(".libraryDirectory"), "debug logging must stay inside the app container")
        XCTAssertFalse(debugLog.contains("/tmp/protonphotos.log"), "sandboxed app must not hard-code /tmp for debug logs")
    }

    func testMacAppKeepsSingleInstanceLaunchGuard() {
        let app = (try? String(
            contentsOf: repoRoot.appendingPathComponent("App/ProtonPhotosApp.swift"),
            encoding: .utf8
        )) ?? ""
        let guardSource = (try? String(
            contentsOf: repoRoot.appendingPathComponent("App/SingleInstanceGuard.swift"),
            encoding: .utf8
        )) ?? ""

        XCTAssertTrue(
            app.contains("@NSApplicationDelegateAdaptor(ProtonPhotosAppDelegate.self)"),
            "macOS app must install its process-level launch guard before creating windows"
        )
        XCTAssertTrue(app.contains("singleInstanceGuard.acquire()"))
        XCTAssertTrue(app.contains("NSApp.terminate(nil)"), "duplicate launches must exit immediately")

        XCTAssertTrue(guardSource.contains("flock("), "single-instance guard must use a real process lock")
        XCTAssertTrue(guardSource.contains("LOCK_EX | LOCK_NB"), "duplicate launches must never block startup")
        XCTAssertTrue(
            guardSource.contains(".applicationSupportDirectory"),
            "lock file must stay sandbox-compatible"
        )
    }

    /// Backup must keep the display awake while actively running and release it on every exit path.
    /// The idle-timer hook is injectable (UIKit stays out of the shared adapter); the controller calls
    /// it with `isSyncing` at every transition so the host (iOS) can toggle the idle timer and macOS
    /// can leave the default no-op.
    func testBackupControllerManagesIdleTimerViaInjectableHook() throws {
        let controller = try String(
            contentsOf: repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/PhotoLibraryBackupAdapter/PhotoLibraryBackupController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(controller.contains("idleTimerHook: ((Bool) -> Void)?"),
                      "controller must expose an injectable idle-timer hook (no UIKit in the shared adapter)")
        XCTAssertTrue(controller.contains("updateIdleTimerIfNeeded()"), "controller must have a single idle-timer chokepoint")
        XCTAssertTrue(controller.contains("idleTimerHook?(isSyncing)"),
                      "hook must be driven by isSyncing")
        XCTAssertFalse(controller.contains("import UIKit"),
                       "the shared PhotoKit adapter must remain UIKit-free; the host app owns the idle timer")
        let idleCalls = controller.components(separatedBy: "updateIdleTimerIfNeeded()").count - 1
        XCTAssertGreaterThanOrEqual(idleCalls, 2,
                                     "idle timer must be refreshed at start AND finish of a pass")
    }
}
