# Localization

ProtonPhotos ships an English (source) and German (`de`) UI, built on Apple's **String Catalogs**
(`.xcstrings`). The app uses the **system language automatically**; an unsupported language falls back
to English. There is intentionally **no in-app language picker** — language follows the OS.

## Architecture at a glance

Two String Catalogs, split by which bundle the strings live in:

| Catalog | Path | Bundle | Used by | How code reads it |
| --- | --- | --- | --- | --- |
| **App** | `App/Localizable.xcstrings` | main app bundle | the `App/` target | `Text("key")`, `String(localized: "key")` (default = `Bundle.main`) |
| **Package** | `Packages/ProtonPhotosKit/Sources/PhotosCore/Resources/Localizable.xcstrings` | `ProtonPhotosKit_PhotosCore.bundle` | every `ProtonPhotosKit` module | `L10n.string("key")` (resolves against `Bundle.module`) |

- **Source language:** English (`en`). Set via `developmentLanguage: en` in `project.yml` and
  `defaultLocalization: "en"` in `Packages/ProtonPhotosKit/Package.swift`.
- **Keys** are stable, human-readable, dotted identifiers (`sidebar.all_photos`, `upload.state_queued`,
  `error.video.unsupported_codec`). The English value is the source of truth; editing English copy does
  **not** change the key.
- The main app bundle ships `en.lproj` + `de.lproj` (produced from the App catalog). That is what makes
  macOS run the app in German when the user prefers it — and drives `Bundle.module`'s language for the
  package catalog too.

### Why a facade for package strings

Inside a Swift package, a bare `Text("key")` or `String(localized: "key")` resolves against
`Bundle.main` (the host app), **not** the package's own resource bundle. To avoid that "accidental
`Bundle.main`" trap, every package module routes lookups through one entry point in `PhotosCore`:

```swift
// Packages/ProtonPhotosKit/Sources/PhotosCore/Localization.swift
public enum L10n {
    public static func string(_ key: String.LocalizationValue, comment: StaticString? = nil) -> String {
        String(localized: key, bundle: .module, comment: comment)   // .module = PhotosCore's bundle
    }
}
```

`PhotosCore` is the lowest-level module and **every** other package module already depends on it, so
`L10n` is reachable everywhere with a single `import PhotosCore`. The facade returns a resolved `String`,
which all SwiftUI controls accept verbatim through their `StringProtocol` initializers (`Text`, `Button`,
`Label`, `.help`, `.accessibilityLabel`, …) — and which also works in non-SwiftUI sites (`NSMenuItem`,
accessibility APIs, error `userMessage`s).

```swift
Text(L10n.string("upload.queue_title"))                  // plain key
Text(L10n.string("error.album_not_found \(albumID)"))    // interpolation → key "error.album_not_found %@"
label = L10n.string("upload.state_uploading \(percent)") // interpolation → key "upload.state_uploading %lld"
```

### Plurals & interpolation

- **Interpolation** uses `String.LocalizationValue` interpolation: `"key \(value)"` becomes a key with a
  `%@`/`%lld` suffix and the value as a format argument. Never concatenate localized fragments — put the
  whole sentence (with placeholders) in one catalog entry.
- **Plurals** use String Catalog plural variations (compiled to `.stringsdict`). Apple requires every
  plural variation to reference the number; for messages whose singular form omits the count (e.g. "Move
  photo to Trash?" vs "Move 3 photos to Trash?"), use **two top-level keys** (`…_one` / `…_other %lld`)
  selected by a `count == 1` check at the call site. See `alert.trash_confirmation_*` in the App catalog.

## Intentionally not localized

These are deliberate and shouldn't be "fixed":

- **Brand / proper nouns:** "Proton Photos", "Proton AG", "Proton Drive".
- **Developer cache diagnostics:** the Settings ▸ Developer tab *is* localized (it's reachable in
  production), but the underlying metric *values* are raw data.
- **Technical SDK-gap detail:** `AlbumError.unsupported` carries `operation` + `gap` describing exactly
  which album capability is missing. These are developer-facing diagnostics kept in the error's
  associated values (used by tests/logs); the user sees the localized `error.album_action_unavailable`
  ("This action isn't available yet.") via `errorDescription`, never the raw gap prose. Album writes are
  also gated read-only in the UI today.
- **Dynamic server/SDK detail:** passthrough error text such as `AlbumError.backend(message)`,
  `UploadError.backend(message)`, and `ProtonAuthError.apiError`'s server message — these are
  runtime-provided strings (like `error.localizedDescription`), interpolated as detail into a localized
  frame where one exists, not fixed UI copy we can translate.
- **`ViewerTitleFormatter`:** a pure, locale-parameterized formatter; its "Photo"/"Foto" fallback and
  date connectors switch on the passed `locale` (not the bundle) so it stays deterministically
  unit-testable. This is intentional and separate from the catalogs.

## How to add a new string

1. **Pick the catalog** by where the call site lives:
   - In `App/…` → App catalog, and read it with `Text("your.key")` / `String(localized: "your.key")`.
   - In `Packages/ProtonPhotosKit/…` → Package catalog, and read it with `L10n.string("your.key")`.
2. **Add the entry** to the chosen `Localizable.xcstrings`. Easiest in Xcode (open the `.xcstrings`, add a
   key, fill in English + German). Manual JSON is fine too — each entry is:
   ```json
   "your.key" : {
     "comment" : "Where/why this is shown (helps translators).",
     "extractionState" : "manual",
     "localizations" : {
       "en" : { "stringUnit" : { "state" : "translated", "value" : "Your text" } },
       "de" : { "stringUnit" : { "state" : "translated", "value" : "Dein Text" } }
     }
   }
   ```
3. **Add a translator `comment`** for anything ambiguous.
4. Build with **Xcode/`xcodebuild`** (the app's normal build) so the catalog compiles to `.lproj`.

> Tip: with a String Catalog open in Xcode, building the target will also *auto-extract* string literals
> from `String(localized:)`/`Text(_:)` calls **in that same target** into its catalog. Cross-module
> facade calls aren't auto-extracted (the literal lives in `PhotosCore`), so add those entries by hand.

The localization regression tests (`Packages/ProtonPhotosKit/Tests/PhotosCoreTests/LocalizationTests.swift`)
assert that **every** key has both an English and a German value, so a half-translated entry fails CI.

## How to add a new language

1. In **both** `Localizable.xcstrings` files, add the language (Xcode: the `+` in the catalog editor;
   or add a `"<lang>"` localization block alongside `"en"`/`"de"` for every key).
2. Translate every key (the `testEveryKeyHasEnglishAndGerman`-style guard can be extended to the new
   language to enforce completeness).
3. No code changes are needed — macOS will offer the language automatically once `<lang>.lproj` is in the
   built bundle. Optionally add the language to `knownRegions` in Xcode if you want it surfaced in the
   project's localization UI.

## Crowdin / XLIFF round-trip (future)

The repo's source of truth is the two `.xcstrings` files. Crowdin's direct `.xcstrings` support varies, so
the recommended, always-works path is **Xcode localization export/import (XLIFF)**:

**Export for translators / Crowdin upload:**
```bash
xcodebuild -exportLocalizations \
  -project ProtonPhotos.xcodeproj \
  -localizationPath ./localization-export \
  -exportLanguage de            # repeat -exportLanguage <lang> per target language
```
This produces one `de.xcloc` per language (each containing an XLIFF) covering **all** catalogs in the
build — the App catalog and the package catalogs — grouped by source file. Upload the XLIFF to Crowdin (or
hand it to translators).

**Import translations back:**
```bash
xcodebuild -importLocalizations \
  -project ProtonPhotos.xcodeproj \
  -localizationPath ./localization-import/de.xcloc
```
Xcode merges the translated XLIFF back into the `.xcstrings` files. Commit the updated catalogs.

A disabled CI skeleton for automating this lives at `.github/workflows/localization.yml` (commented out,
no credentials). Enable it and add a `CROWDIN_*` secret only when the project actually adopts Crowdin.

## Build-system caveat (important)

String Catalogs are compiled to `.lproj/.strings`(`dict`) by **Xcode's build system** (`xcstringstool`),
which runs under `xcodebuild` — i.e. the real app build (`scripts/rebuild.sh`). **Plain command-line
SwiftPM** (`swift build` / `swift test`) currently copies the raw `.xcstrings` into the resource bundle
**without** compiling it. Consequences:

- The shipping app (built via `xcodebuild`) localizes correctly — verified by `de.lproj` appearing in both
  `ProtonPhotos.app/Contents/Resources/` and the embedded `ProtonPhotosKit_PhotosCore.bundle`.
- Under `swift test`, the **package** facade can't resolve the catalog at runtime, so package strings come
  back as their keys. The localization tests handle this: the **catalog-content** checks read the
  `.xcstrings` JSON directly (build-independent), and the few **runtime-resolution** checks `XCTSkip`
  themselves when the catalog wasn't compiled. App-target localization is verified by running the app.

## Verifying a language at runtime

Run the built app forcing a language (no system-settings change needed):

```bash
APP="$(pwd)/build/DD.noindex/Build/Products/Debug/ProtonPhotos.app"
"$APP/Contents/MacOS/ProtonPhotos" -AppleLanguages '(de)'   # German
"$APP/Contents/MacOS/ProtonPhotos" -AppleLanguages '(en)'   # English
"$APP/Contents/MacOS/ProtonPhotos" -AppleLanguages '(fr)'   # unsupported → falls back to English
```

The login screen alone exercises several localized strings (tagline, sign-in button, footer) with no
account needed.
