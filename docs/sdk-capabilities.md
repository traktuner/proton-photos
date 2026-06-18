# SDK capability matrix

What the Proton Drive Swift SDK (`Vendor/sdk-swift`, 0.17.1) exposes, what the app actually uses, and
where each capability is wrapped. The runtime equivalent is logged once at sign-in as the
`[SDKCapabilities]` block (see `App/Drive/SDK/SDKCapabilities.swift`).

The golden rule: **use the SDK where it exists and is stable; where it doesn't, route through the
direct-HTTP layer behind a clean feature interface; where neither can do it, surface an explicit
`unsupported` error — never fake success and never silently downgrade.**

## `ProtonPhotosClient`

| Method | Used by app | Wrapper location | Status | Notes |
|---|---|---|---|---|
| `enumerateTimeline` | yes | `DriveSDKBridge.loadTimeline()` | implemented | SQLite-cached; unchanged by this pass |
| `downloadThumbnails` | yes | `DriveSDKBridge.loadThumbnails/singleThumbnail` | implemented | grid + viewer thumbnails |
| `download` | yes | `DriveSDKBridge.downloadOriginal` | implemented | full-res export |
| `downloadOperation` | indirect | (via `download`) | available | not separately surfaced; `download` covers current needs |
| `cancelPhotoDownload` | no | — | available | not wired (downloads are short-lived) |
| `uploadPhoto` | **yes (new)** | `DriveSDKBridge: PhotoUploading.upload` | implemented | library upload; convenience path (operation + start) |
| `startUpload` | indirect | (inside `uploadPhoto`) | implemented | called by the convenience `uploadPhoto` |
| `uploadOperation` | indirect | (inside `uploadPhoto`) | available | not held separately, so no in-flight byte-pause (see below) |
| `cancelUpload` | **yes (new)** | `DriveSDKBridge: PhotoUploading.cancel` | implemented | token-based cancel of an in-flight upload |

The upload storage stream (`HttpClientProtocol.requestUploadToStorage`) was previously a stub returning
"not implemented". It is now implemented in `App/Drive/SDKHttpClient.swift` (bound input/output stream
pair, pumped on the main run loop, read by `URLSession` as the request body).

### Which upload method is used, and resume honesty

The app uploads via the `uploadPhoto` **convenience** (which internally builds an `UploadOperation` and
calls `startUpload`). It does **not** retain the `UploadOperation`, so:

- **Cancel:** supported (`cancelUpload(token:)`).
- **Pause/resume:** the SDK's `UploadOperation` supports it, but because we don't hold the operation,
  in-flight transfers are **not** byte-paused. Queued (not-yet-started) items pause at the queue level;
  a cancelled/failed item **retries from the start**. This is reported honestly via
  `UploadBackendCapabilities.supportsPauseResume = false`.
- **Resume across relaunch:** **not supported** (`supportsResumeAcrossRelaunch = false`) — operation
  state is in-memory only; on relaunch, incomplete items are re-queued as retry-from-start.

To get true in-flight pause/byte-resume later, switch `DriveSDKBridge.upload` to retain the
`UploadOperation` and wire `pause`/`resume` to it, then flip the capability flag.

## Albums

The Swift SDK exposes **no** album API (confirmed: `grep -ri album Vendor/sdk-swift/Sources` → nothing).

| Operation | Path | Status | Notes |
|---|---|---|---|
| List albums | direct HTTP | implemented | `DriveSession.fetchAlbums` + name decryption (`PhotoVideoStreamSource.nodeName`) |
| List album photos | direct HTTP | implemented | `DriveSession.fetchAlbumPhotos` |
| Create album | — | **unsupported** | needs album-node encryption (node key + encrypted name + hash key) — not implemented |
| Add photo to album | — | **unsupported** | needs re-encrypting the photo's content key to the album key — not implemented |
| Set album cover | — | **unsupported** | no SDK API and no encrypted-write HTTP path |

`DriveCrypto` is **decrypt-only** today (address→share→node→content-key→block decryption), so the
encryption primitives album writes require don't exist yet. Album writes therefore return
`AlbumError.unsupported(operation:gap:)` with the exact missing capability, and the upload destination
sheet disables those options with the same explanation. Listing/selection works.

### Exact gap to enable album upload end-to-end

1. Generate a new album node key pair + passphrase (PGP), encrypted to the photos-share key.
2. Encrypt the album name to a name session key; generate the album hash key.
3. `POST /drive/photos/volumes/{vol}/albums` with the encrypted material.
4. For add: re-encrypt each photo's content session key to the album node key and
   `POST …/albums/{album}/photos`.
5. For cover: `PUT …/albums/{album}` (or the cover endpoint) with the chosen photo link id.

Steps 1–2 and 4 require new encryption/signing helpers in `DriveCrypto`.

## Module map (modular feature foundation)

| Module | Kind | Responsibility |
|---|---|---|
| `PhotosCore` | pure | domain types + provider protocols |
| `AlbumsFeature` | pure | `AlbumManaging` + `AlbumsRepository` over an injected `AlbumBackend` |
| `UploadFeature` | pure | `UploadManaging` + `UploadManager` (queue/state-machine) over injected `PhotoUploading` + `AlbumAttaching`; folder enumeration; UI (`UploadDestinationSheet`, `UploadQueuePanel`) |
| `DriveSDKBridge` | app/SDK | implements `PhotoUploading` + the existing photo providers |
| `HTTPAlbumBackend` | app/HTTP | implements `AlbumBackend` (list works, writes unsupported) |
| `ProtonClientFacade` | app | composes the above so the UI never touches the SDK/HTTP layer |

Pure modules have **no** dependency on the SDK and are unit-tested in isolation
(`UploadFeatureTests`, `AlbumsFeatureTests`).
