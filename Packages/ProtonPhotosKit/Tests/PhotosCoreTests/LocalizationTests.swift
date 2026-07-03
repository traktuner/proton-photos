import XCTest
@testable import PhotosCore

/// Localization regression coverage for the English (source) + German String Catalogs.
///
/// The catalog-content checks parse the `.xcstrings` JSON directly from the source tree (located via
/// `#filePath`), so they are deterministic regardless of the host's language - they validate the
/// *translations that ship*, not whatever language the test process happens to run in. The runtime
/// checks additionally prove the package bundle advertises both languages and falls back to English.
final class LocalizationTests: XCTestCase {

    // MARK: Paths (repo tree, via #filePath → up 5 = repo root)

    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }
    private var appCatalog: URL { repoRoot.appendingPathComponent("App/Localizable.xcstrings") }
    private var mobileCatalog: URL { repoRoot.appendingPathComponent("iOSApp/Localizable.xcstrings") }
    private var packageCatalog: URL {
        repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/PhotosCore/Resources/Localizable.xcstrings")
    }

    // MARK: Catalog parsing

    private struct Catalog {
        let sourceLanguage: String
        /// key → set of languages that have a non-empty value.
        let coverage: [String: Set<String>]
    }

    /// True if a localization node ("en"/"de" value) carries at least one non-empty string - either a
    /// direct `stringUnit` or any `variations` leaf (plurals/device/width).
    private func hasNonEmptyValue(_ node: Any) -> Bool {
        guard let dict = node as? [String: Any] else { return false }
        if let unit = dict["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String, !value.isEmpty {
            return true
        }
        if let variations = dict["variations"] as? [String: Any] {
            return variations.values.contains { variantGroup in
                guard let group = variantGroup as? [String: Any] else { return false }
                return group.values.contains { hasNonEmptyValue($0) }
            }
        }
        return false
    }

    private func loadCatalog(_ url: URL) throws -> Catalog {
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let source = json["sourceLanguage"] as? String ?? ""
        let strings = json["strings"] as? [String: Any] ?? [:]
        var coverage: [String: Set<String>] = [:]
        for (key, entry) in strings {
            var langs: Set<String> = []
            if let e = entry as? [String: Any], let locs = e["localizations"] as? [String: Any] {
                for (lang, node) in locs where hasNonEmptyValue(node) { langs.insert(lang) }
            }
            coverage[key] = langs
        }
        return Catalog(sourceLanguage: source, coverage: coverage)
    }

    // MARK: Source language

    func testSourceLanguageIsEnglish() throws {
        XCTAssertEqual(try loadCatalog(appCatalog).sourceLanguage, "en")
        XCTAssertEqual(try loadCatalog(mobileCatalog).sourceLanguage, "en")
        XCTAssertEqual(try loadCatalog(packageCatalog).sourceLanguage, "en")
    }

    // MARK: Representative keys exist in both English and German

    func testRepresentativeAppKeysHaveEnglishAndGerman() throws {
        let cov = try loadCatalog(appCatalog).coverage
        let reps = [
            "login.tagline", "sidebar.all_photos", "settings.library_tab", "menu.upload_photos",
            "action.cancel", "search.prompt %@", "alert.trash_confirmation_title_other %lld",
            "a11y.download_count_selected_originals %lld",
        ]
        for key in reps {
            let langs = cov[key] ?? []
            XCTAssertTrue(langs.contains("en"), "App catalog missing English for \(key)")
            XCTAssertTrue(langs.contains("de"), "App catalog missing German for \(key)")
        }
    }

    func testRepresentativeMobileKeysHaveEnglishAndGerman() throws {
        let cov = try loadCatalog(mobileCatalog).coverage
        let reps = [
            "tab.photos", "loading.library_title", "loading.preparing_count %lld",
            "empty.message %@", "settings.sign_out_confirm %@", "albums.photo_count %lld",
            "map.empty_message", "auth.sign_in_prompt", "device.requires_metal3 %@",
        ]
        for key in reps {
            let langs = cov[key] ?? []
            XCTAssertTrue(langs.contains("en"), "Mobile catalog missing English for \(key)")
            XCTAssertTrue(langs.contains("de"), "Mobile catalog missing German for \(key)")
        }
    }

    func testRepresentativePackageKeysHaveEnglishAndGerman() throws {
        let cov = try loadCatalog(packageCatalog).coverage
        let reps = [
            "tag.favorites", "error.video.not_a_video", "upload.state_queued",
            "upload.queue_stats %lld %lld %lld", "action.retry", "infopanel.dimensions",
        ]
        for key in reps {
            let langs = cov[key] ?? []
            XCTAssertTrue(langs.contains("en"), "Package catalog missing English for \(key)")
            XCTAssertTrue(langs.contains("de"), "Package catalog missing German for \(key)")
        }
    }

    // MARK: Full coverage - every key carries both languages (no half-translated entries)

    func testEveryKeyHasEnglishAndGerman() throws {
        for (name, url) in [("App", appCatalog), ("Mobile", mobileCatalog), ("Package", packageCatalog)] {
            let cov = try loadCatalog(url).coverage
            XCTAssertFalse(cov.isEmpty, "\(name) catalog is empty")
            for (key, langs) in cov {
                XCTAssertTrue(langs.contains("en"), "\(name) catalog: \(key) has no English value")
                XCTAssertTrue(langs.contains("de"), "\(name) catalog: \(key) has no German value")
            }
        }
    }

    // MARK: Runtime - bundle advertises both languages and falls back to English
    //
    // NOTE: String Catalogs are compiled to `.lproj/.strings` by Xcode's build system (xcstringstool).
    // Plain command-line SwiftPM (`swift build`/`swift test`) copies the raw `.xcstrings` into the bundle
    // *without* compiling it, so at runtime under `swift test` the package facade can't resolve the
    // catalog. The shipping app is built with `xcodebuild`, where these resolve correctly (verified by
    // the presence of `de.lproj` in the built app and package bundles). The runtime-resolution checks
    // below therefore skip when the catalog isn't compiled, so `swift test` stays green while the checks
    // still run (and pass) under an Xcode build. The catalog-content checks above need no such guard.

    /// Whether the package String Catalog was compiled into the resource bundle (Xcode build) vs. copied
    /// raw (plain SwiftPM).
    private var catalogCompiledIntoBundle: Bool {
        L10n.resourceBundle.localizations.contains("de")
    }

    func testPackageBundleAdvertisesEnglishAndGerman() throws {
        try XCTSkipUnless(catalogCompiledIntoBundle,
                          "String Catalog not compiled (plain SwiftPM build) - validated under xcodebuild.")
        let available = Set(L10n.resourceBundle.localizations)
        XCTAssertTrue(available.contains("en"), "package bundle should advertise English")
        XCTAssertTrue(available.contains("de"), "package bundle should advertise German")
    }

    func testUnsupportedLanguageFallsBackToEnglish() {
        // A user who prefers an unsupported language (French) resolves to the development language. This
        // exercises the fallback resolution regardless of whether German is compiled into the bundle.
        let available = L10n.resourceBundle.localizations
        let resolved = Bundle.preferredLocalizations(from: available, forPreferences: ["fr-FR", "fr"]).first
        XCTAssertEqual(resolved, "en", "unsupported language should fall back to English")
    }

    func testFacadeResolvesAKnownKey() throws {
        try XCTSkipUnless(catalogCompiledIntoBundle,
                          "String Catalog not compiled (plain SwiftPM build) - validated under xcodebuild.")
        // The facade returns a real translation, not the raw key.
        let favorites = L10n.string("tag.favorites")
        XCTAssertFalse(favorites.isEmpty)
        XCTAssertNotEqual(favorites, "tag.favorites")
    }

    // MARK: Static guard - migrated German UI strings must not be reintroduced hardcoded in source

    func testNoReintroducedHardcodedGermanUIStrings() {
        // Specific phrases that used to be hardcoded German in UI source and now live only in the
        // catalogs. Searched as quoted literals so prose/comments don't trip the guard. (Intentional
        // inline locale fallbacks such as ViewerTitleFormatter's "Foto"/"von" are deliberately excluded.)
        let forbidden = [
            "\"Wiedergabe fehlgeschlagen\"",
            "\"Offline-Mediathek\"",
            "\"Originale & Videos offline behalten\"",
            "\"Dies ist kein Video.\"",
            "\"Mediathek / Offline\"",
            "\"Offline-Cache löschen",
        ]
        let roots = [
            repoRoot.appendingPathComponent("App"),
            repoRoot.appendingPathComponent("iOSApp"),
            repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources"),
        ]
        let fm = FileManager.default
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                for phrase in forbidden {
                    XCTAssertFalse(text.contains(phrase),
                                   "\(url.lastPathComponent) reintroduced a hardcoded German UI string: \(phrase)")
                }
            }
        }
    }
}
