# Universal Photo Backup/Sync — Architecture Audit & Implementation Plan

**Date:** 2026-07-05
**Branch audited:** `claude/ios-thumbnail-lod-quality-fix` (clean worktree; audit is read-only, this report is the only new file)
**Scope:** iOS/iPadOS Photos-library sync, macOS folder sync, macOS Photos-library sync, shared progress/dedupe/checkpointing, background execution, album-sync strategy.
**Non-goals of this run:** no implementation, no behavior changes, no GPL code, no private APIs.

---

## 1. Executive Summary

The universal sync core prepared in `0f5c3c36` / `ab5e6069` / `29d792b8` is **architecturally sound and genuinely universal**: identity, hashing, name correction, duplicate semantics, the backup preflight index, and the persistent sync queue all live in `UploadCore` with zero platform or SDK imports (enforced by `ProjectHygieneTests.testUploadCoreStaysPlatformAndSDKAgnostic`). What is missing is exactly what the seams predict: platform catalogs (PhotoKit, folder/FSEvents), a core orchestrator that drives the persistent queue end-to-end, scheduling adapters, and UI.

Headline findings:

1. **Transport reality bounds the background story.** The SDK uploads only from local file URLs through its own **foreground** `URLSession` (`URLSessionConfiguration.default` in `SDKHttpClient.swift:14`), with no held operation, no background-session support, and no resume across relaunch (`UploadBackendCapabilities.sdkUploader`, [UploadBackend.swift:55](Packages/ProtonPhotosKit/Sources/UploadCore/UploadBackend.swift:55)). Therefore iOS background sync must be designed as **checkpointed foreground bursts + `BGProcessingTask` catch-up windows**, not as a fire-and-forget background `URLSession`. This is a protocol/SDK constraint, not an app bug.
2. **Apple's new PhotoKit Background Resource Upload extension (iOS 26.1+) exists but is almost certainly incompatible with Proton E2EE** — the *system* uploads raw asset-resource bytes to an HTTPS endpoint using a resumable-upload protocol; there is no documented hook to encrypt bytes before upload. Track as a feasibility spike, never as a roadmap dependency (§8.4).
3. **PhotoKit gives us everything else we need, on both platforms**: streamed original bytes without conversion (`PHAssetResourceManager.writeData` writes progressively to file), Live Photo resource pairs, and — critically — **persistent change history across launches** (`PHPersistentChangeToken`, iOS 16+/macOS 13+), which makes "never rescan the whole library" an official, supported pattern on iOS *and* macOS.
4. **Two latent Core defects should be fixed before any sync runner is wired (P0 for backup semantics, not user-visible today):**
   - `.draftExists`, `.deletedRemotely`, and `.inconsistentRemoteState` skip decisions all surface as `UploadItemState.skippedDuplicate`, whose documented meaning is "your photo IS backed up" ([UploadModels.swift:66-68](Packages/ProtonPhotosKit/Sources/UploadCore/UploadModels.swift:66), [UploadManager.swift:242-249](Packages/ProtonPhotosKit/Sources/UploadCore/UploadManager.swift:242)). For a stale server draft (e.g. our own crashed upload), the photo is **not** backed up, and the state is terminal — a backup run would permanently misreport it as safe.
   - A crash while a sync-queue row is in `uploading`/`finalizing` leaves it in a state `nextRunnable` never selects again ([UploadBackupSyncQueue.swift:33-40](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/UploadBackupSyncQueue.swift:33), [UploadBackupSyncQueueStore.swift:90](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/UploadBackupSyncQueueStore.swift:90)). A startup recovery pass ("demote stale active states") is required.
   Neither is patched in this run (per instructions); the smallest safe fixes are specified in §12 Stage 0.
5. **GPL contamination risk: LOW.** All Proton-Drive-iOS marker greps are clean; no copied symbols, comments, types, or structure. Five files cite Drive-iOS internals *by name in doc comments* as behavioral references ("reimplemented from observed semantics, not its code"). Details and rating rationale in §5.
6. **Recommended next implementation:** Stage 0 (core semantics hardening) + Stage 1 (macOS folder sync adapter). Folder sync exercises the full universal engine end-to-end with the already-proven `fileURL` identity path, zero new permissions beyond one entitlement, and no PhotoKit/background-execution risk — it is the cheapest way to battle-harden the engine before the iOS PhotoKit adapter lands on top of it.

---

## 2. Current Code Map (verified first-hand)

### 2.1 UploadCore (universal, platform/SDK-agnostic — gate-enforced)

| Area | File | Role |
|---|---|---|
| Identity | [UploadIdentityModels.swift](Packages/ProtonPhotosKit/Sources/UploadCore/Dedupe/UploadIdentityModels.swift) | `UploadSourceIdentity` (kind: `fileURL` \| `photoLibraryAsset`; resource: `primary` \| `livePairedVideo`), `UploadResourceDescriptor`, `UploadIdentity` (correctedName, nameHash, sha1, contentHash), `RemotePhotoDuplicate` (+`LinkState` draft/active/trashed/deleted-as-nil, `clientUID` carried "for a future stale-draft cleanup"), `UploadDuplicateDecision` (upload / skip(reason) / uploadMissingSecondaries), `UploadIdentityRecord` (+ conservative `isValid` cache rules, `hashKeyEpoch`), seams `UploadIdentityStore`, `UploadHashing`, `UploadDuplicateChecking`, `UploadIdentityResolving` |
| Dedupe pipeline | [UploadDedupePipeline.swift](Packages/ProtonPhotosKit/Sources/UploadCore/Dedupe/UploadDedupePipeline.swift) | Actor: manifest fast path → cached/streamed SHA-1 → HMAC identity → batched (150) coalesced duplicate lookup → policy; persists identity **before** the remote check ("a crash never re-pays the hashing"); durable outcomes for uploaded/activeDuplicate; trashed recorded but re-checked every run |
| Decision policy | [UploadDuplicateDecisionPolicy.swift](Packages/ProtonPhotosKit/Sources/UploadCore/Dedupe/UploadDuplicateDecisionPolicy.swift) | One compound decision tree (name-hash disjointness → draft pre-filter → name+content match → link-state → secondary completeness) |
| Name correction | [ProtonPhotoNameCorrection.swift](Packages/ProtonPhotosKit/Sources/UploadCore/Dedupe/ProtonPhotoNameCorrection.swift) | trim → last-255 → delete invalid chars → SHA-1-uppercase placeholder fallback; byte-exact input to the name-hash HMAC |
| Hashing | [UploadContentSHA1.swift](Packages/ProtonPhotosKit/Sources/UploadCore/Dedupe/UploadContentSHA1.swift) | Streaming SHA-1 (512 KiB buffer, cancellation between chunks) + `UploadSHA1Accumulator` for hash-while-exporting (built for the future PhotoKit source) |
| Identity manifest | [UploadIdentityManifestStore.swift](Packages/ProtonPhotosKit/Sources/UploadCore/Dedupe/UploadIdentityManifestStore.swift) | `upload-manifest-v1.sqlite` (WAL, per-account dir, fail-closed reset), PK (source_kind, source_id, resource) |
| Backup preflight | [UploadBackupState.swift](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/UploadBackupState.swift) | `UploadBackupRevision` (µs-quantized Int64), `UploadBackupEditRevision` (.trustedNoContentEdits / .revision / .unavailable), `UploadBackupAssetSnapshot/Record`, actor `UploadBackupPreflightIndex.classify` → alreadyBackedUp / pendingUpload / newAsset / needsBackendCheck(unseenEditRevision \| unreliableEditRevision) |
| Backup state store | [UploadBackupStateStore.swift](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/UploadBackupStateStore.swift) | `upload-backup-state-v1.sqlite`, PK (…​, revision_us), per-source index |
| Sync queue | [UploadBackupSyncQueue.swift](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/UploadBackupSyncQueue.swift) | 10-state queue enum (discovered→checking→hashing→duplicateChecking→queuedForUpload→uploading→finalizing→ alreadyBackedUp/completed/failed/paused), `UploadBackupSyncQueueSummary` (progressFraction over resolved/total) |
| Sync queue store | [UploadBackupSyncQueueStore.swift](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/UploadBackupSyncQueueStore.swift) | `upload-backup-sync-queue-v1.sqlite`; stores identities + revisions, **not** export URLs ("platform adapters rematerialize resources when work resumes"); `nextRunnable(limit:)` state-filtered, updated_at-ordered |
| Sync engine | [UploadBackupSyncEngine.swift](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/UploadBackupSyncEngine.swift) | Actor: `scan(catalog)` streams `UploadBackupAssetCandidate`s → preflight classify → queue upsert; `markCompleted/markAlreadyBackedUp/markFailed`; `UploadBackupAssetCatalog` is THE platform seam |
| Source seams | [UploadSourceSeams.swift](Packages/ProtonPhotosKit/Sources/UploadCore/Dedupe/UploadSourceSeams.swift) | `UploadCompoundDescriptor` (primary+secondaries), `UploadCompoundSource`, `UploadBackupCheckpointing` |
| Manual queue | [UploadManager.swift](Packages/ProtonPhotosKit/Sources/UploadCore/UploadManager.swift) | Actor, maxConcurrent=3, **in-memory** job table, per-item task, dedupe prime on enqueue, partial-success album retry |
| UI façade | [UploadCoordinator.swift](Packages/ProtonPhotosKit/Sources/UploadCore/UploadCoordinator.swift) | `@MainActor @Observable` snapshot mirror |
| Backend seam | [UploadBackend.swift](Packages/ProtonPhotosKit/Sources/UploadCore/UploadBackend.swift) | `PhotoUploading` (upload/cancel/pause/resume + capabilities), `AlbumAttaching` |
| Folder walk | [FolderEnumerator.swift](Packages/ProtonPhotosKit/Sources/UploadCore/FolderEnumerator.swift), [SupportedMedia.swift](Packages/ProtonPhotosKit/Sources/UploadCore/SupportedMedia.swift) | Deterministic recursive media discovery; explicit extension→MIME table (13 types) |

**Three separate SQLite stores** (identity manifest / backup state / sync queue), all WAL, all "cache posture" (fail-closed reset when schema is from the future). All live in the per-account directory so sign-out purge covers them.

### 2.2 Backend (ProtonDriveBackend package target — the only SDK importer)

- `DriveSDKBridge: PhotoUploading` (DriveSDKBridge.swift:581) → `ProtonPhotosClient.uploadPhoto(name:fileURL:…expectedSHA1:…)` (Vendor/sdk-swift `ProtonPhotosClient.swift:203`).
- `UploadMediaProcessor` builds thumbnails client-side, **in memory, no temp files**: 512 px thumb + 1920 px preview, JPEG q0.7 (UploadMediaProcessor.swift:13-14,65).
- `ProtonUploadDedupeService` implements `UploadDuplicateChecking`: share bootstrap → root link `NodeHashKey` decrypt → HMAC-SHA256 name/content hashes; `hashKeyEpoch` = first 8 bytes of SHA-256(hashKey) as hex (ProtonUploadDedupeService.swift:81-129).
- `AlbumAttachingAdapter` bridges to `AlbumsRepository`; **add-photos and create-album throw `.unsupported`** (album-write crypto gap: "adding a photo re-encrypts its content key to the album key, which isn't implemented"); setCover works via direct REST.
- Composition root: `ProtonClientFacade.make(bridge:)` builds UploadManager(uploader: bridge, albums: adapter, identityResolver: bridge.makeUploadIdentityResolver(), maxConcurrent: 3) + UploadCoordinator. Both apps consume the facade (macOS `AppModel.swift:127`, iOS `MobileLibraryModel.swift:310-327`).

### 2.3 Apps / project

- **No PhotoKit anywhere** (zero `import Photos` in production; only planning comments in `UploadSourceSeams.swift`).
- **iOS Info.plist has no photo-library usage strings, no `UIBackgroundModes`, no `BGTaskSchedulerPermittedIdentifiers`.** Both targets deploy at **26.0** (`project.yml`), device family 1,2.
- macOS entitlements are minimal (sandbox + network.client + user-selected read-write) and **gate-tested** (`testMacAppKeepsSingleInstanceLaunchGuard` / entitlements test) — folder sync will need `com.apple.security.files.bookmarks.app-scope` added deliberately (not on the test's forbidden list).
- Settings UIs on both platforms already show the **upload check** progress row (`UploadPreparationStatus`), deliberately worded as "checking before upload," not "hashing" ([UploadModels.swift:204-206](Packages/ProtonPhotosKit/Sources/UploadCore/UploadModels.swift:204)).
- Post-upload timeline refresh exists on macOS (`MainView` retry-schedule polling via `refreshAfterUpload`); iOS has none yet.
- Verification gates: `scripts/verify-universal-core.sh` builds the core targets for generic iOS+macOS (UploadCore is in `CORE_TARGETS`); `scripts/verify-ios-app-shell.sh` runs inside `rebuild.sh`.

### 2.4 Tests today (UploadFeatureTests)

State machine + queue (UploadManagerTests, UploadManagerDedupeTests), dedupe pipeline + manifest (UploadDedupePipelineTests, UploadIdentityManifestTests), policy vectors (UploadDedupePolicyTests), folder enumeration, backup preflight semantics (UploadBackupStateTests — incl. revision drift → needsBackendCheck, trustedNoContentEdits seeding), sync queue store round-trips (UploadBackupSyncQueueTests), architecture hygiene (ProjectHygieneTests).

---

## 3. Apple API Findings (official docs only; URLs inline)

### 3.1 Photo access & enumeration

| Fact | Source |
|---|---|
| `PHPhotoLibrary.requestAuthorization(for:)` with `PHAccessLevel.readWrite` / `.addOnly`; iOS 14+, **macOS 11+**. The non-`for:` legacy APIs **report `.authorized` even when access is limited** — always use the `(for:)` variants. | https://developer.apple.com/documentation/photokit/phphotolibrary/requestauthorization(for:handler:) , https://developer.apple.com/documentation/photokit/phauthorizationstatus/limited |
| `.limited`: app sees only user-selected assets; **cannot create or fetch user albums**; selection updates via `presentLimitedLibraryPicker` (iOS/Catalyst only, **not native macOS**); suppress the per-launch reminder with `PHPhotoLibraryPreventAutomaticLimitedAccessAlert`. | https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app |
| Info.plist: `NSPhotoLibraryUsageDescription` (read/write), `NSPhotoLibraryAddUsageDescription` (add-only). | https://developer.apple.com/documentation/bundleresources/information-property-list/nsphotolibraryusagedescription |
| `PHAsset.fetchAssets(with:options:)` (iOS 8+, macOS 10.15+); `PHFetchResult` is officially lazy/batched: "dynamically loads its contents … keeping a batch of objects around the most recently accessed index" — safe for 100k assets. Supported sort/predicate keys include `creationDate`, `modificationDate`, `mediaType`. | https://developer.apple.com/documentation/photokit/phfetchresult , https://developer.apple.com/documentation/photokit/phfetchoptions |
| **Original bytes without conversion**: `PHAssetResource` (Apple names the use case: "like when backing up or restoring assets"), `originalFilename`, `contentType`, `dataSize`. `PHAssetResourceManager.requestData` "progressively provid[es] chunks of data"; `writeData(for:toFile:)` "progressively writes the data into the specified file" (streaming, no whole-file memory). `PHAssetResourceRequestOptions.isNetworkAccessAllowed` + `progressHandler` gate iCloud-original download. | https://developer.apple.com/documentation/photokit/phassetresource , https://developer.apple.com/documentation/photokit/phassetresourcemanager/writedata(for:tofile:options:completionhandler:) |
| **Live Photo** = `.photo` + `.pairedVideo`; edited assets add `.fullSizePhoto` / `.fullSizePairedVideo` + `.adjustmentData` (post-edit current content vs original). `PHAssetMediaSubtype.photoLive` iOS 9.1+/macOS 10.11+. | https://developer.apple.com/documentation/photokit/phassetresourcetype |
| **Edit evidence**: `PHAsset.modificationDate` moves on *content or metadata* changes (favorite toggles included) — drift evidence, not an edit counter. `PHAdjustmentData` / presence of `.adjustmentData`+`.fullSizePhoto` resources = resource-level edit signal. **No official per-edit revision/date API exists.** | https://developer.apple.com/documentation/photokit/phasset/modificationdate , https://developer.apple.com/documentation/photokit/phadjustmentdata |
| **Change observation**: `PHPhotoLibraryChangeObserver` (in-process, fetched-objects only). **Persistent change history**: `PHPhotoLibrary.currentChangeToken` (serializable) + `fetchPersistentChanges(since:)` → inserted/updated/deleted localIdentifiers per object type; throws `.persistentChangeTokenExpired` when history is gone (depth undocumented). **iOS 16+ AND macOS 13+.** | https://developer.apple.com/documentation/photokit/phphotolibrary/fetchpersistentchanges(since:) , WWDC22 10132 |
| **Identity**: `localIdentifier` is persistent per device but not portable; `PHCloudIdentifier` (`archivalStringValue`, mapping APIs iOS 15+/macOS 12+) is stable across devices syncing the same iCloud account; mappings are "expensive … perform lookups sparingly". Behavior across reinstall / without iCloud Photos: undocumented. | https://developer.apple.com/documentation/photokit/phcloudidentifier |
| macOS: everything above except the limited-library picker is native-macOS available. Whether native macOS ever returns `.limited`: undocumented. | availability tables on the pages above |

### 3.2 Background execution

| Fact | Source |
|---|---|
| `BGTaskScheduler` is iOS/iPadOS/Catalyst/tvOS/visionOS — **not native macOS**. `BGProcessingTaskRequest`: minutes-scale, `requiresExternalPower`, `requiresNetworkConnectivity`, runs when device is idle, **terminated immediately when the user starts using the device**; identifiers must be in `BGTaskSchedulerPermittedIdentifiers`; needs `processing` in `UIBackgroundModes`. Official general budget quote: "up to 30 seconds" for background-task runtime; heavy transfer work is directed to `URLSession`. | https://developer.apple.com/documentation/backgroundtasks/bgprocessingtask , https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app |
| **iOS 26**: `BGContinuedProcessingTask` — user-initiated in foreground, continues in background with **system Live-Activity progress UI**, user-cancelable, must report `progress`; optional GPU entitlement. **WWDC25 explicitly says: "Avoid automatic workloads like maintenance, backups, or photo syncing."** | https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados , https://developer.apple.com/videos/play/wwdc2025/227/ |
| **Background `URLSession`**: out-of-process transfers survive suspension/normal termination (force-quit cancels); "Only upload tasks from a file are supported (uploads from data instances or a stream fail after the app exits)"; per-task `URLRequest` headers are fine, so pre-encrypted block temp files ARE the supported E2EE pattern; system rate-limiter penalizes many small launches — "perform fewer, larger transfers"; `isDiscretionary` for bulk; `timeoutIntervalForResource` default 7 days; relaunch via `handleEventsForBackgroundURLSession`. | https://developer.apple.com/documentation/foundation/downloading-files-in-the-background , https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:) |
| Short continuation: `beginBackgroundTask(expirationHandler:)` — finite, un-numbered in current docs (~tens of seconds per WWDC20 10063); `ProcessInfo.performExpiringActivity` for extensions. | https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(expirationhandler:) |
| **PhotoKit Background Resource Upload extension** (headline): extension point `com.apple.photos.background-upload`; `PHBackgroundResourceUploadExtension` **iOS/iPadOS/Catalyst 26.1** (deprecated in 27.0 → `PHBackgroundResourceUploadJobExtension`, which adds **macOS 27.0 beta**); host enables via `PHPhotoLibrary.setUploadJobExtensionEnabled(true)` (needs `.readWrite`); jobs = `PHAssetResourceUploadJobChangeRequest.creationRequestForJob(destination: URLRequest, resource:)`; **the system uploads the resource bytes itself** (IETF resumable-upload draft; server must answer OPTIONS preflight + `104 Upload Resumption Supported`); download-only jobs exist (`creationRequestForDownloadJob`) for pre-fetching iCloud originals; in-flight `jobLimit`; not testable in Simulator. **No documented hook to transform (encrypt) bytes before upload.** | https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background , https://developer.apple.com/documentation/photos/phbackgroundresourceuploadjobextension |
| macOS App-Store-safe background: `SMAppService` login items/agents (WWDC22: works in MAS apps, user-consented); `NSBackgroundActivityScheduler` for deferrable periodic work ("automatic saves, backups, data maintenance"); **App Nap** throttles background apps — prevented for active work via `ProcessInfo.beginActivity(.userInitiated…)`; macOS does not iOS-style-suspend apps. | https://developer.apple.com/documentation/servicemanagement/smappservice , https://developer.apple.com/documentation/foundation/nsbackgroundactivityscheduler , https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html |
| Adaptive-throttle signals: `ProcessInfo.thermalState` (+notification), `isLowPowerModeEnabled` (+notification), `NWPath.isExpensive` / `isConstrained`. | https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property , https://developer.apple.com/documentation/network/nwpath |
| App Review: 2.5.4 (background modes only for intended purposes — no audio/location/VoIP abuse), 2.4.2 (no battery drain/heat), 5.1.1(iii) data minimization ("Where possible, use the out-of-process picker … rather than requesting full access") — a backup app's core functionality justifies full access, but the purpose string must say so plainly. | https://developer.apple.com/app-store/review/guidelines/ |

---

## 4. Proton SDK / Backend Reality Check

Answers to the mandated questions (evidence = vendored SDK 0.19.0 + backend sources):

1. **Upload input:** local **file URLs only**. `ProtonPhotosClient.uploadPhoto(name:fileURL:…)` (Vendor/sdk-swift/Sources/Client/ProtonPhotosClient/ProtonPhotosClient.swift:203-239); the path is handed to the SDK core; no Data/stream overload is exposed.
2. **Background URLSession:** **not possible today.** The app-owned HTTP adapter (`SDKHttpClient.swift:14-16`) uses `URLSessionConfiguration.default`; block bodies are pumped through bound streams (`httpBodyStream`) — exactly the shape background sessions **cannot** run after process exit ("uploads from … a stream fail after the app exits"). Encryption/chunking happens inside the SDK core per upload call; the app never sees block requests, so it cannot re-issue them as file-based background tasks.
3. **Resume after app kill:** **no.** Upload state is in-memory (`UploadManager.jobs`, UploadManager.swift:42); the bridge uses the `uploadPhoto` convenience (no held `UploadOperation` → no in-flight pause/resume either), honestly declared in `UploadBackendCapabilities.sdkUploader` ([UploadBackend.swift:52-57](Packages/ProtonPhotosKit/Sources/UploadCore/UploadBackend.swift:52)). The SDK has an internal draft concept and within-session resilience (`awaitUploadWithResilience`), but nothing exposed across relaunch. **Unknown: whether Proton auto-expires stale server drafts** (see §14 — this interacts with the `.draftExists` skip).
4. **Thumbnails/previews:** client-generated in `UploadMediaProcessor` (512 px thumb + 1920 px preview, JPEG q0.7, in-memory, EXIF-oriented, video poster via `AVAssetImageGenerator`), passed pre-built to `uploadPhoto(thumbnails:)`.
5. **Album attach:** `AlbumAttaching` seam → `AlbumAttachingAdapter` → `AlbumsRepository`; **add-photos/create are unsupported** (album-key re-encryption not implemented; SDK exposes no album-write API — matches the known "incubating" SDK status); setCover works via direct REST. Attach-after-upload failure is already modeled as **partial success** with an album-step-only retry (UploadManager.swift:270-279, 407-418) — the photo is never lost.
6. **Missing SDK APIs blocking parity:** album write crypto (create/add), Live-Photo metadata round-trip (SDK drops Tags/RelatedPhotos today; `mainPhotoUid` upload parameter exists and is plumbed), EXIF/capture metadata blob (SDK accepts `additionalMetadata`, app sends `[]`), cross-relaunch resumable upload, any background-transfer-compatible transport.

**Consequence for architecture:** every upload requires (a) a local file on disk and (b) the app process alive for the duration of that item's transfer. Checkpoint granularity is therefore **per resource**, not per byte-range: on kill, the current item restarts, everything before it is safely recorded (identity manifest row + `recordUploaded` outcome + backup-state row). The design below embraces that instead of pretending byte-resume exists.

---

## 5. GPL Contamination Risk Assessment

**Method:** marker greps over the whole repo (excluding `.build`), plus structural comparison of the audited upload/sync sources against the known shape of Proton Drive iOS (GPL-3.0).

Marker results — **all clean**:

| Marker | Hits |
|---|---|
| `PhotosSkippable`, `SkippableStatus`, `getAdjustmentDate`, `PhotoLibraryIdentifiersRepository`, `PhotoLibraryFetchResource`, `LocalPhotoLibraryLoadProgressController`, `ios-drive` | 0 |
| `ProtonDriveApps` | 1 — the **sdk-swift repo URL** in [docs/dependencies.md](docs/dependencies.md) (the vendored SDK is **MIT-licensed**, `Vendor/sdk-swift/LICENSE.md` — not GPL, safe to link) |
| `GPL` (case-insensitive) | only `logPlayer` substring false-positives |

What *does* exist — doc comments naming Drive-iOS internals as behavioral references, in exactly five files:

- [UploadDuplicateDecisionPolicy.swift:4-5](Packages/ProtonPhotosKit/Sources/UploadCore/Dedupe/UploadDuplicateDecisionPolicy.swift:4) (`PhotoConflictRemoteCheckValidator`, `PhotoConflictNameHashesStrategy` — "reimplemented from observed semantics")
- [ProtonPhotoNameCorrection.swift:5-6,62](Packages/ProtonPhotosKit/Sources/UploadCore/Dedupe/ProtonPhotoNameCorrection.swift:5) (`getNormalizedFilename`, `PhotoNameCorrectionPolicy`, `iosName` — "reproduced from its observed rules, not its code")
- [UploadDedupePipeline.swift:15](Packages/ProtonPhotosKit/Sources/UploadCore/Dedupe/UploadDedupePipeline.swift:15) (batch size 150)
- [UploadIdentityModels.swift:111-112](Packages/ProtonPhotosKit/Sources/UploadCore/Dedupe/UploadIdentityModels.swift:111) (`FindDuplicatesEndpoint` wire fields/`LinkState` values)
- UploadDedupePolicyTests.swift:7-8 (test vectors "mirror the observed behaviour")

Assessment per requested dimension:

- **Copied symbol names:** none. Every local type/function name is original (`UploadDuplicateDecisionPolicy` vs their validator/strategy names, etc.).
- **Copied comments:** none; local comments are original prose that *cite* the reference implementation.
- **Copied type structure:** no. The local architecture (Swift actors, protocol seams, raw-SQLite manifests, compound descriptors) does not resemble Drive iOS's structure.
- **Copied state machines:** the queue states here (`discovered/checking/hashing/…`) are generic pipeline vocabulary, not Drive-iOS naming (`PhotosSkippable`/`SkippableStatus` absent).
- **Algorithm structure:** the duplicate decision tree and name correction intentionally reproduce **externally observable protocol behavior** (what the server sees: name hash, content hash, link-state handling, 150-batch, placeholder names). Wire-format facts and remote-visible semantics are interoperability information, not copyrightable expression; matching them is required for the two clients to agree on "duplicate".

**Rating: LOW RISK** (not "clean" only because the comments document that a GPL app was studied as the behavioral reference, so this cannot claim clean-room provenance; not "needs rewrite" because no expression was copied and the reproduced behavior is interoperability semantics).
Recommendations: (1) keep the "observed semantics, not code" framing in those comments — it is accurate and protective; (2) never paste Drive-iOS code into this repo, including as comments or test fixtures; (3) when the PhotoKit adapter is built, do **not** replicate Drive-iOS's private-API tricks (e.g. its adjustment-date access) — §7.1 uses official evidence only. This is an engineering assessment, not legal advice.

---

## 6. Proposed Universal Architecture

### 6.1 Layering (one sentence)

Everything that decides stays in Core; everything that *touches an OS API* is an adapter that produces/consumes Core value types; each platform app only registers adapters and schedules ticks.

```
┌────────────────────────────── Core (UploadCore + new BackupCore files) ─────────────────────────────┐
│ UploadSourceIdentity · UploadCompoundDescriptor · UploadBackupAssetSnapshot/Revision/EditRevision   │
│ UploadBackupPreflightIndex · UploadBackupSyncEngine · UploadBackupSyncQueue(ManifestStore)          │
│ UploadDedupePipeline · UploadDuplicateDecisionPolicy · ProtonPhotoNameCorrection · SHA1             │
│ NEW: BackupSyncRunner (drains queue) · BackupRetryPolicy · BackupThrottlePolicy(inputs)             │
│ NEW: BackupProgressSnapshot/Aggregator · BackupSettings model · BackupTempFileStore (journaled)     │
│ NEW: AlbumMembershipIntentStore (queue of attach intents)                                           │
└──────────────┬────────────────────────────────┬────────────────────────────────┬───────────────────┘
               │                                │                                │
   PhotoLibraryBackupAdapter (new target,   FolderBackupAdapter (new target,  ProtonDriveBackend
   iOS+macOS — PhotoKit catalog/exporter/   macOS-first: bookmarks, FSEvents) (exists: uploader,
   change observer; NO fork per platform)                                      dedupe svc, albums)
               │                                │                                │
┌──────────────┴───────────────┐   ┌────────────┴─────────────┐   ┌──────────────┴──────────────┐
│ iOSApp: permissions UI,      │   │ App (macOS): folder      │   │ shared SwiftUI:             │
│ BGTaskScheduler registration,│   │ picker, login-item/      │   │ BackupFeature screens        │
│ scene-phase ticks            │   │ NSBackgroundActivity     │   │ (settings, progress, errors) │
└──────────────────────────────┘   └──────────────────────────┘   └──────────────────────────────┘
```

`BackupSyncRunner` is the missing piece between the persistent queue and `UploadManager`'s per-item machinery: an actor that (1) runs the startup recovery pass, (2) pulls `nextRunnable` batches, (3) asks the platform adapter to *rematerialize* each entry (export/locate the file), (4) drives descriptor → `UploadDedupePipeline.resolve` → `PhotoUploading.upload` → `markCompleted`, (5) applies retry/backoff and throttle policy, (6) publishes `BackupProgressSnapshot`s. It reuses `UploadDedupePipeline` and `PhotoUploading` directly rather than tunneling through the manual `UploadManager` (whose in-memory queue and UI semantics serve the drag-drop flow; both share the same seams so no semantics fork).

### 6.2 What stays universal (per requirement list)

| Requirement | Where it lives (existing/new) |
|---|---|
| Asset identity model | `UploadSourceIdentity` (existing). PhotoKit assets: `identifier = PHAsset.localIdentifier`; a new nullable `cloudIdentifier` column on the backup-state store (schema v2) records `PHCloudIdentifier.archivalStringValue` when cheaply available, enabling future cross-device recognition — content hashes remain the remote truth either way |
| Resource/compound model | `UploadCompoundDescriptor` + `Resource.livePairedVideo` (existing) |
| SHA/content hashing policy | `UploadContentSHA1` + `UploadSHA1Accumulator` (existing; hash-while-export for PhotoKit) |
| Proton name correction | `ProtonPhotoNameCorrection` (existing; input = `PHAssetResource.originalFilename` / file name) |
| Duplicate-detection semantics | `UploadDuplicateDecisionPolicy` + pipeline (existing) |
| Backup state machine | `UploadBackupPreflightIndex` + queue states (existing) + Stage-0 fixes (§12) |
| Sync queue / checkpointing | `UploadBackupSyncQueueManifestStore` (existing) + `BackupSyncRunner` recovery pass (new) |
| Retry/backoff | new `BackupRetryPolicy` (pure function: attempts → delay; 1s·2^n, cap 15 min, ±20% jitter; ≥8 attempts → parked `failed` needing attention) |
| Progress aggregation | new `BackupProgressAggregator` over `UploadBackupSyncQueueSummary` + live runner counters; one snapshot type for all three sync sources |
| Album membership intent | new `AlbumMembershipIntentStore` (§6.4) |
| No-photo-loss / no-double-upload | preflight + manifest + policy (existing) + data-safety fixes (§11) |
| Crash/relaunch resume | persistent queue + identity manifest (existing) + recovery pass + temp-file journal (new) |

### 6.3 Required architecture questions — direct answers

**iOS/iPadOS Photos sync**

- **Full access request:** `PHPhotoLibrary.requestAuthorization(for: .readWrite)` from the backup-onboarding screen (never at launch), preceded by an in-app explainer. Purpose string (de): *"Proton Photos benötigt Zugriff auf deine Mediathek, um deine Fotos und Videos verschlüsselt zu sichern."*
- **Limited access:** first-class state, not an error: `BackupAccessState.limited(selectedOnly)`. Backup runs over the selected subset; UI shows "Nur ausgewählte Fotos werden gesichert" with buttons for the limited-library picker and Settings deep-link. Set `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` and re-present the picker ourselves. Core never knows the difference — the catalog just yields fewer candidates.
- **Enumerate everything:** initial scan = `PHAsset.fetchAssets(with:options:)` per media type, sorted by `creationDate` descending (newest first = user-visible value first), `includeHiddenAssets = false` initially (decide with owner), iterate the lazy `PHFetchResult` in chunks of ~500 inside autoreleasepool; each asset → `UploadBackupAssetSnapshot` (resourceCount from `PHAssetResource.assetResources(for:)` only when needed — see fast path below).
- **Fast snapshot without touching resources:** revision = µs-quantized `asset.modificationDate ?? creationDate`; resourceCount = 1 + (subtype contains `.photoLive` ? 1 : 0). Resource enumeration happens only for queued work, keeping the scan O(assets) cheap.
- **Original bytes, no conversion:** `PHAssetResourceManager.writeData(for:toFile:options:)` into the journaled temp store — progressive disk write, original codec (HEIC stays HEIC, MOV stays MOV), `originalFilename` preserved into the descriptor; hash computed in the same pass via `dataReceivedHandler`+`UploadSHA1Accumulator` where we use `requestData`, or as a second streamed read of the temp file after `writeData` (simpler; still O(buffer) memory) — Stage 4 decides by measurement. Never `PHImageManager`, never JPEG conversion.
- **Metadata:** capture time from `asset.creationDate`, filename from `originalFilename`; EXIF stays embedded in the original bytes (that is the backup). The SDK's `additionalMetadata` stays empty until Proton documents the schema (§14).
- **Live Photos as compounds:** one `UploadCompoundDescriptor`: primary = photo resource, secondary = `.pairedVideo` with `source.resource = .livePairedVideo` and `mainResource` → primary; uploaded with `mainPhotoUid` (SDK parameter already plumbed). Edited assets: back up the **current** content (`.fullSizePhoto`/`.fullSizePairedVideo` when present, else originals) — matching "what the user sees is what is backed up"; note this in UI copy. (Backing up *both* original+edit is a future option; Proton's own model is current-content.)
- **Change observation after initial scan:** persistent history is primary: store `PHPersistentChangeToken` after each completed scan; on every activation/BG wake, `fetchPersistentChanges(since:)` → inserted/updated identifiers → snapshot+classify only those; deleted identifiers → mark queue rows `sourceMissing` (no remote action). `PHPhotoLibraryChangeObserver` is the live in-session trigger (debounced → incremental scan). `persistentChangeTokenExpired` → full rescan (cheap: preflight makes it read-mostly).
- **Avoid rehashing after app updates:** already solved twice over — preflight index skips known (source, revision) pairs without touching bytes; identity manifest reuses SHA-1s for unchanged name/size/mtime. Both stores survive updates (per-account dir, schema-versioned).
- **Edit handling without private APIs:** metadata-revision drift on a known asset → check official evidence: fetch resource set; if no `.adjustmentData`/`.fullSizePhoto` present → `.trustedNoContentEdits` (drift was metadata-only: favorite/album). If adjustment resources exist → `.unavailable` → `needsBackendCheck` → rehash current content and let content-hash dedupe decide (server-side no-op when content matches). This is strictly-safe and needs no `getAdjustmentDate`-style private API.
- **Local deletions initially:** never propagated. Queue rows for deleted assets get a terminal `sourceMissing`-style state (Stage 0 adds it), counted in UI as "nicht mehr auf diesem Gerät". Remote deletion sync is explicitly out of scope until a deliberate, opt-in design pass.

**macOS folder sync**

- **Selection & persistence:** NSOpenPanel folder pick → create **security-scoped bookmark** (`.withSecurityScope`), persist in a `BackupFolderRegistry` (app-side store, per account); resolve+`startAccessingSecurityScopedResource` around scan/hash/upload windows; stale bookmarks surface as a "Zugriff erneuern" row. Requires adding `com.apple.security.files.bookmarks.app-scope` to the entitlements (+ update the entitlements gate test deliberately).
- **Change observation:** FSEvents stream per root (coalesced, ~2 s latency) driving *incremental* re-enumeration of touched subtrees; a full `FolderEnumerator` sweep on app launch and on `NSBackgroundActivityScheduler` ticks as the safety net. (DispatchSource per-file watching does not scale to photo trees; FSEvents is the right primitive.)
- **Edits/renames/deletes:** identity is `UploadSourceIdentity.file(url)` (path-keyed) — a rename is a new source whose *content hash* matches remotely → server-side duplicate → skip; the old path becomes `sourceMissing`. mtime/size change → preflight revision drift → rehash → content-hash decides re-upload vs skip. Deletes → `sourceMissing`, never remote deletion.
- **False-skip protection:** the manifest's `isValid` already requires exact (name, size, mtime-as-persisted) equality; any drift forces rehash ([UploadIdentityModels.swift:250-255](Packages/ProtonPhotosKit/Sources/UploadCore/Dedupe/UploadIdentityModels.swift:250)). Equal-mtime-different-content (deliberate tampering) is accepted as out of threat model — same stance as Proton's clients.
- **Bounded hashing:** hashing runs only via the runner's bounded workers (§10); scan itself never reads file bodies.

**macOS Photos library sync**

- **Viable?** Yes — PhotoKit (fetch, resources, persistent history, `.readWrite` auth) is native-macOS since 10.15/11/13; our deployment target (26.0) clears all of it. Constraints: no limited-library picker on native macOS (treat `.limited`, if it ever occurs, as "manage in System Settings"), and iCloud "Optimize Mac Storage" means originals may need network download (`isNetworkAccessAllowed = true` + progress + disk-budget gating — same code path as iOS).
- **Phasing:** **defer behind folder sync AND the iOS adapter.** Rationale: folder sync validates the engine; iOS is where the DAU value is; the macOS Photos adapter then reuses the *same* `PhotoLibraryBackupAdapter` target — by design it is mostly free (§7.1).
- **Shared adapter:** yes — one `PhotoLibraryBackupAdapter` target compiled for both platforms (PhotoKit API surface used is identical); platform apps contribute only permission UI and scheduling. This satisfies the hard no-platform-forks rule.

**Background execution** → §8.
**UI/UX** → §9.

### 6.4 Album-sync strategy (shared where possible)

Blocked for *writes* by the album-crypto gap (add-photos re-encrypts the content key to the album key; unimplemented; SDK exposes no album-write API). Strategy:

1. **Now (universal, cheap):** `AlbumMembershipIntentStore` in Core — rows (source identity, album intent: local-album-name or Proton album id, state: pending/attached/failed). The PhotoKit catalog records each asset's album memberships as *intents* during scan; nothing executes.
2. **When album-write lands** (SDK or direct-REST + crypto): a Core `AlbumAttachOrchestrator` drains intents through the existing `AlbumAttaching` seam, with the existing partial-success semantics (upload safe, attach retryable) — no platform code involved.
3. UI meanwhile shows "Alben werden später verknüpft" honestly (or hides album sync entirely — owner call).

This keeps intent capture (which needs PhotoKit enumeration, happening anyway) decoupled from attach execution (which needs crypto that doesn't exist yet).

---

## 7. Platform Adapter Plan

### 7.1 `PhotoLibraryBackupAdapter` (new package target; iOS + iPadOS + macOS from one source)

Owns (all thin, all producing Core types):
- `PhotoKitAuthorization` — status mapping (incl. `.limited`), request flow.
- `PhotoKitBackupCatalog: UploadBackupAssetCatalog` — initial + incremental enumeration → `UploadBackupAssetCandidate` stream (lazy, cancellation-honoring, chunked).
- `PhotoKitEditEvidence` — resource-set inspection → `UploadBackupEditRevision` (official evidence only, §6.3).
- `PhotoKitResourceExporter` — rematerialize a queue entry: `writeData` → journaled temp file → `UploadCompoundDescriptor`; iCloud download progress passthrough; disk-budget guard.
- `PhotoKitChangeMonitor` — `PHPhotoLibraryChangeObserver` + persistent-change-token bookkeeping (token itself persisted via a Core seam so the resume story is testable).

Explicitly NOT here: retry logic, dedupe, queue writes, wording — all Core.

### 7.2 `FolderBackupAdapter` (macOS-first; the enumerator core is platform-neutral)

- `BackupFolderRegistry` — bookmark persistence/resolution (security-scoped; macOS app supplies the entitlement).
- `FolderBackupCatalog: UploadBackupAssetCatalog` — wraps the existing `FolderEnumerator` + per-file attributes → snapshots (revision = mtime).
- `FolderChangeMonitor` — FSEvents stream → debounced incremental scans.
- File descriptors need no export step — `fileURL` entries rematerialize by bookmark-scoped access, no temp copy, no disk budget.

### 7.3 Platform app responsibilities (only)

| | iOS/iPadOS | macOS |
|---|---|---|
| Permission prompts + Settings deep-links | ✅ | ✅ (Photos adapter phase) |
| Limited-library picker | ✅ | n/a |
| Security-scoped bookmarks UI | n/a | ✅ folder picker + renewal |
| BGTaskScheduler registration (`BGTaskSchedulerPermittedIdentifiers`, `UIBackgroundModes: processing,fetch`) | ✅ | n/a |
| `NSBackgroundActivityScheduler` + `beginActivity(.userInitiated)` wrapping | n/a | ✅ |
| Scene-phase / app-launch sync ticks | ✅ | ✅ |
| Thermal/power/network signal wiring → Core `BackupThrottlePolicy` inputs | ✅ (reuse `UIKitMemoryPressureCoordinator` pattern) | ✅ |
| Backup screens (thin hosts of shared `BackupFeature` views) | ✅ | ✅ |

---

## 8. Background Execution Plan

### 8.1 iOS/iPadOS (official APIs only; honest about limits)

Given §4 (foreground-bound transport), the model is **"make forward progress whenever the OS lets us, checkpoint every row, resume exactly"**:

1. **Foreground = primary engine.** Sync runs whenever the app is active (grid stays responsive per §10 budgets). This is also Proton Drive iOS's practical reality.
2. **On backgrounding:** `beginBackgroundTask` wrap-up window → finish the current *small* item or checkpoint mid-pipeline (queue row keeps its state; temp file journal entry survives), then stop cleanly before expiration.
3. **`BGProcessingTaskRequest`** (`requiresNetworkConnectivity = true`, `requiresExternalPower = true` for the bulk variant; a second no-power request with small batch size for top-ups): overnight-charging catch-up windows. Work in small transactional units; obey `expirationHandler` by checkpointing (never mid-DB-write thanks to WAL + row-granular transitions). Expect minutes, engineered so even 30 s makes progress (≥1 median photo end-to-end).
4. **`BGContinuedProcessingTask`: only for the explicit, user-tapped "Jetzt sichern" of the *initial* backup** — user-initiated one-shot with system progress UI fits its charter; automatic/recurring sync must NOT use it (WWDC25: "Avoid … backups, or photo syncing" for automatic workloads). Treat as an enhancement stage with an App-Review-risk note, default OFF until validated.
5. **Not used:** audio/location/VoIP keep-alive (forbidden, 2.5.4), silent-push schemes (unreliable, not in scope).
6. **What can/cannot run in background:** CAN — classification, hashing, export, uploads *within* granted windows. CANNOT — indefinite transfer after suspension (transport constraint). The UI must therefore say "Sicherung wird fortgesetzt, wenn du die App öffnest oder das Gerät lädt" instead of pretending.

**Checkpoint-before-suspension contract (Core):** every pipeline step is preceded by its queue-state write; temp exports are journaled (`BackupTempFileStore`: intent row → file → commit row) so relaunch can delete orphans and re-export deterministically; `UploadDedupePipeline` already persists identity before the remote check; `recordUploaded` runs before album/finalize steps. Resume = recovery pass (demote stale `uploading/finalizing/checking/hashing` rows → runnable) + `nextRunnable` drain. No user-visible duplicate work: preflight + manifest fast paths turn re-processing into O(1) row reads.

### 8.2 PhotoKit Background Resource Upload extension (iOS 26.1+/macOS 27 beta) — feasibility verdict

Mechanism recap (§3.2): host enables → system creates upload jobs per `PHAssetResource` with a destination `URLRequest` → **system uploads the raw resource bytes** (resumable-upload protocol, server must cooperate). For Proton E2EE this fails on three counts: (a) bytes must be client-encrypted into PGP-sessioned blocks before they touch the network — no transform hook exists; (b) Proton's upload is a multi-request choreography (draft, block list, commit), not a single resumable PUT; (c) the server would need IETF-resumable-upload support on an anonymous-ish endpoint. **Verdict: not adoptable for E2EE originals as documented.** Keep a small spike (Stage 7) to (1) confirm on-device behavior, (2) evaluate the *download-only* job type (`creationRequestForDownloadJob`) as an official way to pre-stage iCloud originals for later foreground encryption — that half MAY be genuinely useful — and (3) leave a design note for Proton SDK upstream.

### 8.3 macOS

- The app is long-running; the "background problem" is App Nap + not-launched.
- **While syncing:** `ProcessInfo.beginActivity([.userInitiated], reason: "photo backup")` around active runner work (prevents App Nap timer/I-O throttling); end when idle.
- **Periodic maintenance:** `NSBackgroundActivityScheduler` (interval ~1 h, deferrable, `.utility`) for rescans/change-token catch-up — Apple's documented use case is literally "backups".
- **Resume:** identical Core recovery pass at launch; macOS force-quit mid-upload behaves exactly like iOS kill (item restarts, earlier work checkpointed).
- **Login item (`SMAppService` agent) for sync-without-opening-the-app: defer.** MAS-compatible per WWDC22 but adds a second process, XPC, and sandbox complexity for marginal value while the main app auto-resumes on open. Revisit on user demand.
- Low-power/thermal/network throttling identical to iOS via the shared policy inputs.

---

## 9. UI/UX Plan (DAU-friendly, de-first wording)

Principles: never say "hashing"; never claim "uploading" while checking; never claim "backed up" unless the preflight/table says complete; always show a truthful next-step for background limits.

### 9.1 Onboarding (Backup tab / first-run card)

1. Value screen: "Sichere deine Fotos verschlüsselt bei Proton." → CTA "Sicherung einrichten".
2. Access prompt pre-screen (why full access helps; limited works too) → system dialog `.readWrite`.
3. Options screen: Wi-Fi only (default ON), "Auch über Mobilfunk" (with size hint), "Nur beim Laden" (iOS bulk default ON).
4. Immediately start the **check phase** with visible counts — first trust moment: "12.482 Fotos gefunden — wird geprüft…".

### 9.2 States & wording (String Catalog keys en+de; the `upload.*` keys pattern already exists)

| State | de (primary) |
|---|---|
| Scanning/classify | "Fotos werden geprüft… (3.214 von 12.482)" |
| Already safe | "9.881 bereits gesichert" |
| Uploading | "Wird gesichert… 412 von 2.601 · 1,2 GB verbleibend" |
| Paused (policy) | "Pausiert — wartet auf WLAN" / "…auf Ladegerät" / "Pausiert wegen Stromsparmodus" |
| Limited access | "Nur ausgewählte Fotos werden gesichert" + "Auswahl ändern" |
| Backgrounded | "Sicherung läuft weiter, sobald du die App öffnest oder das Gerät lädt" |
| Errors | "3 Elemente benötigen Aufmerksamkeit" → per-item sheet with retry |
| Source gone | "5 Fotos sind nicht mehr auf diesem Gerät" (informational) |
| Done | "Alle Fotos gesichert ✓ · zuletzt geprüft: heute 14:32" |

Trashed/deleted-remote skips are **not** counted as "gesichert": own bucket "Übersprungen (im Proton-Papierkorb)" with explainer — this depends on the Stage-0 skip-reason surfacing fix.

### 9.3 Settings structure (both platforms, shared `BackupFeature` views)

Backup section: master toggle per source (iOS: Mediathek; macOS: Ordner-Liste + später Fotos-Mediathek) · progress row (the states above) · Wi-Fi-only / cellular allowance · "Nur beim Laden" (iOS) · Pause/Fortsetzen · error list · storage row (Proton quota + local temp usage) · "Bereits gesichert" count with last-verified timestamp. Low-power behavior: auto-pause with the honest chip, no setting needed initially. macOS folder rows show bookmark health ("Zugriff erneuern").

### 9.4 Communication rules

- Pause is instant and durable (persisted `paused` states; survives relaunch).
- Progress bar = queue `progressFraction` (resolved/total) — checking counts as progress toward "geprüft", uploads get their own numerator; never a fake single bar mixing both silently (two-phase bar: "geprüft" then "gesichert").
- UI refresh throttled (§10); numbers change smoothly, not per-item flicker.

---

## 10. Performance Budgets (20k–100k assets, old devices, E2EE, user scrolling)

Hard rules (all already structurally supported): no main-thread hashing or PhotoKit export (runner is an actor; exports on background QoS `.utility`); no full-res decode for hashing (byte streams only); no JPEG conversion of originals; streaming reads (512 KiB buffer, existing); bounded temp files with journal + startup orphan sweep.

| Budget | Value | Rationale |
|---|---|---|
| Concurrent PhotoKit exports | **2** (1 under `.serious` thermal / low power) | exports are I/O+iCloud-bound; more just multiplies temp disk + memory |
| Concurrent hashing workers | **2**, shared I/O pool with exports (combined ≤ 4 I/O tasks) | SHA-1 streaming is disk-bound; keeps old-iPhone I/O pressure off the grid |
| Concurrent uploads | **3** (existing default) on Wi-Fi+power; **1** on cellular/low-power/`.serious` thermal; **0** on `.critical` | matches `UploadManager` default; SDK encrypt+upload is CPU-heavy per item |
| Scan chunk | 500 assets per autoreleasepool drain; queue upserts batched **250 rows/txn** | keeps `PHFetchResult` batch memory + WAL txns bounded; ~40–80 txns for 20k |
| Temp disk cap | **min(2 GiB, 10 % free disk)**; per-file guard: skip+park if free < 2× file size | Live-Photo pairs + 4K video safety; cap enforced before export, not after |
| Progress UI updates | coalesced ≤ **4 Hz** (250 ms), summary SQL ≤ 1 Hz during scan | matches existing coordinator snapshot pattern; no per-row notify |
| `nextRunnable` batch | 32 | one SQL round-trip feeds all workers for seconds |
| Retry/backoff | 1 s·2^attempts, cap 15 min, ±20 % jitter; ≥8 → parked | prevents hot-looping the API on outages (today: none — §12 Stage 0) |
| BGProcessingTask unit | ≤ 25 s per work unit before re-checking expiration | even the minimum official window makes ≥1 item of progress |
| First-run target | 20k library: classify-only scan ≤ ~2–3 min on old hardware (row reads + metadata only, no bytes) | preflight is O(1)/asset SQL; validated in Stage-0 perf test |

Thermal/power/network are **inputs to one Core `BackupThrottlePolicy`** (pure, unit-tested table like `GridPinchDensityPolicy`), fed by platform monitors — no scattered `if lowPower` in adapters.

---

## 11. Data Safety Matrix

Legend: ✅ safe today · 🔧 safe after Stage-0/engine integration · target behavior described.

| Scenario | Outcome (target) | Mechanism |
|---|---|---|
| Kill during export | ✅ no loss, no dupes | temp journal orphan-swept at launch; queue row still runnable; re-export |
| Kill during hash | ✅ | nothing persisted mid-hash; rehash on resume (manifest row only written after digest) |
| Kill during upload | 🔧 restart item | row stuck `uploading` → **Stage-0 recovery pass requeues**; server draft may remain → see draft row below; identity manifest spares rehash |
| Kill after upload, before album attach | ✅ photo safe | `recordUploaded` runs first; attach is an intent (§6.4) retried independently; partial-success model already exists for manual uploads |
| Kill after upload, before `recordUploaded` | ✅ no double upload | next run: manifest row valid → hashes reused → remote check finds ACTIVE duplicate → skip + outcome persisted |
| Network loss | 🔧 | item fails → `BackupRetryPolicy` backoff; queue persists; policy pauses uploads on path-unsatisfied |
| Token/session expiration | 🔧 | auth errors classified non-retryable-by-backoff → runner pauses globally ("Anmeldung erforderlich"), resumes after `ProtonAuthController` refresh/re-login; no state lost |
| Proton API partial success (e.g. commit ok, response lost) | ✅ | same as kill-before-record: content-hash duplicate check reconciles on retry |
| Live Photo: primary uploaded, paired video failed | ✅ semantics exist | per-resource queue rows + `uploadMissingSecondaries(primaryLinkID:missing:)` uploads only the video with `mainPhotoUid` on retry |
| Album attach failure after upload | ✅ | partial-success + intent store; photo never re-uploaded |
| Local edit while upload in flight | 🔧 | descriptor snapshot (name/size/mtime) is what's hashed+uploaded; a mid-flight edit changes mtime → next scan sees revision drift → re-classified; worst case = consistent pre-edit copy remotely, then the edited version uploads as new content |
| Local deletion while upload in flight | 🔧 | export already materialized → upload completes (photo saved — arguably the best outcome) OR file-read fails → row → `sourceMissing`; never crashes the runner |
| Remote duplicate ACTIVE | ✅ | skip `.activeDuplicate`, counted as backed up, manifest-remembered |
| Remote duplicate TRASHED | ✅ policy / 🔧 wording | skip (deliberate deletion), **re-checked every run** (not manifest-fast-pathed) — correct; UI must show "im Papierkorb", not "gesichert" (Stage 0) |
| Remote duplicate DELETED (state absent) | same as trashed | skip `.deletedRemotely`; own UI bucket; optional future "erneut sichern" override |
| Remote DRAFT on our name hash | ⚠️ **P0 gap → Stage 0** | today: terminal `skippedDuplicate` ("backed up") — wrong. Target: non-terminal `blockedByDraft` + backoff re-check; later stale-draft cleanup keyed on `clientUID` (field already carried) once SDK/REST exposes draft deletion |
| Crash leaves rows `uploading`/`finalizing` | ⚠️ **P0 gap → Stage 0** | recovery pass: on runner start, demote `checking/hashing/duplicateChecking/uploading` → runnable predecessors, `finalizing` → verify-then-complete |
| Double-scan races (two scans upserting) | ✅ | engine is an actor; queue PK upserts idempotent |
| Schema from the future / corrupt store | ✅ | fail-closed reset; stores are caches — cost is a re-scan, never data loss |

---

## 12. Staged Implementation Roadmap

Ordering rationale: harden semantics first (Stage 0) because everything sits on them; then **macOS folder sync before iOS PhotoKit** — it proves the whole engine (scan→classify→queue→upload→resume) using the already-shipping `fileURL` path, with no new permission model, no export step, no background constraints; the iOS adapter then lands on a battle-tested core. Shared UI model comes between, because both platforms need it and it forces the progress vocabulary.

Implementer key: **Fable** = semantics/concurrency-critical core; **Claude** = adapters/features/UI; **Codex** = mechanical wiring, tests, plumbing. (All stages need the owner's manual pass on-device.)

**Stage 0 — Core semantics hardening (P0)** — *Fable*
- Goal: fix the two latent defects; add the missing runner-facing policies. No behavior change for manual uploads except honest skip surfacing.
- Touch: `UploadModels.swift` (split `skippedDuplicate` into reason-carrying terminal state or add `skipReason` payload), `UploadManager.swift` (map `.draftExists` → non-terminal retryable, `.trashedDuplicate/.deletedRemotely` → distinct terminal), `UploadBackupSyncQueue(Store)` (add `sourceMissing`, `blockedByDraft` states + recovery-pass API `requeueStaleActive(before:)`), new `BackupRetryPolicy.swift`, new `BackupThrottlePolicy.swift`.
- Tests: policy tables (retry delays, throttle matrix), recovery-pass round-trips, draft-skip non-terminality, UI-facing skip-reason mapping; update `UploadManagerDedupeTests` vectors.
- Manual: manual-upload flow unchanged except duplicate-skip labels.
- Perf risk: none. Data-loss risk: reduces it. **This stage needs explicit owner authorization since it touches committed Core behavior.**

**Stage 1 — macOS folder sync (first real source)** — *Claude (adapter) + Codex (wiring/tests)*
- Goal: user picks folders; engine keeps them backed up incl. resume.
- Touch: new `FolderBackupAdapter` target (registry+catalog+FSEvents monitor), new Core `BackupSyncRunner` (queue drain over `PhotoUploading`+`UploadDedupePipeline`), `App/` folder-settings UI, entitlement `com.apple.security.files.bookmarks.app-scope` (+ entitlements gate-test update), `verify-universal-core.sh` target lists.
- New types: `BackupFolderRegistry`, `FolderBackupCatalog`, `FolderChangeMonitor`, `BackupSyncRunner`, `BackupTempFileStore` (journal used by PhotoKit later; folder path doesn't need temp copies).
- Tests: runner end-to-end with fake uploader (happy/crash-resume/backoff/pause), catalog snapshots (mtime revisions), FSEvents-debounce unit (protocol-faked), bookmark staleness surface.
- Manual: 10k-file folder, kill mid-run, relaunch resume, rename/edit/delete cases.
- Perf risk: low (bounded workers). Data-loss risk: low (file sources, no export).

**Stage 2 — Shared Backup settings/progress model + screens** — *Claude*
- Goal: one `BackupFeature` module: `BackupProgressAggregator`, `BackupSettings` (wifiOnly/cellular/chargingOnly/paused), state→wording mapping (§9), SwiftUI views hosted by both apps; replaces the ad-hoc `UploadPreparationSettingsRow` placement.
- Tests: aggregator math (two-phase progress), wording-state table incl. limited/paused/backgrounded, settings persistence.
- Perf: UI throttling budget test. Risk: none.

**Stage 3 — iOS/iPadOS PhotoKit adapter (foreground sync)** — *Fable (exporter/hash-while-export, evidence logic) + Claude (screens/permissions)*
- Goal: full library backup while app is open; Live Photos as compounds; limited access first-class.
- Touch: new `PhotoLibraryBackupAdapter` target (§7.1); iOS Info.plist `NSPhotoLibraryUsageDescription`; onboarding + Backup screens; change-token persistence seam in Core.
- Tests: snapshot mapping (subtype→resourceCount, revision quantization), edit-evidence table (adjustment-resource permutations→`UploadBackupEditRevision`), exporter journal (orphan sweep), compound assembly, limited-mode catalog behavior (protocol-faked PhotoKit seams — keep PhotoKit types behind thin wrappers so Core-level logic tests run in SPM).
- Manual: 20k+ real library, iCloud-optimized originals, Live Photos, edited photos, limited selection, kill/resume.
- Perf risk: **highest of all stages** (export+hash+upload while scrolling) — budgets §10 + `[BackupPerf]` os_signpost tracing. Data-loss risk: medium until soak-tested → ship behind a Settings toggle default-off first.

**Stage 4 — iOS background scheduling** — *Codex (registration/plumbing) + Fable (checkpoint review)*
- Goal: overnight catch-up. `UIBackgroundModes: processing,fetch`; `BGTaskSchedulerPermittedIdentifiers`; submit-on-background; expiration-checkpoint path; `beginBackgroundTask` wrap-up.
- Tests: work-unit chunking respects a fake expiration signal; scheduling-policy unit (when to request power-required vs top-up task). BG runtime itself is device-manual (Console + `[BackupBG]` logs).
- Risk: low (pure additive; runner already checkpoint-safe).

**Stage 5 — macOS Photos-library source** — *Claude*
- Goal: compile `PhotoLibraryBackupAdapter` for macOS, add source toggle + permission flow in macOS settings; `NSBackgroundActivityScheduler` rescans; `beginActivity` wrapping.
- Tests: adapter target builds+tests on macOS in core gate; auth-state mapping incl. undocumented-`.limited` fallback.
- Risk: low (shared code path).

**Stage 6 — Album membership intents (+ attach when unblocked)** — *Codex now, Fable when crypto lands*
- Goal: capture intents during PhotoKit scan; orchestrator ready; execution gated on album-write capability (`AlbumCapabilities.canAddPhotos`).
- Tests: intent store round-trips, orchestrator drains with fake `AlbumAttaching`, partial-success retry.
- Risk: none while gated.

**Stage 7 — Background Resource Upload extension spike** — *Fable*
- Goal: 1–2 day time-boxed on-device spike per §8.2; deliverable = short report; explicitly allowed to conclude "not adoptable"; evaluate download-only jobs for iCloud pre-staging.
- Risk: none (spike branch).

**Stage 8 — End-to-end stress & soak** — *Codex (harness) + owner (devices)*
- Goal: synthetic 100k-manifest scan benchmarks; 10k-file folder soak with random kills (scripted); iOS 20k library soak; memory ceiling assertions; duplicate-count invariant checks against a fake backend ledger ("no double upload" proven by ledger, not logs).
- Deliverable: perf report + regression tests wired into `swift test` where OS-independent.

---

## 13. Exact Tests Required (beyond existing suites)

Core (SPM, platform-free):
1. `BackupRetryPolicyTests` — delay table, jitter bounds, park threshold.
2. `BackupThrottlePolicyTests` — full matrix (thermal × power × path × settings) → worker counts.
3. `BackupSyncRunnerTests` — drain order; crash-resume (recovery pass demotes `uploading`); pause/resume; backoff scheduling; sourceMissing on vanished file; no-double-upload with a ledger-checking fake uploader; Live-Photo secondary-only retry.
4. `UploadBackupSyncQueueRecoveryTests` — `requeueStaleActive` state mapping incl. `finalizing`.
5. `UploadManagerSkipReasonTests` — draft → retryable; trashed/deleted → distinct terminal; UI labels.
6. `BackupTempFileStoreTests` — journal commit/orphan-sweep/cap enforcement.
7. `BackupProgressAggregatorTests` — two-phase fractions, limited-mode totals, wording-state mapping.
8. `AlbumMembershipIntentTests` — store + gated orchestrator.
9. `PhotoKitEditEvidenceTests` (adapter target, faked resource sets) — adjustment permutations → EditRevision.
10. `FolderBackupCatalogTests` — mtime-revision snapshots, rename-as-new-source semantics.
11. Hygiene additions: `PhotoLibraryBackupAdapter` may import Photos but not ProtonDriveSDK/UIKit-UI; UploadCore ban-list unchanged; entitlements test updated for the bookmark entitlement (deliberate).
12. Perf assertions (Stage 8): 20k-classify wall-clock budget on CI-class hardware; queue-summary query < 5 ms at 100k rows.

---

## 14. Open Questions / Blockers

1. **Server draft lifecycle** — does Proton auto-expire stale upload drafts? Determines how aggressive `blockedByDraft` re-checks can be and whether client-side draft cleanup (via `clientUID`) is required. *Next: observe a crashed upload's draft via the duplicates endpoint over 24–48 h; check sdk-swift `UploadControllerDisposeRequest` semantics.*
2. **Album-write crypto** — SDK roadmap (full SDK ~end 2026 per incubating status) vs. implementing content-key re-encryption over direct REST ourselves. Gates Stage 6 execution (intents proceed regardless).
3. **`additionalMetadata` schema** — undocumented; needed for capture-metadata parity. *Next: sdk-swift protobuf definitions / upstream question.*
4. **Persistent-change-history retention depth** — undocumented; token-expired → full-rescan path must stay cheap (it is, via preflight).
5. **Native-macOS `.limited`** — undocumented whether it occurs; adapter treats it defensively.
6. **`PHCloudIdentifier` without iCloud Photos** — undocumented; we only store it opportunistically, so no dependency.
7. **App Review 5.1.1(iii)** — full-access request needs the backup framing front and center; plan review notes accordingly.
8. **BGContinuedProcessingTask for initial backup** — WWDC25 wording is anti-backup for *automatic* workloads; user-initiated first backup is arguably in-charter but reviewer-risky. Decide at Stage 4 with owner.
9. **Stage-0 authorization** — fixing committed Core behavior (`skippedDuplicate` semantics) needs the owner's go-ahead per this run's constraints.

---

## 15. Final Recommendation

Implement next, in order:

1. **Stage 0 (core hardening)** — small, high-leverage, unblocks honest UX and crash-safe running; needs explicit owner approval since it adjusts committed Core semantics (draft-skip surfacing + recovery pass + retry/throttle policies).
2. **Stage 1 (macOS folder sync)** — first shippable sync feature; validates `BackupSyncRunner`, checkpointing, FSEvents incrementality, and the progress model end-to-end on the platform with zero background/permission risk.
3. **Stage 2 (shared settings/progress UI)** in parallel with late Stage 1 — both platforms consume it.

Then Stage 3 (iOS PhotoKit adapter) lands on a proven engine, followed by Stage 4 background scheduling. The PhotoKit upload extension remains a spike, not a plan dependency; album sync stays intent-only until the write-crypto gap closes.

The architecture rule holds throughout: **every decision named in §6.2 lives in Core once; platforms contribute only catalogs, permissions, scheduling, and screens.**

---

*Verification for this run: `git status --short --branch` clean before and after; the only change is this report file. No code was modified; no builds were run (none needed for a read-only audit).*
