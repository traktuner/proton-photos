# Proton Photos

Independent photo client for Proton Drive. This is a personal project and is not an official Proton AG product.

The app is built around Proton Drive's end-to-end encrypted data model. Authentication uses Proton's browser-based session fork flow, supported Drive operations go through the Proton Drive SDK, and local feature modules keep decrypted user content in memory unless the user explicitly exports files or enables encrypted offline caches.

## Current Status

- macOS is the primary and most mature target.
- iOS is functional enough for real-device and simulator testing: sign-in, library loading, the shared Metal timeline, viewer basics, selection UI, settings, and cache plumbing are present, with UI polish still ongoing.
- Core features are organized as Swift package modules so timeline, media cache, decoding, albums, uploads, map data, viewer policy, and backend composition can be shared by macOS, iOS, and iPadOS.
- Platform targets are intended to stay thin: AppKit/UIKit integration, window/navigation chrome, gestures, and platform-native presentation.
- `Vendor/sdk-swift` is used as a local path dependency for the Proton Drive SDK.

## Tech Stack

- Swift, SwiftUI, AppKit, UIKit, MapKit, AVFoundation, CryptoKit, SQLite C API.
- Metal-based timeline/grid rendering.
- Swift Package Manager modules under `Packages/ProtonPhotosKit`.
- Xcode project generation through `xcodegen` from `project.yml`.
- Proton Drive SDK 0.17.1 vendored locally at `Vendor/sdk-swift`.
- ProtonCore pinned to 37.3.0 in `project.yml`; this must match the SDK requirement.

## Security Model

- The app does not collect the user's Proton password. Sign-in opens Proton's web flow and receives a forked session.
- Session tokens and the mailbox key password are stored in the platform Keychain with device-only accessibility.
- The SDK secret cache is kept in memory only; `secretCachePath` is deliberately omitted and legacy `secrets.sqlite` files are purged on launch.
- Thumbnails, previews, offline originals, account-data cache, and the local GPS index are encrypted at rest with CryptoKit AES-GCM.
- Video streaming stores Proton-encrypted Drive blocks on disk; decrypted video bytes are held in memory only.
- Explicit export writes decrypted originals only to the user-selected destination.
- Debug file logging is disabled by default and release builds never write a debug log. Debug builds write the opt-in log under the app's Library Logs directory.
- The macOS app is signed with App Sandbox, outgoing-network access, and user-selected read/write file access only. Hardened Runtime remains enabled without JIT, unsigned executable memory, or library-validation exceptions.

## Requirements

- macOS with Xcode installed at `/Applications/Xcode.app`.
- Xcode command line tools selected from the full Xcode toolchain:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

- `xcodegen` available on `PATH`.
- Git access to the Proton Drive SDK repository if `Vendor/sdk-swift` is not already present.

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

Build, install, and launch the canonical local app at `/Applications/Proton Photos.app`:

```bash
./scripts/rebuild.sh
```

`scripts/rebuild.sh` generates the project, verifies the iOS shell, builds the macOS app, installs it into `/Applications`, registers LaunchServices, and launches it.

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

## Repository Layout

- `App` - macOS app target and AppKit/SwiftUI composition.
- `iOSApp` - iOS/iPadOS app target and UIKit/SwiftUI composition.
- `Packages/ProtonPhotosKit` - shared core, feature, renderer, cache, backend, and platform-adapter modules.
- `Branding` - app icons and shared product assets.
- `Vendor/sdk-swift` - local Proton Drive SDK checkout.
- `project.yml` - source of truth for generated Xcode project settings.
- `scripts/rebuild.sh` - canonical local macOS build/install flow.
