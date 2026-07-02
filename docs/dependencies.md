# Dependencies

## Proton Drive SDK (`Vendor/sdk-swift`)

| | |
|---|---|
| Repo | https://github.com/ProtonDriveApps/sdk-swift |
| Integration | Vendored **local path** Swift package (`Vendor/sdk-swift`), gitignored - re-clone, not committed |
| Current tag | **0.17.1** |
| Tag commit | `527b3115a80fcf006e944bf610ffe27ab3a9e23e` |
| SDK source commit | `2eb7f75ca92d508d074e11f0a540ba6dadad3d8e` |
| xcframework | `CProtonDriveSDK.xcframework` 0.17.1 (checksum `dcff6fda…`) |
| Updated | 2026-06-18 (from 0.15.0 / commit `fab6c242…` / source `6fabe065…`) |

It must be a **local path** package (not a versioned remote dependency) because the SDK's
`Package.swift` uses `.unsafeFlags` in its linker settings - SwiftPM forbids those in remote deps.
Re-clone with: `git clone --branch 0.17.1 https://github.com/ProtonDriveApps/sdk-swift Vendor/sdk-swift`

### ProtonCore coupling (important)

`Vendor/sdk-swift/Package.swift` pins `protoncore_ios` with `exact:`. The app's `project.yml` **must
pin the same exact version** or SwiftPM resolution fails.

| sdk-swift tag | requires ProtonCore |
|---|---|
| 0.15.0 / 0.15.1 / 0.16.0 / 0.17.0 | 37.0.1 |
| **0.17.1** | **37.3.0** |

0.16.0 and 0.17.0 shipped an xcframework whose `libproton_drive_sdk.a` needs GoLibs crypto symbols
`_pgp_key_unlock` / `_pgp_reader_destroy`, but those tags still pinned ProtonCore 37.0.1 (which only
exports `_pgp_key_unlock_with_token` / `_pgp_go_reader_destroy`) → "Undefined symbols for
architecture arm64" at link. **0.17.1 fixes the inconsistency** by bumping to 37.3.0, which exports
the matching symbols. So 0.17.1 + ProtonCore 37.3.0 is the coherent combination.

### API impact of 0.15.0 → 0.17.1

The public Swift API the app consumes (`ProtonPhotosClient.enumerateTimeline` / `downloadThumbnails`
/ `download`, `SDKNodeUid`, `PhotoTimelineItem`, `ProtonDriveClientConfiguration`,
`HttpClientProtocol`, `AccountClientProtocol`) is **unchanged**. The only `Sources/` diffs are the
generated protobuf and additive telemetry enum cases (`DownloadError.validationError`,
`UploadError.validationError`) - both ignored by the app's no-op log/metric callbacks.

All SDK-specific types stay isolated in `App/Drive/` (`DriveSDKBridge`, `SDKHttpClient`,
`SDKAccountClient`, `DriveSession`). The feature package `Packages/ProtonPhotosKit` has **no** SDK or
ProtonCore dependency.

## ProtonCore (`protoncore_ios`)

| | |
|---|---|
| Repo | https://github.com/ProtonMail/protoncore_ios |
| Version | **37.3.0** (was 37.0.1) - pinned `exact` in `project.yml`, must match sdk-swift |
| Products linked | `ProtonCoreDataModel`, `ProtonCoreCrypto`, `ProtonCoreCryptoGoInterface`, `ProtonCoreCryptoPatchedGoImplementation`, `ProtonCoreKeyManager`, `GoLibsCryptoPatchedGo` (via SDK) |
