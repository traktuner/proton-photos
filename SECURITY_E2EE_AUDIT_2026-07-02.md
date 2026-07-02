# Security / E2EE Audit - 2026-07-02

Scope: focused review for Proton review readiness, with emphasis on whether local behavior breaks Proton Drive E2EE or allows session/access tokens to be abused.

This is a source-level audit of the Swift app code and the app's integration boundary with the Proton Drive SDK. It is not a formal cryptographic proof of the SDK/native core.

## Result

No confirmed E2EE break or plaintext session-token persistence was found in the current app code.

One defense-in-depth token-handling issue was fixed in this pass: app session auth is now constrained to the configured Proton Drive API host, and storage URLs must be HTTPS. This reduces the blast radius if an SDK-provided URL or future wrapper path ever resolves outside the expected Proton API host.

The app still has important residual review items before public distribution: local metadata SQLite stores remain plaintext, the app is currently unsandboxed and uses hardened-runtime relaxations for the embedded SDK runtime, and decrypted keys/session material necessarily exist in process memory while the app is signed in.

## Areas Reviewed

- Authentication and session persistence: `Packages/ProtonPhotosKit/Sources/ProtonAuth/Session.swift`, `Packages/ProtonPhotosKit/Sources/ProtonAuth/ProtonForkAuthenticator.swift`, `App/Drive/DriveSession.swift`.
- SDK HTTP boundary: `App/Drive/SDKHttpClient.swift`, `App/Drive/DriveSDKBridge.swift`.
- Local caches and offline stores: `App/Offline/OfflineLibraryManager.swift`, `App/Drive/AccountDataCache.swift`, `Packages/ProtonPhotosKit/Sources/MediaByteCache/*`, `Packages/ProtonPhotosKit/Sources/MediaLocationCore/PhotoLocationStore.swift`, `Packages/ProtonPhotosKit/Sources/PhotosCore/TimelineMetadataStore.swift`.
- Video streaming: `App/Drive/Streaming/DriveCrypto.swift`, `App/Drive/Streaming/PhotoVideoStreamSource.swift`, `App/Drive/Streaming/VideoByteRangeCache.swift`, `App/Drive/Streaming/ProtonVideoResourceLoader.swift`.
- Export and diagnostics: `App/Views/MainView.swift`, `App/Drive/DebugLog.swift`, `Packages/ProtonPhotosKit/Sources/PhotosCore/Diagnostics.swift`.
- Entitlements and build surface: `App/ProtonPhotos.entitlements`, `project.yml`, `scripts/rebuild.sh`.

## E2EE Invariants Checked

- The app does not collect the user's Proton password. Sign-in uses Proton's browser/session-fork flow and receives a forked session plus decrypted key password payload.
- Session tokens and the mailbox key password are stored through macOS Keychain only, service `me.protonphotos.mac.session`, with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- The old plaintext `dev-session.json` path is removed during save/clear and is not used by the current session store.
- The Proton Drive SDK secret cache is kept in memory by omitting `secretCachePath`; legacy `secrets.sqlite`, `secrets.sqlite-wal`, and `secrets.sqlite-shm` are purged at launch.
- Thumbnails, previews, offline originals, account-data cache, and the local GPS index are encrypted at rest with CryptoKit AES-GCM using account-bound associated data.
- Video byte-range caching stores Proton-encrypted Drive blocks on disk. Decrypted video bytes are held in memory by the streaming pipeline, not written as local plaintext cache files.
- User exports intentionally write decrypted originals only to user-selected destinations. ZIP export cleanup removes partial files on failure/cancel.
- Debug file logging is disabled by default and Release builds never write `/tmp/protonphotos.log`.

## Finding Fixed In This Pass

### F-2026-07-02-01 - Session auth could follow an untrusted absolute Drive API URL

Severity: Low to Medium, defense-in-depth. No current user-controlled exploit path was confirmed.

Before this pass, `SDKHttpClient.requestDriveApi` accepted the SDK-provided Drive API path, normalized embedded absolute URLs, and then applied session auth headers. If a compromised SDK/native core, unexpected SDK behavior, or future wrapper bug supplied an absolute non-Proton URL through the Drive API path, the app could attach `Authorization: Bearer ...` and `x-pm-uid` to that request.

`DriveSession.fetchBlock(url:token:)` also treated `token == nil` full URLs as authenticated requests. That is safe for Proton API URLs, but it was broader than necessary for storage/pre-signed URLs.

Fix:

- `SDKHttpClient.requestDriveApi` now refuses Drive API requests unless the final URL is HTTPS and its host matches `driveSession.config.baseURL.host`.
- Storage upload/download URLs must be HTTPS and have a host before any SDK storage headers are applied.
- `DriveSession.fetchBlock(url:token:)` now sends session auth only to the trusted Proton Drive API host. External HTTPS pre-signed URLs are fetched without app session auth.

Files changed:

- `App/Drive/SDKHttpClient.swift`
- `App/Drive/DriveSession.swift`

## Token Handling Review

- Access/refresh tokens are kept in the live `DriveSession` object and persisted only through `SessionKeychainStore`.
- Refresh-token rotation writes the updated session back to Keychain; no file fallback is present.
- `SDKHttpClient` adds session auth only on Drive API requests after the new trusted-host check.
- Storage uploads/downloads use SDK-provided storage headers and do not add app session auth.
- Debug logs do not log token values. They may include API paths, local filenames, node IDs, or status codes in DEBUG-only logging, so `PROTONPHOTOS_DEBUG_LOG` should stay disabled for normal QA/release.

## Residual Risks / Proton Review Notes

- `entities.sqlite` remains an SDK-owned plaintext metadata cache. This can include decrypted Drive metadata such as names/hashes. App-side mitigation would be to disable `entityCachePath`, at a cold-start performance cost.
- The app timeline database remains plaintext app metadata: volume/node IDs, capture time, MIME/type flags, dimensions, tags, and related IDs. It does not store media bytes or session secrets, but it is still local metadata.
- Hardened-runtime relaxations are currently present for the embedded SDK runtime: `disable-library-validation`, `allow-unsigned-executable-memory`, and `allow-jit`. These should be revalidated before distribution.
- The app is currently unsandboxed. That may be acceptable during development but should be revisited for App Store/TestFlight distribution.
- Decrypted keys, access tokens, and decrypted media bytes exist in process memory while the user is signed in or viewing media. This is expected for a native client, but it is not memory-hardening.
- This audit did not prove that the Proton Drive SDK/native core never spills decrypted material elsewhere. That should be reviewed by Proton against the SDK/runtime internals.

## README / Build Instructions

Added `README.md` with:

- Project status and macOS-first scope.
- Technology stack and Proton Drive SDK dependency notes.
- Security model summary.
- Bootstrap steps for `Vendor/sdk-swift`.
- `xcodegen`, `xcodebuild`, `scripts/rebuild.sh`, and package-test commands.

The README deliberately describes the app as an independent photo companion for Proton Drive. It also notes that current `ProtonPhotos` target names are development identifiers and the public app name is not final.

## Verification

Commands run on 2026-07-02:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer git diff --check

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path Packages/ProtonPhotosKit

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

Result: package tests passed; two String Catalog tests were skipped by design in plain SwiftPM and are covered by the Xcode build path. The macOS app build completed with `BUILD SUCCEEDED`.
