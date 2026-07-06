# Maximal Apple-Compliant Background Strategy for Proton E2EE Photo Backup

**Date:** 2026-07-05
**Branch:** `claude/ios-thumbnail-lod-quality-fix` (working tree carries Fable's in-progress PhotoKit backup adapter — read-only for this run; this report is the only new file)
**Scope:** the *background-execution* strategy for iOS/iPadOS/macOS Photos-library + folder backup under Proton end-to-end encryption. This is the deep companion to [`SYNC_ARCHITECTURE_AUDIT_2026-07-05.md`](SYNC_ARCHITECTURE_AUDIT_2026-07-05.md); it extends §8 of that audit rather than repeating it.
**Mode:** proposal only. No production code was edited. All evidence is from local Xcode SDK headers (Xcode 26.5 `iPhoneOS.sdk` + Xcode-beta 27.0 `iPhoneOS27.0.sdk`), vendored Proton SDK source (MIT), current repository code, or official Apple documentation.

---

## 0. How to read this document

The task asks a hard question: *"find the maximal legitimate background window Apple gives us, and use every one of them, without breaking E2EE."* The honest answer has two layers:

1. **What we can ship today, entirely Apple-compliant, using the SDK exactly as it is.** This is a *checkpointed, opportunistic, multi-window* architecture. It is already ~80% built in Core (the `BackupSyncRunner` state machine) and ~40% wired on iOS (Fable's `BGProcessingTask`). The maximal-today plan adds four more legitimate windows and the entire macOS scheduler.
2. **What would make background backup *genuinely continue while suspended*** — the one thing Apple's background model rewards (out-of-process `URLSession` uploads from files) but the Proton SDK cannot currently feed. This needs one upstream SDK feature. §5 specifies it precisely, and §12 gives the exact questions to send Proton.

The product decision baked into this report (per the run's instructions): **do not hack around the SDK's private/unstable native-core internals to fake background uploads.** Ship layer 1 now; request layer 2 from the SDK; mark the seam so switching later changes *no Core semantics*.

---

## 1. Executive verdict

**A. PhotoKit Background Resource Upload (iOS 26.1+, the headline new API) is unusable for Proton E2EE, by construction.** The extension only pairs a `PHAssetResource` with an `NSURLRequest` *destination*; **the system uploads the raw original resource bytes** to that URL. There is **no byte-transform / encryption / data-provider hook** anywhere in the API — verified directly in the iOS 26.5 *and* iOS 27.0 headers. Using it for Proton would mean sending plaintext originals to a Proton endpoint = a hard E2EE/privacy violation. **Rejected for uploads.** (§6)

**B. iOS 27 does add a new hook — but it is a *scheduling* hook, not a crypto hook.** iOS 27.0 deprecates `PHBackgroundResourceUploadExtension.process()` and introduces `PHBackgroundResourceUploadJobExtension.processJobs() async` / `willTerminate() async`. It changes *when/how* the extension is invoked; the upload mechanism (system uploads the resource to a URL) is unchanged. It does **not** move the needle for E2EE. (§6.2)

**C. There is exactly one legitimate PhotoKit-background use for us: `creationRequestForDownloadJob(resource:)` (iOS 26.4).** It asks the system to pull an **iCloud original down to the device** in the background, without uploading anywhere. That is a real accelerator for our own later foreground/BGProcessing encrypt-and-upload of iCloud-optimized libraries. **Prototype/spike.** (§6.3, §7)

**D. The real ceiling on "backup continues while suspended" is the Proton SDK's transport shape, not Apple's background model.** The SDK's native core (a compiled **.NET runtime + patched gopenpgp** in `CProtonDriveSDK.xcframework`, driven over protobuf) owns block-splitting/encryption/commit and drives transfers **in-process** through an app-provided `HttpClientProtocol`, pushing each encrypted block through an **in-memory bound stream** (pulled a buffer at a time back from the live core via `StreamReadRequest`) on a **foreground** `URLSession`; its resumable state is **in-memory only** ([`UploadBackend.swift:55`](Packages/ProtonPhotosKit/Sources/UploadCore/UploadBackend.swift:55) declares `supportsResumeAcrossRelaunch: false`). Apple's background `URLSession` requires **file-based, out-of-process** uploads that survive suspension. The two do not meet today. (§4)

> **Refinement of the prior audit.** [`SYNC_ARCHITECTURE_AUDIT_2026-07-05.md`](SYNC_ARCHITECTURE_AUDIT_2026-07-05.md) §4.2 states *"the app never sees block requests, so it cannot re-issue them as file-based background tasks."* First-hand reading of [`SDKHttpClient.requestUploadToStorage`](Packages/ProtonPhotosKit/Sources/ProtonDriveBackend/SDKHttpClient.swift:54) shows the app **does** see each per-block storage `PUT` (URL + `pm-storage-token` headers + the encrypted block body as a `StreamForUpload`). The true blockers are narrower and therefore more *fixable*: the block ciphertext is delivered as an **in-memory stream, not a file**; the transfer is **synchronously coupled** to the native core's in-memory state machine; and neither the transfer nor the commit **survives process death**. This reframes the SDK ask (§5, §12) from "expose blocks at all" to "let the app own the block *file* transfers and let the commit resume from persisted state."

**E. The maximal *today* strategy is a job-lattice of tiny checkpointed steps drained opportunistically across five legitimate windows**, with every step persisted before its work so any window — even a 20-second one — makes durable forward progress and any interruption resumes exactly. Core already implements the checkpoint contract; the work is platform scheduler adapters. (§3, §7, §8)

**F. Core stays single-implementation.** Everything that *decides* (queue, dedupe, retry, throttle table, progress) lives once in `UploadCore`; everything that *touches an OS scheduling API* is a thin platform adapter that calls Fable's already-shared `PhotoLibraryBackupController.backgroundCatchUp()` / `syncNow()` / `stopSync()`. No business logic moves into the apps. (§7)

**Bottom line:** ship the checkpointed multi-window architecture now (it is close); adopt the PhotoKit *download-only* prefetch as a spike; treat PhotoKit background *upload* as permanently rejected for E2EE; and file one upstream SDK feature — "app-owned background block-file uploads with resumable commit" — that upgrades background reach from *opportunistic* to *continues-while-suspended* **without changing any Core semantics**.

---

## 2. Evidence table (header paths, file:line, official docs)

### 2.1 PhotoKit Background Resource Upload — local SDK header evidence

| Fact | Evidence (local header / interface) |
|---|---|
| `PHAssetResourceUploadJob` is **iOS-only, iOS 26.1+**; a job = a `resource` (`PHAssetResource`) uploaded to a `destination` (`NSURLRequest`). Terminal props `responseHeaderFields`/`error` (26.4). Class `jobLimit`. | `…/Xcode.app/…/iPhoneOS.sdk/System/Library/Frameworks/Photos.framework/Headers/PHAssetResourceUploadJob.h` — `NS_SWIFT_SENDABLE API_AVAILABLE(ios(26.1)) API_UNAVAILABLE(macos, macCatalyst, tvos, visionos, watchos)` |
| Job creation: `creationRequestForJob(destination:resource:)` (26.4), `createJob(destination:resource:)` (26.1, **deprecated** 26.4), plus `acknowledge`, `retry(destination:)`, `cancel` (26.4). **The only inputs are a URL request and a resource — no bytes callback.** | `…/Photos.framework/Headers/PHAssetResourceUploadJobChangeRequest.h` |
| **Download-only** job: `creationRequestForDownloadJob(resource:)` (26.4): *"registers a job that requests an asset resource be downloaded from iCloud to the device without uploading it to a remote server… performed asynchronously by the system over time… the system may subsequently purge the downloaded resource."* | `…/Photos.framework/Headers/PHAssetResourceUploadJobChangeRequest.h` |
| Enablement gate: `PHPhotoLibrary.setUploadJobExtensionEnabled(_:error:)` / `isUploadJobExtensionEnabled` (iOS 26.1, `API_UNAVAILABLE(macos…)`). *"To enable background uploads, you must have both full library access and register the extension with the extension point: `com.apple.photos.background-upload`."* | `…/Photos.framework/Headers/PHPhotoLibrary.h` (lines ~73–92) |
| **iOS 26.1 extension protocol** (to be deprecated): `PHBackgroundResourceUploadExtension { func process() -> PHBackgroundResourceUploadProcessingResult; func notifyTermination() }`. | `…/Photos.framework/Modules/Photos.swiftmodule/arm64e-apple-ios.swiftinterface` (Xcode 26.5) |
| **iOS 27.0 NEW extension protocol** replacing it: `PHBackgroundResourceUploadJobExtension { func processJobs() async -> …ProcessingResult; func willTerminate() async }`. Old protocol annotated `@available(iOS, introduced: 26.1, deprecated: 27.0, message: "Adopt PHBackgroundResourceUploadJobExtension instead")`. New protocol `@available(iOS 27.0, macOS 27.0, macCatalyst 27.0, *)`. | `…/Xcode-beta.app/…/iPhoneOS.sdk/System/Library/Frameworks/Photos.framework/Modules/Photos.swiftmodule/arm64e-apple-ios.swiftinterface` (lines 71–110) |
| `PHBackgroundResourceUploadProcessingResult` = `failure` / `processing` / `completed`. **No transform/encrypt member exists on any of these types.** | same swiftinterface |
| **macOS nuance:** the *protocol* `PHBackgroundResourceUploadJobExtension` claims `macOS 27.0`, but the operational *classes* `PHAssetResourceUploadJob(ChangeRequest)` remain `API_UNAVAILABLE(macos, macCatalyst)` in the shipped ObjC headers of both the iOS and macOS SDKs. Net: **no runnable upload/download jobs on macOS.** | `…/MacOSX.sdk/…/Photos.framework/Headers/PHAssetResourceUploadJobChangeRequest.h:19` = `API_AVAILABLE(ios(26.1)) API_UNAVAILABLE(macos, macCatalyst, …)` |

### 2.2 BackgroundTasks — local SDK header evidence

| Fact | Evidence |
|---|---|
| `BGProcessingTask`: *"Processing tasks run only when the device is idle. The system terminates any background processing tasks running when the user starts using the device."* Needs `processing` in `UIBackgroundModes`. **`API_UNAVAILABLE(macos)`.** | `…/iPhoneOS.sdk/System/Library/Frameworks/BackgroundTasks.framework/Headers/BGTask.h` — `API_AVAILABLE(ios(13.0), tvos(13.0)) API_UNAVAILABLE(macos) API_UNAVAILABLE(watchos)` |
| `BGProcessingTaskRequest`: `earliestBeginDate`, `requiresNetworkConnectivity`, `requiresExternalPower` (default NO). Docs: system fulfills *"within the next two days as long as the user has used your app within the past week."* | `…/BackgroundTasks.framework/Headers/BGTaskRequest.h` |
| **`BGContinuedProcessingTask` (iOS 26.0)**: user-initiated; *"present UI while in progress"*; **must report `NSProgressReporting`**; *"Tasks that appear stalled may be forcibly expired."* `updateTitle:subtitle:`. **`API_UNAVAILABLE(macos, tvos, visionos, watchos, macCatalyst)`.** | `…/BackgroundTasks.framework/Headers/BGTask.h` — `API_AVAILABLE(ios(26.0)) …` |
| `BGContinuedProcessingTaskRequest`: `title`/`subtitle` (shown to user), `strategy` (`.fail` / `.queue`; queued requests *"cancelled when the user removes your app from the app switcher"*), `requiredResources` (`.default` / `.gpu`; GPU needs entitlement `com.apple.developer.background-tasks.continued-processing.gpu`). Created for the *currently foregrounded app*; **`earliestBeginDate` is ignored** (runs now/soon). Identifier wildcard `<bundleID>.<context>.*`. | `…/BackgroundTasks.framework/Headers/BGTaskRequest.h` |
| `BGTaskScheduler` and *every* `BGTask*` type: **`API_UNAVAILABLE(macos)`.** macOS has no BackgroundTasks. | all `BackgroundTasks.framework/Headers/*` |

### 2.3 PhotoKit resource export + change history (both platforms)

| Fact | Evidence |
|---|---|
| Original bytes without transcoding, streamed to a file: `PHAssetResourceManager.writeDataForAssetResource:toFile:options:completionHandler:` and chunked `requestDataForAssetResource:…`; `PHAssetResourceRequestOptions.isNetworkAccessAllowed` (iCloud download) + `progressHandler`. macOS 10.15 / iOS 9. | `…/Photos.framework/Headers/PHAssetResourceManager.h` |
| Persistent change history across launches: `PHPhotoLibrary.currentChangeToken` + `fetchPersistentChangesSinceToken:` — **macOS 13 / iOS 16+.** The "never rescan the whole library" primitive, on both platforms. | `…/Photos.framework/Headers/PHPhotoLibrary.h` (`fetchPersistentChangesSinceToken:`, `currentChangeToken`) |

### 2.4 Repository & Proton SDK (transport reality)

| Fact | Evidence (file:line) |
|---|---|
| Uploader capabilities are honestly declared: **no in-flight pause/resume, no resume across relaunch.** | [`UploadBackend.swift:48-57`](Packages/ProtonPhotosKit/Sources/UploadCore/UploadBackend.swift:48) (`UploadBackendCapabilities.sdkUploader`) |
| The app owns the HTTP transport the SDK calls into (`HttpClientProtocol`); block bodies stream through **`URLSessionConfiguration.default`** (foreground) as an in-memory `httpBodyStream`. | [`SDKHttpClient.swift:14`](Packages/ProtonPhotosKit/Sources/ProtonDriveBackend/SDKHttpClient.swift:14), [`:54-90`](Packages/ProtonPhotosKit/Sources/ProtonDriveBackend/SDKHttpClient.swift:54) |
| The SDK exposes the transport seam publicly: `requestDriveApi`, `requestUploadToStorage(content: StreamForUpload)`, `requestDownloadFromStorage`. | `Vendor/sdk-swift/Sources/Client/ProtonDriveClient/HttpClientProtocol.swift:5` |
| The encrypted block is delivered to the app as an **in-memory bound-stream pair**, pumped on the main run loop — not a file. | `Vendor/sdk-swift/…/Networking/Model/StreamForUpload.swift:3`, `SDKHttpClient.swift:66-71` |
| Upload orchestration (block split, encryption, draft, commit, resumable state, expectedSHA1) lives in the **compiled native core (.NET runtime + patched gopenpgp), behind protobuf**; the Swift layer drives it via `Proton_Drive_Sdk_UploadController*` requests; operation state is in-memory (`resume()` works in-process only). The app receives the ciphertext only as a **live pull-stream** (`StreamReadRequest` back into the core), never as a file or `Data`. | `Vendor/sdk-swift/Sources/FileOperations/Uploads/UploadOperation.swift:90-157`, `…/StreamForUpload.swift:113-121`, `sdk-swift/Package.swift` (`.binaryTarget CProtonDriveSDK` + `libbootstrapperdll` .NET bootstrapper) |
| The high-level upload is a fused convenience over a lower-level `uploadOperation`/`startUpload`; even the lower-level path transfers through the in-memory streaming seam. | `Vendor/sdk-swift/Sources/Client/ProtonPhotosClient/ProtonPhotosClient.swift:217-268` |
| **Vendored SDK is MIT** (Proton AG). GPL applies only to the Proton *Drive iOS app*, studied for behavior only. | `Vendor/sdk-swift/LICENSE.md` |

### 2.5 Core state machine + Fable WIP (what already exists)

| Fact | Evidence (file:line) |
|---|---|
| Universal Core cannot import `UIApplication`/`NSApplication`/UIKit/AppKit → **schedulers must be platform adapters**, calling into Core. | [`docs/core-architecture-contract.md:56-58, 212-213`](docs/core-architecture-contract.md:56) |
| `BackupSyncRunner` — the universal drain actor. `runUntilDrained()` (crash-recovery-first) and `stop()` (cancel-and-revert-to-runnable) are the two entry points a scheduler needs. Every transition persisted **before** the work; manifest recorded **before** the queue row turns terminal. | [`BackupSyncRunner.swift:32-186`](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/BackupSyncRunner.swift:32), [`:342-392`](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/BackupSyncRunner.swift:342) |
| Throttle inputs already model thermal / low-power / constrained / expensive → concurrency (critical ⇒ 0 = pause). Core never reads OS state; adapters inject it. | [`BackupThrottlePolicy.swift:19-62`](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/BackupThrottlePolicy.swift:19) |
| Crash-safe temp export store: `.partial`→`commit` rename, `sweep()` at start, disk-budget `reserve()` via `volumeAvailableCapacityForImportantUsage`. | [`BackupTempFileStore.swift:15-97`](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/BackupTempFileStore.swift:15) |
| **Fable's shared orchestrator already exposes the Core-side background seam**: `backgroundCatchUp()` ("one full catch-up pass for OS background windows (BGProcessingTask on iOS)… stopped by the expiration handler via `stopSync()`"), `syncNow()`, `stopSync()`; throttle wired to `ProcessInfo.thermalState` + `isLowPowerMode`. | `Packages/…/PhotoLibraryBackupAdapter/PhotoLibraryBackupController.swift:128-188` |
| **Fable's iOS scheduler rung already built**: registers `BGProcessingTask` handler; on scenePhase `.background` submits `BGProcessingTaskRequest` (`requiresNetworkConnectivity = true`, `requiresExternalPower = true`); handler runs `backgroundCatchUp()`, reschedules, completes; expiration → `stopSync()` + cancel. | [`iOSApp/ProtonPhotosMobileApp.swift:55-87`](iOSApp/ProtonPhotosMobileApp.swift:55) |
| iOS Info.plist: `BGTaskSchedulerPermittedIdentifiers = [me.protonphotos.ios.photo-backup.processing]`, `UIBackgroundModes = [processing]`. macOS entitlements: sandbox, app-scope bookmarks, user-selected read-write, network client, **`com.apple.security.personal-information.photos-library`**. | `iOSApp/Info.plist:27-33`, `App/ProtonPhotos.entitlements` |

### 2.6 Official Apple documentation (canonical URLs)

These corroborate the header facts and cover the non-header semantics. (Many are already gathered in the prior audit §3; kept here for a single evidence surface.)

- Background `URLSession` (file-only uploads survive suspension; stream/data uploads fail after exit; discretionary; relaunch): <https://developer.apple.com/documentation/foundation/downloading-files-in-the-background> · <https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)>
- Choosing background strategies: <https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app>
- Long-running tasks (BGContinuedProcessingTask) + WWDC25 framing (*"Avoid automatic workloads like maintenance, backups, or photo syncing"* for automatic scheduling): <https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados> · <https://developer.apple.com/videos/play/wwdc2025/227/>
- `beginBackgroundTask(expirationHandler:)` finite grace: <https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(expirationhandler:)>
- PhotoKit background resource upload (system uploads the resource; resumable-upload protocol; download-only jobs): <https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background> · <https://developer.apple.com/documentation/photos/phbackgroundresourceuploadjobextension>
- macOS: `NSBackgroundActivityScheduler` (Apple's example use includes *"backups"*), App Nap / `ProcessInfo.beginActivity`, `SMAppService`: <https://developer.apple.com/documentation/foundation/nsbackgroundactivityscheduler> · <https://developer.apple.com/documentation/foundation/processinfo/beginactivity(options:reason:)> · <https://developer.apple.com/documentation/servicemanagement/smappservice>
- Throttle signals: `ProcessInfo.thermalState`, `isLowPowerModeEnabled`, `NWPath.isExpensive`/`isConstrained`: <https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property> · <https://developer.apple.com/documentation/network/nwpath>
- App Review 2.5.4 / 2.4.2 / 5.1.1(iii): <https://developer.apple.com/app-store/review/guidelines/>

---

## 3. Job graph / state machine (the job-lattice)

The design principle: **decompose one photo's backup into the smallest steps that are each individually persisted, cheap, and resumable, so any background window — however short — completes at least one step durably.** Core already encodes this as a 10-state queue drained by `BackupSyncRunner`; the lattice below is that machine, annotated with *which OS window each step is safe in* and *what checkpoint guarantees resumability*.

### 3.1 Per-item micro-step lattice

```
   ┌─────────────┐   persist row=discovered
   │ 0 DISCOVER  │   (scan / persistent-change token → queue upsert)              cost: O(1) SQL
   └──────┬──────┘   [safe: FG, BGProcessing, BGContinued, macOS-idle]
          │
   ┌──────▼──────┐   persist row=checking BEFORE reading bytes
   │ 1 RESOLVE   │   PhotoLibraryResourceResolver.resolve → export original to    cost: iCloud dl + disk write
   │  (export)   │   BackupTempFileStore (.partial→commit); iCloud dl if optimized [FG, BGProcessing(power), macOS]
   └──────┬──────┘   ← download-only PhotoKit job (§6.3) can PRE-STAGE this
          │
   ┌──────▼──────┐   persist identity BEFORE remote call (pipeline invariant)
   │ 2 IDENTIFY  │   stream SHA-1 (512 KiB buf) → HMAC name/content hashes         cost: disk-bound hash
   └──────┬──────┘   [FG, BGProcessing, macOS]  (skippable via manifest fast path)
          │
   ┌──────▼──────┐   batched remote duplicate lookup (coalesced 150)
   │ 3 DEDUPE    │   decision: upload / skip(reason) / uploadMissingSecondaries    cost: 1 network round-trip
   └──────┬──────┘   [FG, BGProcessing, macOS]
          │  ├─ skip(activeDuplicate/known) → settle secondaries → alreadyBackedUp (terminal)
          │  ├─ skip(trashed/deleted)        → skippedRemoteDeletion (terminal, NOT "backed up")
          │  └─ draftExists                  → blockedByDraft (non-terminal, capped backoff)
          │
   ┌──────▼──────┐   persist row=uploading BEFORE transfer
   │ 4 UPLOAD    │   PhotoUploading.upload(fileURL) → encrypted blocks → commit    cost: CPU(encrypt)+network
   │  (primary)  │   ┄┄ TODAY: in-process, foreground URLSession, NOT suspend-safe ┄┄  ← the ceiling (§4/§5)
   └──────┬──────┘   [FG, BGProcessing while app alive; NOT after suspension today]
          │  persist identity manifest (recordUploaded) BEFORE row terminal
   ┌──────▼──────┐
   │ 5 SECONDARY │   Live Photo paired video etc. via same pipeline, mainPhotoUID  cost: repeat 1–4 per secondary
   └──────┬──────┘   [same windows as 4]
          │
   ┌──────▼──────┐   preflight.markBackedUp → row=completed (terminal)
   │ 6 FINALIZE  │   (album-attach intent recorded separately, drained when crypto lands)
   └─────────────┘
```

### 3.2 Why every window makes progress — the checkpoint contract (already in Core)

- **Persist-before-work:** each `transition(...)` writes the queue row *before* the expensive step it names ([`BackupSyncRunner.swift:500-512`](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/BackupSyncRunner.swift:500)).
- **Manifest-before-terminal:** `recordUploaded` runs before the row turns `completed`, so a crash between them re-resolves to a *remote duplicate*, never a re-upload ([`:382-391`](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/BackupSyncRunner.swift:382)).
- **Crash recovery on start:** `requeueStaleActive` demotes any `checking/hashing/uploading/finalizing` row left by a dead run back to runnable ([`:144`](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/BackupSyncRunner.swift:144)).
- **Graceful expiration:** `stop()` cancels in-flight transfers and reverts touched rows to a runnable predecessor without burning a retry attempt ([`:117-123`](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/BackupSyncRunner.swift:117), [`:579-589`](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/BackupSyncRunner.swift:579)) — this is exactly what a `BGTask.expirationHandler` or a `beginBackgroundTask` timeout calls.
- **Crash-safe exports:** temp files are `.partial` until `commit`, swept at start; disk budget reserved before writing ([`BackupTempFileStore.swift`](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/BackupTempFileStore.swift)).

**Granularity today is per-resource (whole file), not per-byte-range.** A window that dies mid-transfer of one large video loses *that item's* transfer progress (re-uploaded next window), but nothing before it. This is acceptable for photos and small clips; it is the specific weakness a large 4K/ProRes video exposes, and the reason §5's SDK feature (per-block file resume) matters.

---

## 4. Transport reality — the precise ceiling (Q1/Q5 groundwork)

The call chain, verified first-hand:

```
BackupSyncRunner.upload(fileURL)                      [UploadCore, universal]
  → PhotoUploading.upload(request)                    [UploadBackend.swift:69 — the ONE SDK seam]
    → DriveSDKBridge → ProtonPhotosClient.uploadPhoto(name:fileURL:…expectedSHA1:)   [SDK convenience]
      → UploadOperation.awaitUploadWithResilience()   [drives native core via protobuf]
        → native core splits + ENCRYPTS each block, then calls back:
          → SDKHttpClient.requestUploadToStorage(url, StreamForUpload, headers)      [APP owns this]
            → URLSession(configuration: .default).data(for: req)   req.httpBodyStream = block ciphertext
```

Consequences that bound the background story:

1. **File-in, but foreground-out.** The SDK accepts a local *file URL* for the source (good — no in-memory original), but the block *transfer* is an **in-memory `httpBodyStream`** on a **foreground default `URLSession`**. Apple is explicit: background sessions support **only file-based upload tasks**; *"uploads from data instances or a stream fail after the app exits."* So the current transfer cannot be a background task.
2. **The transfer is synchronously coupled to the native core's in-memory state machine.** The core hands one block to `requestUploadToStorage`, awaits the HTTP response inline, then advances. It is not designed to hand off a block, suspend the process, and resume from an OS background completion event.
3. **No resume across relaunch.** Operation state lives in the native core's memory ([`UploadBackend.swift:33-34`](Packages/ProtonPhotosKit/Sources/UploadCore/UploadBackend.swift:33) declares this; `UploadOperation.resume()` is in-process only). A killed upload restarts that item from scratch.
4. **But the app already holds the ciphertext at the seam.** `requestUploadToStorage` receives the encrypted block body and the pre-signed storage URL + `pm-storage-token`. This is why §5's feature is an *incremental* SDK change, not a rewrite: the encryption boundary is already app-visible.

**Therefore the maximal *today* reach is "app-process-alive windows":** foreground, the `beginBackgroundTask` grace period, and `BGProcessingTask` execution time — during each of which the runner drains whole items. Beyond that (true suspended-transfer continuation) needs §5.

---

## 5. "Magical but possible" plan — app-owned background block-file uploads (needs one SDK feature)

**Goal:** upgrade window (4) UPLOAD from "in-process, foreground-only" to "app-owned, file-based, out-of-process, resumable across relaunch" — i.e. real Apple background `URLSession` uploads — **without the app touching Proton crypto and without changing any Core semantics.**

### 5.1 Target SDK capability (the feature request)

A lower-level, transport-decoupled upload API on `ProtonPhotosClient` shaped like this (names illustrative):

```
// 1. Plan: encrypt to disk, no network.
let plan = try await client.prepareEncryptedUpload(
    name:, fileURL:, fileSize:, modificationDate:, captureTime:,
    mainPhotoUid:, mediaType:, thumbnails:, expectedSHA1:, additionalMetadata:)
//   → EncryptedUploadPlan {
//        draftToken,                                   // server draft handle, persistable
//        blocks: [ EncryptedBlock {
//            index, encryptedFileURL,                  // ciphertext ON DISK (temp file)
//            uploadURL: URLRequest,                    // pre-signed storage PUT + pm-storage-token
//            expectedSize, sha256 } ],
//        commit: CommitDescriptor                      // everything needed to finalize, persistable/Codable
//     }

// 2. Transfer: APP owns this — background URLSessionUploadTask(with: block.uploadURL, fromFile: block.encryptedFileURL)
//    on URLSessionConfiguration.background(withIdentifier:). Survives suspension; file-based; resumable.

// 3. Finalize: after all blocks report success (even across relaunch, from the persisted plan):
let ids = try await client.commitEncryptedUpload(plan.commit, blockResults: [...])   // draft → committed revision
```

Required properties (mapped to the run's target-feature list):

- **prepare an encrypted upload plan from a local original file** → `prepareEncryptedUpload` returns block ciphertext files + a commit descriptor.
- **persist encrypted block files locally** → blocks are `encryptedFileURL`s in our `BackupTempFileStore` (journaled, budget-capped, crash-swept — already built).
- **upload those block files via app-owned background `URLSessionUploadTask(fromFile:)`** → each block is a plain `PUT` to a pre-signed URL with token headers; nothing secret is in the request beyond ciphertext. Configure the session `background(withIdentifier:)` with `isDiscretionary = true` + `waitsForConnectivity = true` (Apple's recommended posture for bulk backup — the system picks power/network-favorable windows), `sessionSendsLaunchEvents = true` (relaunch the app on completion to finalize), `allowsConstrainedNetworkAccess = false` / `allowsExpensiveNetworkAccess = false` (respect Low-Data-Mode / cellular), and a generous `timeoutIntervalForResource` (default 7 days) for large videos. Apple is explicit that background sessions support **only** `uploadTask(with:fromFile:)` — *"uploads from data instances or a stream fail after the app exits."*
- **commit/finalize after transfers complete** → `commitEncryptedUpload(commit, blockResults)`; idempotent so a lost commit response reconciles via content-hash dedupe.
- **resume safely after crash/relaunch** → `EncryptedUploadPlan`/`CommitDescriptor` are `Codable` and persisted; on relaunch we re-attach to the background session's completed tasks via `application(_:handleEventsForBackgroundURLSession:completionHandler:)` (store the handler, recreate the session by identifier, finalize on `urlSessionDidFinishEvents`) and commit.
- **Live Photo primary/paired video, expectedSHA1, capture metadata, duplicate checks** → `prepareEncryptedUpload` already takes `mainPhotoUid`, `expectedSHA1`, `additionalMetadata`, thumbnails; dedupe stays in Core's pipeline (unchanged).

### 5.2 Why this is E2EE-safe and App-Review-safe

- Only **ciphertext** ever leaves the device (the SDK encrypts during `prepareEncryptedUpload`; blocks are opaque encrypted bytes). No plaintext to any relay/endpoint.
- The transfer is a stock background `URLSession` upload of a file — Apple's blessed, most-rewarded background mechanism.
- Backup is the app's core function → full-library access + background transfers are in-charter (2.5.4, 5.1.1(iii)) with an honest purpose string.

### 5.3 The Core-invariance guarantee (the seam mark)

This changes **only the `PhotoUploading` backend implementation** in `ProtonDriveBackend`. `BackupSyncRunner`, the queue, dedupe pipeline, retry/throttle policies, `BackupTempFileStore`, and Fable's `PhotoLibraryBackupController.backgroundCatchUp()` are untouched. Concretely:

- Add a capability flag `UploadBackendCapabilities.supportsResumeAcrossRelaunch = true` for the new backend — the runner already branches on capabilities, so no state-machine edit.
- The runner's `upload()` step becomes "enqueue background block transfers + persist plan" instead of "await in-process upload"; but its *contract* (persist-before-work, manifest-before-terminal, `stop()` reverts) is identical. A background completion simply drives the same `recordUploaded`→`markBackedUp` path.
- **Marked switch point:** `DriveSDKBridge.upload(_:onProgress:)` ([`DriveSDKBridge.swift`](Packages/ProtonPhotosKit/Sources/ProtonDriveBackend/DriveSDKBridge.swift)) is the single file that flips from `uploadPhoto(...)` to `prepareEncryptedUpload(...) + background transfers + commit`. Nothing above it in Core changes.

### 5.4 Simpler adjacent option — IETF resumable uploads (server-side)

iOS 17+ `URLSession` supports **resumable uploads** natively (`URLSessionUploadTask.cancel(byProducingResumeData:)`, `uploadTask(withResumeData:)`, `isResumable`) — but only when the **server implements the HTTP Working Group `draft-ietf-httpbis-resumable-upload`**; otherwise `resumeData` is `nil` and it falls back to full re-upload. This does not replace §5 (we still need block ciphertext as files, which requires the SDK seam), but it is a **complementary server-side ask**: if Proton block storage answered the resumable-upload preflight (`104 Upload Resumption Supported`), a killed background block transfer could resume mid-block instead of restarting — turning the per-resource floor into a per-*block* floor for large videos. Worth raising with Proton alongside §5 (see §13 Q2).

Until the SDK ships §5.1, the checkpointed-foreground/BGProcessing architecture (§7) is the shipping plan; this section is the labeled upgrade path.

---

## 6. PhotoKit Background Resource Upload — verdict with exact API evidence

### 6.1 Q1 — Is there any hook to transform/encrypt bytes before upload? **No.**

The complete API surface (headers in §2.1) is: an extension whose `process()`/`processJobs()` creates `PHAssetResourceUploadJob`s, each pairing a `PHAssetResource` with an `NSURLRequest` **`destination`**, plus lifecycle verbs (`acknowledge`/`retry`/`cancel`) and a `jobLimit`. **The system performs the transfer of the resource's bytes to the destination URL.** There is no callback that yields the bytes to the app, no body-stream override, no data-provider, no "encrypt then send" hook, and no API to create an encrypted *derivative* resource to upload instead. For Proton E2EE this is fatal: the only bytes it can send are the plaintext originals, to whatever URL we name. **Rejected: violates E2EE.**

### 6.2 Q2 — Does iOS 27 add a new hook? **Yes, but it's a scheduling hook, not a crypto hook.**

iOS 27.0 (beta SDK) deprecates `PHBackgroundResourceUploadExtension` (sync `process()` + `notifyTermination()`) in favor of `PHBackgroundResourceUploadJobExtension` (`processJobs() async` + `willTerminate() async`) — direct swiftinterface evidence in §2.1. This is an ergonomic/lifecycle refinement (async job processing, explicit termination). **The upload mechanism is unchanged** — jobs are still `(PHAssetResource → NSURLRequest destination)` with system-performed transfer. No encryption/transform member is added to any type. It does **not** enable E2EE.

### 6.3 Q3 — Can it be used safely for Proton E2EE direct upload? **No. Exact missing API:**

A byte-provider / transform hook on the job — e.g. a `resourceDataProvider` or `bodyStream(for: resource)` callback that let the app substitute app-encrypted bytes for the resource's plaintext — **does not exist**. Additionally, Proton upload is a multi-request choreography (draft → block list → commit), not a single resumable `PUT` to one destination, and the destination expects the IETF resumable-upload handshake the system speaks — a shape Proton storage does not implement for anonymous client PUTs. Three independent blockers; the first (no transform hook) is sufficient and unfixable from our side. **Classification: rejected (E2EE). Track only as a documented dead-end, never a roadmap dependency.**

### 6.4 Q4 — Can `creationRequestForDownloadJob(resource:)` accelerate iCloud-original prefetch? **Yes — the one usable piece.**

Per its header doc (§2.1), it asks the system to download an iCloud-stored original **to the device**, asynchronously, over time, *without uploading anywhere*. For a library on "Optimize iPhone Storage," step (1) RESOLVE otherwise blocks on an on-demand iCloud download (`isNetworkAccessAllowed`). Pre-staging originals via download-only jobs lets a later foreground/BGProcessing window find the bytes already local and spend its scarce time on encrypt+upload. **Caveats:** it requires the `com.apple.photos.background-upload` extension enabled + **full** library access; jobs count against `jobLimit`; downloaded resources may be **purged** by the system before we consume them (so we must re-check locality at RESOLVE and treat prefetch as best-effort); iOS-only (macOS classes unavailable); not testable in the Simulator. **Classification: prototype/spike** — genuine value, but earns its complexity only after the core pipeline ships and only for optimized-storage libraries.

---

## 7. iOS/iPadOS runtime strategy — the full legitimate-window ladder

Ordered from most-available to least. Rungs 1–3 are the ship-now maximal-today plan; 4–5 are spikes; 6 is rejected. Fable's foundation (`BGProcessingTask` + `backgroundCatchUp()`) is rung 3, partially built.

| # | Window | Mechanism | What runs | Status |
|---|---|---|---|---|
| 1 | **Foreground (primary engine)** | `syncNow()` on activation + `PHPhotoLibraryChangeObserver`/persistent-token incremental | full lattice 0–6, bounded workers so the grid stays smooth (§10 of audit) | **built** (Fable) |
| 2 | **Backgrounding grace** | `UIApplication.beginBackgroundTask(withName:expirationHandler:)` wrapped around the *current* in-flight item as the scene goes to background | finish/checkpoint the item already transferring (~tens of seconds) before suspension; expiration → `stopSync()` | **gap → adopt now** |
| 3 | **Deferred idle/charging** | `BGProcessingTask` (`processing` mode). Submit **two** requests: a bulk `requiresExternalPower=true, requiresNetworkConnectivity=true`, and a lighter top-up with `requiresExternalPower=false` for on-battery-Wi-Fi progress | `backgroundCatchUp()`; expiration → `stopSync()`; always reschedule | **rung built** (single request); add top-up variant + `beginBackgroundTask` handoff |
| 4 | **User-tapped "Back up now" (initial backup)** | `BGContinuedProcessingTask` (iOS 26): user-initiated, live progress UI, continues into background | the initial big drain, driven by `NSProgressReporting` bridged from `BackupSyncProgress`; `.queue` strategy; expiration-safe via `stop()` | **prototype/spike** (App-Review nuance §9) |
| 5 | **iCloud-original prefetch** | PhotoKit `creationRequestForDownloadJob(resource:)` (26.4) | pre-stage optimized-storage originals for a later window's RESOLVE | **prototype/spike** (Q4) |
| 6 | **PhotoKit background *upload* jobs** | `PHAssetResourceUploadJob` | — | **rejected: E2EE** (§6) |

> **Fable-alignment (do not duplicate).** The shared `PhotoLibraryBackupController` already owns *foreground* change-driven scheduling — a 3 s `PHPhotoLibraryChangeObserver` debounce ([`PhotoLibraryBackupController.swift:192-209`](Packages/ProtonPhotosKit/Sources/PhotoLibraryBackupAdapter/PhotoLibraryBackupController.swift:192)), cross-launch persistent-change-token detection ([`PhotoLibraryChangeMonitor.swift`](Packages/ProtonPhotosKit/Sources/PhotoLibraryBackupAdapter/PhotoLibraryChangeMonitor.swift)), and the thermal/LPM `throttleInputs`. macOS has a *separate but symmetric* `FolderBackupController` over the same `BackupSyncRunner`. The maximal-strategy scheduler layer must slot **above** the existing `syncNow()`/`backgroundCatchUp()`/`stopSync()` entry points and **consolidate** the per-platform BGTask + folder wiring through their shared runner seam — it must **not** re-add change detection, throttling, or drain/retry orchestration (all already in Core/controller). A purity gate already enforces the split: `testPhotoLibraryBackupAdapterStaysUIAndSDKFree` bans `BackgroundTasks`/UIKit/AppKit/SwiftUI/SDK in the adapter (`ProjectHygieneTests.swift`), so every scheduler API named below is necessarily app-side.

### 7.1 Concrete adjustments on top of Fable's rung 3

- **Add the grace window (rung 2).** On `scenePhase == .background`, before/around submitting the BGProcessing request, take a `beginBackgroundTask` and let the runner finish the current small item or checkpoint; end the task in the expiration handler (which also calls `stopSync()`). This converts "cut mid-item at suspension" into "one more item, cleanly." *Adapter-only; Core already checkpoints.*
- **Wire network throttle inputs.** Fable's `throttleInputs` closure currently feeds only `thermalState` + `isLowPowerMode`; `isNetworkConstrained` / `isNetworkExpensive` stay `false`. Add an `NWPathMonitor`-backed source (app layer) so cellular/Low-Data-Mode correctly drop to single-file or pause — the Core policy already consumes these ([`BackupThrottlePolicy.swift:54-61`](Packages/ProtonPhotosKit/Sources/UploadCore/Backup/BackupThrottlePolicy.swift:54)). *Adapter-only.*
- **Two BGProcessing request variants** for better window coverage (power-required bulk + no-power top-up), both draining the same checkpointed queue.
- **Respect the file-protection reality:** BGProcessing can run before first unlock; keep backup stores at `NSFileProtectionCompleteUntilFirstUserAuthentication` (they already live in the per-account dir) so the queue is readable in early windows.

### 7.2 Deliberately *not* used

Audio/location/VoIP keep-alive (2.5.4 abuse — forbidden); silent-push wakeups (unreliable, add a server dependency, and still can't beat the transport ceiling — see §11); PhotoKit background upload jobs (§6).

---

## 8. macOS runtime strategy

macOS has **no** BackgroundTasks (§2.2) and no PhotoKit upload jobs (§2.1) — but it also **does not iOS-suspend apps**, so the "background problem" is different: it is *App Nap* and *not-currently-launched*, not a hard suspension clock. None of the macOS scheduler layer exists yet (Fable's shared controller compiles for macOS and the app links it, but no macOS scheduling wraps it).

| Concern | Mechanism | Classification |
|---|---|---|
| Keep the runner from being throttled while syncing | `ProcessInfo.beginActivity([.userInitiated, .idleSystemSleepDisabled?], reason: "photo backup")` around active runner work; `endActivity` when idle | **adopt now** (defeats App Nap timer/I-O throttling) |
| Periodic deferrable rescans / change-token catch-up | `NSBackgroundActivityScheduler` (interval ~1 h, `.utility`, deferrable) → `syncNow()` | **adopt now** (Apple documents "backups" as the use case) |
| Sync without the app open | `SMAppService` login-item/agent (MAS-compatible, user-consented) | **not worth complexity now** — defer; the app auto-resumes on open and macOS keeps it alive while running |
| Throttling under thermal/LPM/constrained network | same shared `BackupThrottlePolicy` inputs, fed by macOS `ProcessInfo` + `NWPathMonitor` | **adopt now** (reuse Core policy) |
| Force-quit mid-upload | identical Core recovery pass at next launch (`requeueStaleActive`) | **built** (Core) |

macOS therefore reaches "continuous while the app runs" natively; the only missing rung (run-while-closed) is the deferred `SMAppService` agent. Because macOS keeps a running app alive, the SDK transport ceiling (§4) hurts *less* here than on iOS.

---

## 9. Risks and App Review concerns

1. **`BGContinuedProcessingTask` for backup (rung 4).** WWDC25 explicitly says to *avoid automatic* maintenance/backup/photo-sync workloads with it. A **user-tapped** "Back up now" for the initial backup is arguably in-charter (user-initiated, visible progress, user-cancelable), but it is reviewer-risk. **Mitigation:** gate it to the explicit button only, never automatic; default off until validated; be ready to fall back to rung 3. Owner decision at the spike.
2. **Full library access (5.1.1(iii)).** A backup app's core function justifies `.readWrite`, but the purpose string must say *backup* plainly (macOS string already does: `NSPhotoLibraryUsageDescription` = "…backs up the photos and videos… end-to-end encrypted." — [`project.yml:81`](project.yml:81)). Keep the iOS string identical; request access only from an explicit backup-onboarding action.
3. **Battery/heat (2.4.2).** The throttle table (pause on `.critical` thermal, single-file on `.serious`/LPM/cellular) + `requiresExternalPower` bulk variant are the defense; keep them.
4. **PhotoKit download-only jobs (rung 5)** require full access + the background-upload extension; adding that extension target invites reviewer questions ("why a background-upload extension in an E2EE app that never uses system upload?"). **Mitigation:** only ship the extension if the download-prefetch spike proves worthwhile, and document in review notes that it is used **solely** for `creationRequestForDownloadJob` prefetch, never for uploads.
5. **No misleading UI.** The transport ceiling (§4) means iOS cannot promise "uploads continue after you close the app." The **honest wording already ships**: iOS Settings key `settings.photos_backup_background_note` — *"Backup runs while the app is open and in system-granted windows (usually while charging). iOS may pause it in between - it resumes automatically."* (de present too). Keep this contract; only if §5's SDK feature lands may the promise strengthen (and the string must then change to match). macOS shows no continuation note — correct until Stage B exists.
6. **GPL contamination: low, unchanged — one transitive-dependency flag.** The vendored `sdk-swift` is MIT (all cited upload files clean, covered by root `LICENSE.md`); the Drive iOS *app* is studied for behavior only — do not copy its structure, `PHBackgroundResourceUpload*` adoption patterns, or any code/names/tests. **Flag (pre-existing, not introduced here):** `sdk-swift/Package.swift` transitively links `protoncore_ios` (for `GoLibsCryptoPatchedGo`/`ProtonCoreDataModel`) and the `CProtonDriveSDK.xcframework` is a compiled blob — both are outside the MIT tree with their own (historically GPLv3 for ProtonCore) licensing. This is the app's *existing* dependency posture, not something this strategy adds; confirm distribution licensing separately.
7. **Duplicate-upload safety across windows.** The manifest-before-terminal + recovery-pass contract (§3.2) already guarantees no double upload across interruption; the new background-transfer backend (§5) must preserve `recordUploaded`-before-terminal ordering — call it out in that backend's tests.

---

## 10. Minimal implementation stages

Each stage is adapter/app-only unless noted; Core semantics are frozen. This slots into the audit's Stage 4 and extends it.

**Stage A — iOS grace window + throttle wiring (adopt now).**
- Add `beginBackgroundTask` handoff around scene-background so the in-flight item finishes/checkpoints; end it in the expiration handler alongside `stopSync()`.
- Add `NWPathMonitor` source feeding `isNetworkConstrained`/`isNetworkExpensive` into Fable's `throttleInputs`.
- Add the no-power BGProcessing top-up request variant.
- *Touch:* `iOSApp/ProtonPhotosMobileApp.swift`, a small app-side `NetworkThrottleSource`. *Risk: low* (Core unchanged).

**Stage B — macOS scheduler adapter (adopt now).**
- `NSBackgroundActivityScheduler` (~1 h) → `syncNow()`; `ProcessInfo.beginActivity` around runner work; macOS `NWPathMonitor` + `thermalState` throttle wiring.
- *Touch:* `App/` (a `MacBackupScheduler`), no Core changes. *Risk: low.*

**Stage C — iCloud-original prefetch spike (prototype).**
- Time-boxed on-device spike of `creationRequestForDownloadJob` behind the enablement gate; measure hit rate + purge behavior on an optimized-storage library; decide whether to ship the extension target.
- *Deliverable:* short report + go/no-go. *Risk: none (spike branch).*

**Stage D — BGContinuedProcessingTask initial-backup spike (prototype).**
- Bridge `BackupSyncProgress` → `NSProgressReporting`; wire a user-tapped "Back up now" to a `BGContinuedProcessingTaskRequest` (`.queue`); validate expiration→`stopSync()` and App-Review posture with the owner.
- *Entitlements:* CPU-only continued-processing needs **no** entitlement and **no** `BGTaskSchedulerPermittedIdentifiers` entry (it uses a wildcard `<bundle>.<context>.*` identifier). Only `.gpu` would need `com.apple.developer.background-tasks.continued-processing.gpu` — which would require **creating an iOS `.entitlements` file** (none exists today; the iOS target declares no `CODE_SIGN_ENTITLEMENTS`). We do not need GPU (and GPU-in-background is effectively iPad-only at present), so keep it CPU-only.
- *Risk: reviewer-risk; default off.*

**Stage E — SDK background-uploader integration (blocked by Proton SDK).**
- Land only after the SDK ships §5's `prepareEncryptedUpload`/`commitEncryptedUpload`. Reimplement `DriveSDKBridge.upload` over a background `URLSession`; flip `supportsResumeAcrossRelaunch = true`.
- *Touch:* `ProtonDriveBackend` only; Core unchanged. *Risk: medium; behind capability flag + soak.*

---

## 11. Inventive options — full classification

| Option | Verdict | Rationale (evidence) |
|---|---|---|
| Job-lattice scheduler with per-job CPU/network/disk/memory budget | **adopt now** | Already ~built: `BackupSyncRunner` waves + `BackupThrottlePolicy` (thermal/LPM/net) + `BackupTempFileStore` disk budget. Missing only CPU/memory dims and network wiring — additive to the existing throttle seam. |
| `BGProcessingTask` for silent incremental maintenance | **adopt now** | Rung 3, already registered ([`ProtonPhotosMobileApp.swift:55`](iOSApp/ProtonPhotosMobileApp.swift:55)); add top-up variant + grace handoff. iOS-only (macOS uses Stage B). |
| `BGContinuedProcessingTask` for user-started initial backup | **prototype/spike** | Exists iOS 26 (§2.2); fits user-initiated one-shot; WWDC25 anti-*automatic*-backup wording ⇒ gate to explicit tap, default off (§9.1). |
| PhotoKit download-only jobs to pre-stage iCloud originals | **prototype/spike** | `creationRequestForDownloadJob` (26.4) genuinely downloads originals; purge risk + extension-in-review cost (§6.4, §9.4). |
| Direct PhotoKit background **upload** to a Proton endpoint | **rejected: violates E2EE** | System uploads plaintext originals; no transform hook (§6.1). |
| Direct PhotoKit background upload to an app-controlled **relay** endpoint | **rejected: violates E2EE/privacy** | Same plaintext-leaves-device problem; a relay that sees plaintext photo bytes breaks E2EE and violates "no raw unencrypted bytes to any relay." |
| Create encrypted **derivative** resources in Photos and upload those | **blocked by Apple API** | No API to author an arbitrary encrypted `PHAssetResource` and mark it the upload source; resource types are fixed/system-authored (`PHAssetResourceType`). |
| Local loopback/proxy that encrypts then forwards | **rejected / not worth complexity** | Background upload runs in `nsurlsessiond` out-of-process; a reliable in-app loopback server can't be guaranteed alive during background transfer, and plaintext-to-localhost then re-encrypt is double work and fragile. |
| Background `URLSession` with **pre-encrypted block temp files** | **blocked by Proton SDK** (then **adopt**) | This is the correct Apple pattern (file-based, out-of-process). Blocked only because the SDK won't emit block *files* + a resumable commit today (§4). Unblocked = §5 → adopt. |
| Silent push / server-side wakeups | **not worth complexity** | Even a perfect wakeup lands in an app-alive window that still can't do suspended transfers (transport ceiling §4); adds a server + entitlement + reliability tax for no reach beyond BGProcessing until §5 exists. Revisit *after* §5. |
| Live Activity as progress/continuation support | **prototype/spike** | `BGContinuedProcessingTask` already provides system progress UI for rung 4; a separate ActivityKit Live Activity is only worth it if we want richer/longer user-visible progress — evaluate with Stage D. |
| macOS `NSBackgroundActivityScheduler` / login item / App Nap handling | **adopt now** (scheduler + `beginActivity`); **defer** (login item) | Stage B. `SMAppService` agent for run-while-closed is deferred complexity (§8). |
| Thermal / Low Power / constrained-network / disk throttling | **adopt now** | Core `BackupThrottleInputs` already models all four; `BackupTempFileStore` already gates disk. Wire the network inputs (Stage A/B). |

---

## 12. Tests / gates needed

Core (SPM, platform-free — extend the existing suites named in the audit §13):
1. `BackupSyncRunner` expiration/resume: a fake clock + injected "expire mid-item" that calls `stop()`, asserting the row reverts to runnable and the next pass completes it with **no** duplicate `upload(...)` call (ledger-checked fake uploader).
2. Throttle-input matrix incl. the newly-wired `isNetworkConstrained`/`isNetworkExpensive` → worker counts.
3. `BackupTempFileStore` orphan-sweep + disk-budget park under a fake volume-space provider (already has `BackupTempFileStoreTests.swift`).
4. **New-backend contract test (for Stage E):** a fake background-transfer backend must preserve `recordUploaded`→`markBackedUp`→terminal ordering and idempotent commit; assert crash-between-blocks re-resolves to remote duplicate.

Adapter/app (device-manual where OS-bound, protocol-faked where possible):
5. iOS scenePhase→background submits BGProcessing **and** takes/ends a `beginBackgroundTask`; expiration handler calls `stopSync()` (fake `UIApplication`/task seam).
6. `NWPathMonitor`→throttle-input mapping unit (protocol-faked path).
7. macOS `NSBackgroundActivityScheduler` tick drives `syncNow()`; `beginActivity` bracket around runner work (fake scheduler).
8. Hygiene gate: the app scheduler layer imports `BackgroundTasks`/`AppKit` but Core stays clean (existing `CoreArchitectureGateTests` already bans `UIApplication`/`NSApplication` in Core — confirm the new adapters live app-side).

Runtime (owner/device): BGProcessing on-device soak (Console `[BackupBG]`); 4K-video mid-window kill/resume; optimized-storage iCloud prefetch hit-rate; BGContinued expiration behavior.

---

## 13. Exact questions to send Proton SDK maintainers

If §5's capability is not on the SDK roadmap, these unblock the maximal design (SDK is MIT `sdk-swift` 0.19.x):

1. **Transport decoupling.** Can `ProtonPhotosClient` expose a lower-level upload split into *(a)* `prepareEncryptedUpload(fileURL:…) -> EncryptedUploadPlan` that **writes each encrypted block to a local file** and returns the pre-signed storage `URLRequest` + `pm-storage-token` per block, and *(b)* `commitEncryptedUpload(commit:blockResults:)` that finalizes the draft after the app has transferred the blocks itself? (Today the block transfer is fused into `awaitUploadWithResilience` via the in-memory `StreamForUpload` seam — `UploadOperation.swift`, `SDKHttpClient.requestUploadToStorage`.)
2. **Background `URLSession` compatibility.** Are the storage block `PUT`s plain, idempotent, file-uploadable requests (no per-request in-process state) such that they can be executed by an app-owned `URLSessionUploadTask(fromFile:)` on a **`URLSessionConfiguration.background`** session, possibly out of order and across app relaunch?
3. **Resumable/persistable state.** Can `EncryptedUploadPlan` + `CommitDescriptor` be `Codable`/serializable so the app can persist them, transfer blocks over hours/relaunches, then finalize? Is the server **draft** durable across that window, and is `commit` idempotent (so a lost commit response reconciles via the existing duplicates endpoint)?
4. **Draft lifecycle.** How long does a server upload **draft** live, and does it auto-expire? (Drives our `blockedByDraft` re-check cadence and whether `UploadControllerDisposeRequest` / a `clientUID`-keyed cleanup is needed — audit §14.1.)
5. **`expectedSHA1` + metadata across the split.** Do `prepareEncryptedUpload`/`commitEncryptedUpload` carry `expectedSHA1`, `additionalMetadata` (capture EXIF/metadata schema — audit §14.3), `mainPhotoUid` (Live Photo pairing), and client-supplied thumbnails exactly as `uploadPhoto` does today?
6. **In-flight resume without full re-upload.** Short of full transport decoupling, can `UploadOperation` state be persisted so `resume()` works **across process relaunch** (today it is in-memory only — `UploadBackend.swift:33`)? Even per-item cross-relaunch resume materially improves large-video reliability.
7. **Availability.** Which of the above are in the ~end-2026 "full SDK" milestone vs. addable to 0.19.x sooner? Is there a REST contract we could implement against directly in the interim without reimplementing Proton block crypto?

---

## 14. Appendix — direct answers to the run's 12 questions

1. **Transform/encrypt hook in PhotoKit bg upload?** No (§6.1) — job = `(PHAssetResource → NSURLRequest)`, system uploads plaintext; no bytes callback.
2. **iOS 27 new hook?** Yes but scheduling-only: `PHBackgroundResourceUploadJobExtension.processJobs() async` replaces `process()`; no crypto hook (§6.2).
3. **Safe for Proton E2EE direct upload?** No; missing API = a per-job byte-provider/transform substituting app-encrypted bytes; also single-PUT-vs-choreography and IETF-resumable-server mismatch (§6.3).
4. **`creationRequestForDownloadJob` as iCloud prefetch?** Yes — legitimate background download-to-device accelerator; best-effort (purge risk), full-access + extension required; iOS-only (§6.4).
5. **Does SDK 0.19.x expose block files/requests for background `URLSession(fromFile:)`?** Not as files: the app sees per-block ciphertext as an **in-memory stream** synchronously coupled to the native core, foreground session, no cross-relaunch resume (§4).
6. **What must the SDK provide?** `prepareEncryptedUpload` → encrypted block **files** + pre-signed URLs + persistable commit; app owns transfers; `commitEncryptedUpload` finalizes; resumable/idempotent (§5, §13).
7. **Custom E2EE background uploader from MIT internals?** **Blocked-by-SDK as shipped — not feasible for a true out-of-process background uploader.** The app never possesses the encrypted block *files* or their keys: each block body is a **live pull-stream** (`StreamReadRequest`) that requires the .NET core alive **in-process** to produce it, so it cannot be handed to iOS's out-of-process background daemon, which needs a static file/`Data`. A *foreground* custom transport (swap the `HttpClientProtocol`/session config) is possible but pointless for the background goal. The only tractable path is the SDK "encrypt-to-file" seam (§5) — reimplementing Proton's block/commit protocol against REST is rejected (high risk, crypto duplication). This matches the run's product decision: request the SDK feature, do not hack the native core.
8. **Splitting into tiny checkpointable jobs?** Done — the 0–6 lattice (§3), each step persisted before its work; per-resource granularity today; per-block after §5.
9. **Which jobs are safe in which window?** Foreground: all 0–6. Grace (`beginBackgroundTask`): finish/checkpoint current item. `BGProcessingTask`: 0–6 while alive, power/network-gated. `BGContinuedProcessingTask`: user-initiated 0–6 with progress UI. PhotoKit bg extension: **download-only** prefetch of RESOLVE inputs (no upload). macOS background/idle: 0–6 via `NSBackgroundActivityScheduler` + `beginActivity` (no BGTask). (§3.1, §7, §8.)
10. **Best UI wording?** Honest, opportunistic framing — "Backup continues when you open the app or while charging"; never "uploading" during checking; never "backed up" for trashed/deleted; pause is instant + durable (audit §9). Strengthen the promise only when §5 lands.

*(Design outputs 1–12 requested by the run map to: §1 verdict, §2 evidence table, §3 job graph, §7+§8+§10 implementation plan, §5 magical-but-possible plan, §6 PhotoKit verdict, §7 iOS strategy, §8 macOS strategy, §9 risks, §10 stages, §12 tests, §13 SDK questions.)*

---

## 15. Hard-constraint compliance

- **No GPL contamination** — SDK is MIT; Drive iOS studied for behavior only; no code/name/structure/test copying. ✅
- **No private APIs** — every API cited is a public header/interface with availability annotations. ✅
- **No raw unencrypted photo bytes to any relay/server** — PhotoKit upload + relay options explicitly rejected for exactly this; §5 sends only ciphertext. ✅
- **No misleading UI** — §9.5 honest wording; no "continues while closed" promise until §5. ✅
- **No duplicate uploads** — manifest-before-terminal + recovery pass (§3.2); required of the new backend (§9.7). ✅
- **No local photo deletion** — nothing in this strategy deletes originals; deleted sources become `sourceMissing`, never remote deletions. ✅
- **No platform-specific duplicate business logic** — all decisions in Core (`BackupSyncRunner`/policies); apps are schedulers/adapters/UI only (§7 heading, §5.3). ✅
- **Core single implementation point** — the SDK-backend switch (§5.3) is the only change point; Core semantics frozen across today's plan and the magical plan. ✅

---

## 16. Corroboration & residual open items

**Claim verification.** The three load-bearing claims were confirmed by *independent* lines of evidence, not a single source: (1) *PhotoKit bg upload can't carry E2EE* — confirmed by the local headers (§2.1/§6), the transport analysis (the SDK must encrypt the plaintext original inside its native core before any bytes leave), **and** Apple's own docs page (which states the system uploads the resource to the destination URL, with no transform hook); (2) *background E2EE needs pre-encrypted block **files** the app owns* — confirmed by the SDK-internals read (block bytes are a live in-process pull-stream, never a file; `URLSession` background requires a file) **and** Apple's `URLSessionUploadTask` docs (*"uploads from data instances or a stream fail after the app exits"*); (3) *macOS has no BackgroundTasks* — confirmed by the macOS SDK headers **and** the `NSBackgroundActivityScheduler`/App-Nap docs. (Two dedicated adversarial-verifier agents errored on an output-schema retry cap; the claims stand on the header + docs + code evidence above, which is stronger than agent adjudication.)

**Residual open items surfaced for a future scheduler (not blockers):**
- **Single-writer invariant is load-bearing.** `BackupSyncRunner` guards `!isRunning` and `staleActiveGrace = 0`; **two concurrent runners over one queue would mutually requeue each other's in-flight rows.** A true multi-runner "lattice" therefore needs a lease/runner-id column or partitioned queues — today the correct lattice is *one runner draining many sources* (already supported via `CompositeBackupResourceResolver`), not many runners. Keep it that way unless leasing is added.
- **No priority/size ordering.** `nextRunnable` is `updated_at ASC`; a multi-GB video can monopolize a short window and never commit. Cheap mitigation (not implemented): size-order or defer huge items to power+Wi-Fi windows.
- **No CPU/memory throttle inputs.** `BackupThrottleInputs` models thermal/LPM/network but not memory-pressure or CPU; a lattice balancing against a live scrolling grid on old hardware would want a memory-pressure input (mirroring the grid's `UIKitMemoryPressureCoordinator`).
- **`notBefore` backoff is in-memory** (lost on crash — one immediate retry; persisted attempt count bounds it). Persist next-attempt times if a distributed lattice is ever built.
- **Vestigial seams** (`UploadBackupCheckpointing`, `UploadCompoundSource`, `UploadBackupSyncEngine.mark*`) have no production callers — a scheduler author must not wire them expecting the terminal path; the runner owns transitions. Delete or document.
- **Privacy manifest:** `BackupTempFileStore` uses `volumeAvailableCapacityForImportantUsage`, which is a fingerprinting-flagged API — ensure `NSPrivacyAccessedAPICategoryDiskSpace` is declared in each app's `PrivacyInfo.xcprivacy`.
- **Retry jitter absent by design** (deterministic backoff, cap 900 s) — fine for a single-user client; only a concern at fleet scale.

---

*Verification for this run: read-only. `git status --short --branch` shows the pre-existing backup-domain WIP (Fable's `PhotoLibraryBackupAdapter`, `BackupTempFileStore`, modified `BackupSyncRunner`); this report is the only file added. No production code modified; no builds run (none needed for a read-only spike). SDK header evidence is reproducible via the exact paths in §2 against Xcode 26.5 and Xcode-beta 27.0.*
