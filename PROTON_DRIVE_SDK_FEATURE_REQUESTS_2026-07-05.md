# Proton Drive SDK / API Feature Requests for Proton Photos

Date: 2026-07-05  
Project: Proton Photos, an independent Apple-platform client for Proton Drive Photos  
Targets: macOS, iOS, iPadOS  
Primary goal: keep Proton end-to-end encryption intact while enabling reliable, high-performance photos backup, album sync, and future on-device AI search across the user's own devices.

This document is intentionally written as a product/SDK request, not as an implementation demand. The app can already work around some missing APIs with direct REST or visible files, but the requests below would let third-party clients build these features cleanly, safely, and in a Proton-compatible way.

## Summary

We would like Proton Drive to expose three related capabilities:

1. An app-private, end-to-end encrypted data namespace for client-owned metadata that syncs through Proton Drive but is not shown in the user's normal files or photos UI.
2. A background-compatible photo upload API that lets the SDK encrypt blocks to local files and lets the app upload those encrypted block files through Apple background `URLSessionUploadTask(fromFile:)`, then resume and commit safely after app relaunch.
3. Official album write and album metadata APIs in the Swift SDK, replacing direct REST usage for creating albums, adding photos, setting covers, and optionally storing small app-visible sync-state metadata.

The most important blockers are (1) and (2). Request (3) is lower urgency because direct REST can be made to work, but an official SDK path is safer for compatibility.

## Request 1: App-Private E2EE Data Namespace

### Problem

Some Proton Photos features need small account-scoped state that should sync across the user's devices but should not appear as normal user files, albums, photos, or trash items.

Examples:

- Album sync status: Device A is currently syncing local Apple Photos album "Family" into Proton album X, with 420 of 900 items processed. Device B can show a small "sync in progress" indicator next to the album.
- Future CLIP / AI search index: Mac or iPad computes encrypted embedding shards for photos; iPhone can reuse those shards instead of recomputing everything.
- Device coordination: which model version has indexed which photo revision, which shards are compacted, which work is stale, which device currently has a fresh lease.
- Feature-state manifests: schema versions, migrations, model versions, and stale leases.

Today, the only clean fallback is a visible folder such as `Proton Photos App Data/`. That is honest but not ideal. It exposes internal files to users, invites accidental deletion, and makes app state look like user content. A "hidden photo" or fake album is not acceptable: it pollutes the photos product model, risks classification/trash/dedupe side effects, and could break with future server behavior.

### Requested capability

Please expose an app-private, account-scoped E2EE object namespace, conceptually similar to:

```swift
protocol ProtonDriveAppDataStore {
    func putObject(
        appNamespace: String,
        key: String,
        data: URL,
        contentType: String,
        expectedRevision: String?
    ) async throws -> AppDataObjectRevision

    func getObject(appNamespace: String, key: String) async throws -> AppDataObject?
    func listObjects(appNamespace: String, prefix: String, cursor: String?) async throws -> AppDataObjectPage
    func deleteObject(appNamespace: String, key: String, expectedRevision: String?) async throws
}
```

API shape is flexible; the important contract is:

- End-to-end encrypted with the user's Proton Drive keys.
- Synced across all user's Proton Drive devices.
- Not listed in My Files, Photos, Albums, Recents, Search, Trash, or public sharing surfaces.
- App-scoped by product/client namespace, so unrelated apps cannot accidentally collide.
- Small and large object support, at least from a few KB manifests to multi-MB AI index shards.
- Revision / ETag / generation support for optimistic concurrency.
- Prefix listing and pagination.
- Atomic replace semantics.
- Delete and retention semantics clearly documented.
- Quota accounting clearly documented. It is acceptable if this counts toward user Drive storage; it just should not appear as normal content.
- No plaintext metadata leakage in object names where avoidable. If keys are visible to Proton servers, clients should be able to use opaque/content-addressed names.

### Why this matters for AI search

A future AI search feature should remain privacy-preserving and device-local in computation where possible. However, recomputing CLIP embeddings separately on every iPhone, iPad, and Mac is wasteful. The fastest/least constrained device should be able to compute index shards and let other devices reuse them.

The remote format would be append-only and conflict-tolerant, not a shared SQLite database. A likely layout:

```text
app-data://proton-photos/ai-index/
  clip/
    model-openclip-vit-b32-v1/
      manifest.json
      shards/
        00/00-2026-07-05T120000Z-macbook.jsonl.zst
        00/00-2026-07-05T121000Z-iphone.jsonl.zst
      tombstones/
      compacted/
```

Properties:

- Remote objects are immutable shards plus manifests.
- Local devices build their own search index from downloaded shards.
- Duplicate work is harmless: if two devices index the same photo revision, deterministic compaction removes redundancy.
- Embeddings should be encrypted at rest and in transit just like user data.
- No human-readable labels or generated captions need to be stored remotely by default.

### Minimum viable version

A first version can be much smaller than a full database:

- `putObject`, `getObject`, `listObjects(prefix:)`, `deleteObject`
- optimistic revision token
- per-object size up to at least 10 MB
- total namespace size discoverable
- no sharing
- no search integration

That would already unblock album sync status, feature manifests, and early AI index shards.

## Request 2: Background-Compatible E2EE Photo Uploads

### Problem

Apple platforms reward background uploads that are file-based and owned by the system. On iOS/iPadOS, `URLSessionConfiguration.background` can continue uploads while the app is suspended or relaunched, but only for file-based upload tasks. In-memory streams and data uploads cannot provide the same reliability after the app exits.

The current Swift SDK photo upload flow accepts a local file URL, which is good, but the encrypted block upload is fused into the SDK/native core and delivered through an in-memory stream to a foreground URLSession. This means:

- The app cannot give encrypted blocks to `URLSessionUploadTask(fromFile:)`.
- Upload state does not survive process death in a way the app can resume.
- A large video interrupted mid-transfer may need to restart its current item.
- The app can only make progress while foregrounded or during system-granted execution windows.

PhotoKit Background Resource Upload is not a replacement for Proton E2EE. Apple's API uploads the raw `PHAssetResource` to a destination request; there is no transform/encrypt hook that lets the app substitute Proton-encrypted bytes. Using it directly would send plaintext originals to the upload destination.

### Requested SDK capability

Please expose a lower-level upload split that decouples encryption/planning from transport:

```swift
let plan = try await photosClient.prepareEncryptedUpload(
    name: String,
    fileURL: URL,
    fileSize: Int64,
    modificationDate: Date?,
    captureTime: Date?,
    mainPhotoUid: SDKNodeUid?,
    mediaType: String,
    thumbnails: [ThumbnailData],
    expectedSHA1: Data?,
    additionalMetadata: [AdditionalMetadata]
)

// App uploads every encrypted block file with URLSessionConfiguration.background.
// After all block tasks report success:
let ids = try await photosClient.commitEncryptedUpload(
    commit: plan.commitDescriptor,
    blockResults: completedBlocks
)
```

Illustrative data model:

```swift
struct EncryptedUploadPlan: Codable, Sendable {
    let uploadID: String
    let draftID: String?
    let commitDescriptor: CommitDescriptor
    let blocks: [EncryptedUploadBlock]
    let expiresAt: Date?
}

struct EncryptedUploadBlock: Codable, Sendable {
    let index: Int
    let encryptedFileURL: URL
    let uploadRequest: URLRequest
    let expectedSize: Int64
    let checksum: Data?
}
```

Required semantics:

- The SDK performs all Proton encryption and writes encrypted block files to disk.
- The app never sees plaintext beyond the source file it already owns through PhotoKit/file access.
- Each block upload request is safe to execute later by `URLSessionUploadTask(fromFile:)`.
- The app can persist `EncryptedUploadPlan` and recover after process death.
- `commitEncryptedUpload` is idempotent or has a clearly documented reconciliation path.
- Server draft lifetime is documented.
- Upload plan supports Live Photo relationships (`mainPhotoUid`), additional metadata, expected SHA-1, thumbnails, and capture time exactly like the existing high-level upload.
- Background block transfer must be safe across app relaunch and out-of-process execution.
- If a block upload succeeds but the app dies before commit, the next launch can commit or reconcile without duplicating the photo.

### Why this preserves Proton architecture

This request does not ask the app to reimplement Proton cryptography. The SDK remains the cryptographic authority. The app only owns the transport of already-encrypted block files through Apple's background upload mechanism.

This also preserves a clean Core design in our app:

- Our universal backup queue, dedupe, retry, and progress model do not need to change.
- The implementation swap happens only behind the `PhotoUploading` backend.
- The capability flag can move from `supportsResumeAcrossRelaunch = false` to `true` once the SDK supports this flow.

### Optional server-side improvement

If Proton block storage can support the HTTP resumable upload draft used by modern `URLSessionUploadTask` resume APIs, a failed block could resume mid-block rather than restarting. This is useful for large videos but secondary to the main requirement: encrypted block files plus persistable commit state.

## Request 3: Official Album Write and Album Metadata APIs

### Problem

Proton Photos album sync needs to:

- list albums,
- create albums,
- attach existing photos to albums without re-uploading media bytes,
- set album cover,
- inspect album children,
- handle "already member" as convergence,
- optionally store small app-visible state such as "album sync is in progress on another device".

We can perform some operations via direct REST and clean-room node metadata encryption, but official SDK support would be safer and easier to keep compatible with Proton server changes.

### Requested capability

Please expose official Swift SDK APIs for:

```swift
protocol ProtonPhotosAlbumClient {
    func listAlbums() async throws -> [PhotoAlbum]
    func createAlbum(name: String) async throws -> PhotoAlbum
    func addPhotos(_ photoUIDs: [SDKNodeUid], to albumID: String) async throws -> AlbumAddResult
    func children(of albumID: String, cursor: String?) async throws -> AlbumChildrenPage
    func setCover(albumID: String, photoUID: SDKNodeUid) async throws
}
```

Optional metadata support:

```swift
func putAlbumAppMetadata(albumID: String, namespace: String, data: Data, expectedRevision: String?) async throws
func getAlbumAppMetadata(albumID: String, namespace: String) async throws -> AlbumAppMetadata?
```

If album-scoped app metadata is not desirable, the app-private data namespace from Request 1 is enough. The client can store records keyed by `remoteAlbumID`.

### Required behavior

- Adding an already-present photo should be an idempotent success or a typed "already member" result.
- Adding a photo must not upload media bytes again.
- Album writes must preserve Proton E2EE semantics and server-side duplicate handling.
- Partial failures must be visible per item.
- The API must support large albums through pagination/batching.

## Non-Goals / Rejected Workarounds

The following are intentionally not requested:

- No plaintext relay service.
- No private Apple APIs.
- No fake "hidden photo" carrying app metadata.
- No fake album used as a control channel.
- No shared SQLite database stored directly in Drive.
- No requirement for Proton to compute AI embeddings server-side.
- No request for Proton to see CLIP labels, captions, or plaintext semantic metadata.

## Expected Integration in Proton Photos

If Proton provides Request 1:

- Add `DriveAppDataStore` behind a pure Core protocol.
- Store album sync status and future AI index manifests as encrypted app-data objects.
- Keep local SQLite only as a cache/materialized index.
- Show cross-device status only when a remote lease is fresh; stale leases expire automatically.

If Proton provides Request 2:

- Replace the current foreground SDK upload backend with a background-capable backend.
- Keep the existing backup queue and dedupe pipeline unchanged.
- Use Apple background `URLSessionUploadTask(fromFile:)` for encrypted blocks.
- Finalize commits on relaunch/background session completion.

If Proton provides Request 3:

- Replace direct REST album write code with official SDK calls.
- Keep `AlbumSyncCore` unchanged.
- Continue treating album sync as strictly additive unless the user explicitly chooses a future remove mode.

## Questions for Proton

1. Is an app-private, E2EE, non-user-visible Drive data namespace planned for the Swift SDK or Drive API?
2. If not, is there an existing Proton-supported location for client-owned app state that does not show up in My Files, Photos, Albums, Recents, Search, or Trash?
3. Can the Photos SDK expose encrypted upload blocks as local files plus persistable commit state, so apps can use Apple background `URLSessionUploadTask(fromFile:)`?
4. Are Proton storage block PUTs idempotent and safe to execute out-of-process, out of order, or after app relaunch?
5. How long do upload drafts live, and can they be resumed or cleaned up by client identifier?
6. Can the Swift SDK expose official album create/add/list/children/set-cover operations?
7. Is there an official place for album-scoped app metadata, or should clients use a future app-private data namespace keyed by album id?
8. What is the recommended path for third-party apps to implement full-library iOS/iPadOS/macOS photo backup without duplicate uploads and without violating E2EE?

## References

- Apple background `URLSession` upload model: file-based background upload tasks are the durable path for uploads that should continue while the app is suspended or relaunched.
  - https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)
  - https://developer.apple.com/documentation/foundation/downloading-files-in-the-background
- Apple BackgroundTasks: useful for checkpointed foreground/BGProcessing work, but not a substitute for out-of-process file upload.
  - https://developer.apple.com/documentation/backgroundtasks
- Apple PhotoKit Background Resource Upload: useful only if the system may upload the original resource bytes directly; not suitable for Proton E2EE unless Apple or Proton provides a transform/encrypt hook.
  - https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background
- Proton Drive SDK:
  - https://github.com/ProtonDriveApps/sdk
- Current local Proton Photos architecture already has a universal backup queue, dedupe manifest, and album sync core. The missing pieces are SDK/API capabilities, not UI-only workarounds.

## Priority

1. Background-compatible encrypted upload plan and commit API. This directly improves reliability and battery/network behavior for iOS/iPadOS photo backup.
2. App-private E2EE data namespace. This unlocks clean cross-device state and future privacy-preserving AI index sharing.
3. Official album write SDK APIs. This removes direct REST surface area and makes album sync easier to maintain.
