import Foundation

/// Localization facade for every ProtonPhotosKit package module.
///
/// All package-level user-facing strings live in `PhotosCore`'s String Catalog
/// (`Sources/PhotosCore/Resources/Localizable.xcstrings`) and are resolved here against
/// `Bundle.module`. Routing every package lookup through this one entry point means package
/// views never accidentally fall back to `Bundle.main` (which is what a bare `Text("key")` /
/// `String(localized:)` would do inside a Swift package) — the string is always read from the
/// package's own catalog, regardless of which module the call site lives in.
///
/// Keys are stable, human-readable, and dotted (e.g. `tag.favorites`, `upload.state_queued`).
/// The English catalog value is the source of truth; German (`de`) is the first translation.
///
/// Usage:
/// ```swift
/// Text(L10n.string("upload.queue_title"))                 // plain key
/// Text(L10n.string("error.album_not_found \(albumID)"))   // interpolation  → key "error.album_not_found %@"
/// Text(L10n.string("upload.state_uploading \(percent)"))  // interpolation  → key "upload.state_uploading %lld"
/// ```
///
/// Plural-aware strings (catalog entries with plural variations, or one/other key pairs) live in the App
/// catalog today; see `docs/localization.md` for the plurals convention.
///
/// SwiftUI controls accept the returned `String` through their `StringProtocol` initializers, so the
/// already-localized value is shown verbatim (no double lookup).
public enum L10n {
    /// Resolves `key` (a stable catalog key, optionally with interpolated arguments) against the
    /// package String Catalog. Interpolated values become `%@`/`%lld` format arguments and drive
    /// plural selection where the catalog entry defines plural variations.
    ///
    /// - Parameters:
    ///   - key: A `String.LocalizationValue` built from a stable catalog key. Interpolation is allowed
    ///          (`"key \(value)"`) and is captured as format arguments.
    ///   - comment: Optional translator note. Catalog comments are authored in the `.xcstrings` file,
    ///              so this is rarely needed at the call site.
    /// - Returns: The localized string for the app's effective language, falling back to English.
    public static func string(_ key: String.LocalizationValue, comment: StaticString? = nil) -> String {
        String(localized: key, bundle: .module, comment: comment)
    }

    /// The bundle backing the package String Catalog. Exposed for tests/diagnostics (e.g. to assert the
    /// available localizations and the English fallback); not needed for normal lookups, which go through
    /// `string(_:comment:)`.
    public static var resourceBundle: Bundle { .module }
}
