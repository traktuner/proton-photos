# Dependencies

## Proton Drive SDK (`Vendor/sdk-swift`)

| | |
|---|---|
| Repo | https://github.com/ProtonDriveApps/sdk-swift |
| Integration | Vendored **local path** Swift package (`Vendor/sdk-swift`), gitignored - re-clone, not committed |
| Current tag | **0.19.0** |
| Tag commit | `8a1379eb31e536713dca484fe4ceaf95a1521e45` |
| SDK source commit | `ca7b010218db97c33537c8cfe87940c651ae70f0` |
| xcframework | `CProtonDriveSDK.xcframework` 0.19.0 (checksum `8e151fcb…`) |
| Updated | 2026-07-04 (from 0.17.1 / commit `527b311…` / source `2eb7f75…`) |

It must be a **local path** package (not a versioned remote dependency) because the SDK's
`Package.swift` uses `.unsafeFlags` in its linker settings - SwiftPM forbids those in remote deps.
Prepare or refresh it with: `./scripts/update-proton-sdk.sh 0.19.0`. The script applies the local
path-package linker patch required by this repo.

### ProtonCore coupling (important)

`Vendor/sdk-swift/Package.swift` pins `protoncore_ios` with `exact:`. The app's `project.yml` **must
pin the same exact version** or SwiftPM resolution fails.

| sdk-swift tag | requires ProtonCore |
|---|---|
| 0.15.0 / 0.15.1 / 0.16.0 / 0.17.0 | 37.0.1 |
| **0.17.1 / 0.18.0 / 0.18.1 / 0.19.0** | **37.3.0** |

0.16.0 and 0.17.0 shipped an xcframework whose `libproton_drive_sdk.a` needs GoLibs crypto symbols
`_pgp_key_unlock` / `_pgp_reader_destroy`, but those tags still pinned ProtonCore 37.0.1 (which only
exports `_pgp_key_unlock_with_token` / `_pgp_go_reader_destroy`) → "Undefined symbols for
architecture arm64" at link. **0.17.1 and newer fix the inconsistency** by requiring 37.3.0, which
exports the matching symbols. So 0.19.0 + ProtonCore 37.3.0 is the current coherent combination.

### API impact of 0.17.1 → 0.19.0

The `ProtonPhotosClient` surface the app consumes (`enumerateTimeline`, `downloadThumbnails`,
`download`, upload/cancel) remains source-compatible except for the HTTP adapter stream initializer:
`HttpClientStream` now takes `source: .stream(...)` or `source: .file(...)`. `ProtonDriveClient`
adds public generic Drive APIs we can use where they match photos behavior; the app now routes
move-to-trash through `ProtonDriveClient.trash(nodes:)`. Photos album/favorite/list-trash/restore
capabilities are still not exposed as public Swift SDK methods, so those remain behind the direct-HTTP
backend seams.

All SDK-specific types stay isolated in `App/Drive/` (`DriveSDKBridge`, `SDKHttpClient`,
`SDKAccountClient`, `DriveSession`). The feature package `Packages/ProtonPhotosKit` has **no** SDK or
ProtonCore dependency.

## ProtonCore (`protoncore_ios`)

| | |
|---|---|
| Repo | https://github.com/ProtonMail/protoncore_ios |
| Version | **37.3.0** (was 37.0.1) - pinned `exact` in `project.yml`, must match sdk-swift |
| Products linked | `ProtonCoreDataModel`, `ProtonCoreCrypto`, `ProtonCoreCryptoGoInterface`, `ProtonCoreCryptoPatchedGoImplementation`, `ProtonCoreKeyManager`, `GoLibsCryptoPatchedGo` (via SDK) |
