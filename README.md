# Photo Companion for Proton Drive

Independent, macOS-first photo companion for Proton Drive. This is a personal hobby project, not an official Proton product and not affiliated with Proton AG. The repository currently uses development target names such as `ProtonPhotos`; the public app name is not final.

The app is built around Proton Drive's end-to-end encrypted data model. Authentication uses Proton's browser-based session fork flow, the Proton Drive SDK performs supported Drive operations, and local feature modules keep decrypted user content in memory unless the user explicitly exports files or enables encrypted offline caches.

## Current Status

- Primary target: native macOS app.
- Shared core: Swift package modules are structured for future Apple-platform reuse.
- Mobile shell: an iOS/iPadOS proof target exists to validate the shared core and UIKit adapters, but macOS is the first real product target.
- SDK integration: `Vendor/sdk-swift` is used as a local path dependency.

## Tech Stack

- Swift, SwiftUI, AppKit, MapKit, AVFoundation, CryptoKit, SQLite C API.
- Metal-based grid rendering for the timeline.
- Swift Package Manager modules under `Packages/ProtonPhotosKit`.
- Xcode project generation through `xcodegen` from `project.yml`.
- Proton Drive SDK 0.17.1 vendored locally at `Vendor/sdk-swift`.
- ProtonCore pinned to 37.3.0 in `project.yml`; this must match the SDK's exact requirement.

## Security Model

- The app does not collect the user's Proton password. Sign-in opens Proton's web flow and receives a forked session.
- Session tokens and the mailbox key password are stored in the macOS Keychain service `me.protonphotos.mac.session` with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- The SDK secret cache is kept in memory only; `secretCachePath` is deliberately omitted and legacy `secrets.sqlite` files are purged on launch.
- Thumbnails, previews, offline originals, account-data cache, and the local GPS index are encrypted at rest with CryptoKit AES-GCM.
- Video streaming stores Proton-encrypted Drive blocks on disk; decrypted video bytes are held in memory only.
- Explicit export writes decrypted originals only to the user-selected destination.
- Debug file logging is disabled by default and release builds never write `/tmp/protonphotos.log`.

Known residual risk before distribution: the app currently needs hardened-runtime relaxations for the embedded SDK runtime (`disable-library-validation`, `allow-unsigned-executable-memory`, `allow-jit`). Re-check those entitlements before shipping.

## Requirements

- macOS with Xcode installed at `/Applications/Xcode.app`.
- Xcode command line tools selected from the full Xcode toolchain:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

- `xcodegen` available on `PATH`.
- Git access to the Proton Drive SDK repository.

## Bootstrap

Clone the repository, then clone the local SDK dependency:

```bash
git clone <repo-url> proton-photos
cd proton-photos
git clone --branch 0.17.1 https://github.com/ProtonDriveApps/sdk-swift Vendor/sdk-swift
```

Verify the SDK and ProtonCore pin:

```bash
./scripts/proton-sdk-current-version.sh
```

Generate the Xcode project:

```bash
xcodegen generate
```

`ProtonPhotos.xcodeproj` is generated output and intentionally ignored by Git.

## Build

Compile the macOS app without installing it:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild build \
  -project ProtonPhotos.xcodeproj \
  -scheme ProtonPhotos \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/DD.noindex \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO
```

Build, install, and launch the canonical local app at `/Applications/ProtonPhotos.app`:

```bash
./scripts/rebuild.sh
```

`scripts/rebuild.sh` also generates the project, verifies the iOS shell, builds the macOS app, clears duplicate indexed build products, installs the app into `/Applications`, removes quarantine, registers LaunchServices, and launches it.

## Tests

Run the Swift package test suite:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path Packages/ProtonPhotosKit
```

Run the universal-core/platform-adapter proof gate:

```bash
./scripts/verify-universal-core.sh
```

Build the iOS/iPadOS shell target:

```bash
./scripts/verify-ios-app-shell.sh
```

## Useful Files

- `project.yml` - source of truth for generated Xcode project settings.
- `docs/dependencies.md` - SDK and ProtonCore dependency notes.
- `docs/sdk-capabilities.md` - SDK capability matrix and app wrapper map.
- `SECURITY_E2EE_AUDIT_2026-06-30.md` - previous E2EE/local-cache audit.
- `OFFLINE_THUMBNAIL_SECURITY_REPORT.md` - historical cache hardening report.
- `scripts/rebuild.sh` - canonical local macOS build/install flow.
