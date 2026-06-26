import Foundation
import Testing

/// Static source guards: removed/insecure production routes must not reappear, and the grid feed must use the
/// shared account-configured cache. Scans App/ + the package Sources/ (NOT Tests/, which holds these literals).
@Suite("Production route guards")
struct ProductionRouteGuardTests {
    /// `<repo>/Packages/ProtonPhotosKit/Tests/TimelineFeatureTests/ProductionRouteGuardTests.swift` → `<repo>`.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TimelineFeatureTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ProtonPhotosKit
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // <repo>
    }

    private func swiftFiles(under dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test func noRemovedProductionRoutesRemain() {
        // The spike tuning UI, the rejected focusRow crossfade flag, AND the single-lattice gating flag must
        // all be gone — the accepted Phase-B effect path is the production default, with no flag of any kind.
        let forbidden = ["anim-tuning", "TuningView", "AnimationTuning",
                         "MetalGrid.focusRowTransition", "MetalGridFocusRowTransitionFlag",
                         "MetalGrid.singleLatticeTransition", "MetalGridSingleLatticeTransitionFlag"]
        let roots = [Self.repoRoot.appendingPathComponent("App"),
                     Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources")]
        var scanned = 0
        for root in roots {
            for file in swiftFiles(under: root) {
                scanned += 1
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                for token in forbidden {
                    #expect(!text.contains(token), "Forbidden production route '\(token)' found in \(file.path)")
                }
            }
        }
        #expect(scanned > 0, "Guard scanned no files — repoRoot path is wrong: \(Self.repoRoot.path)")
    }

    @Test func gridFeedUsesSharedConfiguredCache() throws {
        let mainView = Self.repoRoot.appendingPathComponent("App/Views/MainView.swift")
        let text = try String(contentsOf: mainView, encoding: .utf8)
        // The grid feed must be built with the account-configured shared cache, never a throwaway instance.
        #expect(text.contains("ThumbnailFeed(cache: OfflineLibraryManager.shared.cache"))
        #expect(!text.contains("ThumbnailFeed(cache: ThumbnailCache()"))
    }

    @Test func mainViewUsesNativeSplitViewChrome() throws {
        let mainView = Self.repoRoot.appendingPathComponent("App/Views/MainView.swift")
        let text = try String(contentsOf: mainView, encoding: .utf8)
        #expect(text.contains("NavigationSplitView(columnVisibility:"))
        #expect(text.contains(".navigationSplitViewColumnWidth("))
        #expect(text.contains(".searchable(text: $searchText"))
        #expect(!text.contains("SidebarResizeHandle"))
    }
}
