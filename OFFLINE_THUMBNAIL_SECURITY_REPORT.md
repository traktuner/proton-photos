# Offline Thumbnail Pipeline & Secure Local Cache — Implementation Report

> **Status: HISTORICAL (largely still accurate).** The encrypted AES-GCM thumbnail/preview cache, in-memory SDK secret cache, and session hardening described here remain live. NOTE: the Live-Photo motion path mentioned later was subsequently re-implemented as encrypted streaming (no decrypted temp file) — see [SECURITY_E2EE_AUDIT_2026-06-30.md](SECURITY_E2EE_AUDIT_2026-06-30.md) for the current, verified E2EE invariants.

Date: 2026-06-25 · Branch: `apple-normal-focusrow-transition`
Scope: (1) fix offline/grid thumbnail behavior, (2) make local thumbnail/preview persistence
security‑auditable and Proton‑style, (3) inventory all local stores and report residual risk.
The accepted grid transition/pinch work was **not** modified.

---

## 1. Executive summary

| Problem (before) | Status |
|---|---|
| Turning **Offline Mode off stopped the background thumbnail crawl** (grid infrastructure coupled to the toggle) | ✅ Fixed — thumbnails always crawl |
| Background crawl ran **oldest→newest** (store is `ORDER BY t ASC`, passed straight to `startPrefetch`) | ✅ Fixed — named, tested `newest→oldest` helper |
| No stable‑viewport debounce; visible reprioritisation could fire every frame | ✅ Added — tested ~100 ms debouncer |
| Background crawl shares one rate‑limit gate with visible loads (can stall on‑screen thumbnails) | ✅ Mitigated (app‑level) — crawl yields to demand + backs off on 429 |
| **Thumbnails & previews persisted as plaintext images** on disk | ✅ Fixed — AES‑GCM, per‑account Keychain key |
| **SDK `secrets.sqlite` persisted decrypted Proton key material in plaintext** | ✅ Fixed — secret cache moved **in‑memory only**; legacy file purged |
| `dev-session.json` wrote the session **incl. the PGP key password in plaintext**, on by default in DEBUG | ✅ Fixed — hard‑gated behind an explicit env var, off by default |
| Session Keychain item used `AccessibleAfterFirstUnlock` | ✅ Hardened to `WhenUnlockedThisDeviceOnly` |
| Sign‑out left caches + keys on disk | ✅ Fixed — sign‑out purges blobs + cache keys |
| Review: grid feed used a **throwaway unconfigured cache** (ephemeral key → re‑crawl every launch) | ✅ Fixed — feed uses the shared account‑configured cache; guarded by tests |
| Review: `has()` skipped the network on **file existence**, so a corrupt blob could starve a thumbnail | ✅ Fixed — `hasUsableDiskData` validates decryptability in all network‑skip paths |
| Review: lost‑wakeup race could strand the last‑requested thumbnail | ✅ Fixed — `workersStopped` re‑checks the queue |

Build: `BUILD SUCCEEDED` (full app). Tests: **268 passed / 41 suites** (`swift test`). Commands and
exact results in §9.

---

## 2. Stop‑condition evaluation (from the spec)

The spec required stopping and reporting before broad implementation if any condition applied.

| # | Condition | Verdict | Evidence |
|---|---|---|---|
| 1 | SDK thumbnail loading would need raw Drive API replacement | **Not triggered** | SDK provides `photosClient.downloadThumbnails(type: .thumbnail/.preview)` natively — `App/Drive/DriveSDKBridge.swift:126`. No raw‑API path exists or is needed. |
| 2 | Cache encryption would require storing keys outside Keychain | **Not triggered** | The cache MainKey is a random 256‑bit key stored in the Keychain (`KeychainCacheKeyStore`). |
| 3 | Proton key material would need plaintext persistence | **Was already occurring** in the SDK secret cache; **resolved** by moving it in‑memory. Our own cache never touches Proton PGP material. |
| 4 | Visible thumbnails can be starved by background crawl | **Partially applied at the network layer.** Feed‑level priority already serves visible first (`takeBatch` drains the priority queue before the crawl — `ThumbnailFeed.swift:420`). The residual is the shared `RateLimitGate`/`URLSession`. Per the chosen decision, mitigated **app‑level** (crawl yields + 429 backoff); full network priority lanes need SDK changes and are reported as residual risk. |
| 5 | SDK local secret storage appears plaintext and cannot be wrapped safely | **Applied.** `secrets.sqlite` is owned by the SDK's closed native core; the Swift layer only passes a path, and the `ProtonPhotosClient` create‑path does not forward `secretCacheEncryptionKey` to the core. Rather than patch the vendored SDK (unverifiable in tests), we **keep secrets in‑memory** — no decrypted key material persists at rest. |

Per‑condition decisions were confirmed with the user before implementation:
**SDK secret cache → in‑memory only**, **starvation → app‑level mitigation**.

---

## 3. Thumbnail pipeline changes

### 3.1 Mandatory grid cache, decoupled from Offline Mode
The thumbnail grid cache is now **mandatory infrastructure** and always crawls when signed in. The
"Offline Photo Library" toggle no longer gates it; it is reserved for future preview/original offline
caching. The split is encoded as a named, tested policy.

- `Packages/.../MediaCache/OfflineLibraryPolicy.swift` — `shouldCrawlThumbnails(offlineEnabled:) == true` always; `shouldCacheOfflineDerivatives(offlineEnabled:)` returns the toggle.
- `App/Offline/OfflineLibraryManager.swift` — `attach` now sets `setPrefetchEnabled(true)` unconditionally; `setOfflineEnabled` only persists the flag (no longer starts/stops prefetch). The dead `restartPrefetch` hook was removed.

### 3.2 Newest→oldest crawl order (proved + tested)
The SQLite store loads `ORDER BY t ASC` (oldest first — `DriveSDKBridge.swift:391`) and the grid
bottom‑pins to the newest photo, so index 0 of the timeline is the **oldest**. The crawl previously
walked that array front‑to‑back (oldest→newest). A named helper now makes newest‑first explicit:

- `Packages/.../MediaCache/ThumbnailCrawlOrder.swift` — `newestToOldest(_:)` sorts by `captureTime` descending with a **stable** tie‑break (deterministic, resumable). Applied at all crawl starts in `TimelineViewModel.swift` (lines 132/183/196/215).

### 3.3 Stable‑viewport debounce (~100 ms)
- `Packages/.../MediaCache/ViewportRequestDebouncer.swift` — pure, clock‑injectable policy that emits the visible set **once per stable viewport**, not every frame.
- Wired in `MetalGridDataSource.swift` (`RealMetalGridDataSource.warm`): on‑screen disk→RAM decode stays **immediate** (no scroll‑feel regression); only the network reprioritisation (`.visibleNow`) is coalesced and fired after the viewport settles. This is the data‑source boundary — the pinch/transition engine was not touched.

### 3.4 Visible priority preemption (already correct) + crawl‑yield mitigation
`takeBatch` always drains the priority queue before the sequential crawl, so visible fetches are never
gated by the crawl. New app‑level mitigation prevents the background crawl from stealing the shared
rate‑limit budget (`ThumbnailFeed.swift`):
- A non‑idle `requestPriority` records live demand; the **sequential** crawl pauses for `visibleQuietWindow` (0.25 s) after demand (priority queue unaffected).
- A rate‑limited/empty batch (likely 429) sets a `crawlBackoffUntil` so the crawl backs off instead of compounding the 429 and stalling visible loads.
- Both use an injected clock for deterministic tests.

### 3.5 Disk‑hit warms RAM without network; missing → visible‑priority fetch
Unchanged contract, re‑verified with the encrypted cache: `warmDecoded` decodes disk→RAM with **no
loader call** for cached items and enqueues a network fetch only for genuinely missing ones
(`ThumbnailFeed.swift:176`). Bounded SDK usage is preserved (single worker pool, 20 s per‑batch timeout,
de‑duplicated/idempotent requests, 600‑item priority bound).

---

## 4. Encrypted thumbnail/preview cache

Implemented with Apple primitives only — no hand‑rolled crypto.

- **Cipher** — `SecureBlobCipher.swift`: CryptoKit `AES.GCM`. Each blob is sealed with a **fresh random 96‑bit nonce** (CryptoKit default). On‑disk layout = `nonce(12) ‖ ciphertext ‖ tag(16)` (`SealedBox.combined`). No plaintext or key‑derived value is ever written.
- **AAD** — every blob is authenticated against `namespace ‖ version ‖ accountUID ‖ volumeID ‖ nodeID ‖ derivativeType` (U+001F‑delimited). A blob cannot be moved between accounts, namespaces, derivative types, or photos — a mismatch fails the GCM tag and reads as a **miss**, never as wrong bytes.
- **Key** — `KeychainCacheKeyStore.swift`: a per‑account random 256‑bit key, service `me.protonphotos.mac.cachekey`, account = Proton UID. `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; `kSecAttrSynchronizable` deliberately **unset** (never iCloud‑synced, never migrated to another device or unencrypted backup). The key is never logged.
- **Cache** — `ThumbnailCache.swift` now seals/opens transparently; callers (`ThumbnailFeed`, `PhotoViewerModel` preview cache) keep the same `diskData`/`storeToDisk` signatures. Files are stored under `<namespace>.enc/` with **content‑hiding, account‑scoped filenames** (`SHA‑256(namespace ‖ account ‖ volume ‖ node).blob`) — node IDs never appear on the filesystem, two accounts never collide.
- **One configured instance (fixed)** — the production grid feed is now built with the **shared, account‑configured** `OfflineLibraryManager.shared.cache` (`MainView.swift`), and the viewer with `OfflineLibraryManager.shared.previewCache`. `configure`/`deleteOfflineCache`/`refreshStatus`/`purgeOnSignOut` all operate on those same instances. (A prior throwaway `ThumbnailCache()` in the feed would have stayed on an ephemeral key and re‑crawled every launch — caught in review, now fixed + guarded by `ProductionRouteGuardTests` + cache‑survives‑relaunch tests.)
- **Decryptable ≠ exists (fixed)** — network‑skip decisions use `hasUsableDiskData(_:)`, which validates the blob actually decrypts (and deletes a corrupt/tampered/wrong‑key blob so it re‑fetches), with a memoized validated‑presence set so it stays O(1). Plain `has(_:)` (existence) is now diagnostics‑only. A corrupt blob can no longer permanently starve a thumbnail.
- **Lifecycle**:
  - `configure(accountUID:)` installs the durable per‑account key at sign‑in (`AppModel.prepareBackend`), before the grid renders. The account UID is available at launch from the restored session.
  - Before configure, a **process‑ephemeral** key is used — nothing readable persists across launches (secure by default).
  - **Missing key** (Keychain locked/denied) → cache **locked**: reads miss, writes drop, no crash.
  - **Auth failure / corruption** on read (or on a `hasUsableDiskData` probe) → miss **and** the corrupt blob is deleted so it re‑fetches.
  - **Legacy plaintext purge**: `configure` deletes the old plaintext `<namespace>/` directory (one‑time). Re‑crawl refills encrypted. (Purge chosen over migrate: it guarantees no plaintext survives, and thumbnails are cheap to refetch.)
  - **Sign‑out** (`AppModel.signOut → OfflineLibraryManager.purgeOnSignOut`): erases encrypted thumbnail/preview blobs **and** deletes their account Keychain keys, plus the streamed video blocks.

---

## 5. Session secret hardening

`Packages/.../ProtonAuth/Session.swift`:
- The plaintext `dev-session.json` path (which persisted the full session **including the PGP key password**) was on for every default DEBUG build. It is now hard‑gated behind `SessionKeychainStore.devPlaintextSessionEnabled`, which is **`#if DEBUG` AND** the environment variable `PROTONPHOTOS_DEV_PLAINTEXT_SESSION=1`. Default (normal Debug **and** Release) → Keychain. Release never honors the env var.
- The escape hatch is documented in‑code as **insecure**. Trade‑off: with it off, a local rebuild may trigger a one‑time "ProtonPhotos was modified" Keychain prompt (the Keychain ACL is bound to the changing code signature) — this is the intended secure default; set the env var for a prompt‑free dev session.
- Keychain accessibility strengthened from `kSecAttrAccessibleAfterFirstUnlock` to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; `kSecAttrSynchronizable` remains unset.
- `clear()` (sign‑out) now removes **both** the Keychain item and any dev plaintext file.

---

## 6. SDK secret cache → in‑memory

`App/Drive/DriveSDKBridge.swift`: the `ProtonDriveClientConfiguration` no longer passes `secretCachePath`,
so the SDK keeps its secret cache (decrypted share/node/content keys) **in memory only** — nothing
decryptable is persisted. The non‑secret `entityCachePath` (node metadata) stays on disk for fast
startup. Any pre‑existing plaintext `secrets.sqlite` (+ `-wal`/`-shm`) from older builds is deleted on
launch. Cost: the secret cache is re‑derived on each cold start (one‑time per launch).

---

## 7. Full local‑store inventory

Root: `~/Library/Caches/ProtonPhotos/` unless noted.

| Store | Location | Owner | Contents | At‑rest posture |
|---|---|---|---|---|
| Thumbnail cache | `thumbnails.enc/` | app | grid thumbnails | ✅ **AES‑GCM**, per‑account Keychain key |
| Preview cache | `previews.enc/` | app | viewer previews | ✅ **AES‑GCM**, per‑account Keychain key |
| Video byte‑range cache | `video-blocks/` | app | **Proton‑encrypted** Drive blocks (decrypted only in RAM) | ✅ ciphertext at rest already |
| Cache MainKeys | login Keychain (`me.protonphotos.mac.cachekey`, per UID) | app | 32‑byte AES keys | ✅ `WhenUnlockedThisDeviceOnly`, no sync |
| Session item | login Keychain (`me.protonphotos.mac.session`) | app | tokens + key password | ✅ `WhenUnlockedThisDeviceOnly`, no sync (hardened) |
| `secrets.sqlite` | `sdk/` | SDK core | decrypted share/node/content keys | ✅ **now in‑memory** (no longer on disk; legacy purged) |
| `entities.sqlite` | `sdk/` | SDK core | node tree metadata / names / hashes | ⚠️ plaintext SQLite (no SQLCipher) — **residual** |
| `timeline-v3-<uid>.sqlite` | `sdk/` | app | node id, volume id, capture time, mime, isLivePhoto, related‑video id | ⚠️ plaintext metadata (no secrets/thumbnails) — **residual** |
| Aspect registry | `aspects*.json` / `thumbnails.json` | app | thumbnail aspect ratios | ⚠️ plaintext, non‑sensitive — residual (trivial) |
| Temp originals | `$TMPDIR/ProtonPhotos/originals/` | app | full original of the photo opened in the viewer | ⚠️ plaintext, ephemeral — **residual** |
| `dev-session.json` | `~/Library/Application Support/ProtonPhotos/` | app | full session incl. key password | ✅ now off by default (DEBUG + explicit env var only) |

App is **unsandboxed** (`App/ProtonPhotos.entitlements`: `network.client` + 3 hardened‑runtime
relaxations; no app‑sandbox, no file data‑protection). Plaintext files rely on POSIX home‑dir
permissions.

---

## 8. Residual risks (explicit — full local security is NOT claimed)

1. **`entities.sqlite` is plaintext** (SDK‑owned, no SQLCipher in the stack). It holds node metadata and
   likely decrypted node **names** (filenames) and hashes. Cannot be wrapped from the Swift layer; the
   only app‑side mitigation would be to also set `entityCachePath = nil` (in‑memory, at a cold‑start
   cost) — not done in this pass. **Stop‑condition #5 territory; reported, not silently accepted.**
2. **`timeline-v3-<uid>.sqlite` is plaintext** but holds only non‑secret metadata (capture time, mime,
   node/volume IDs). Lower sensitivity; could be encrypted with the same cache‑key approach if desired.
3. **Temp originals are plaintext** in `$TMPDIR/ProtonPhotos/originals/` while the viewer shows a photo
   (and until the temp dir is cleared). Per the non‑goals, offline originals are out of scope; flagged for
   a future encrypted originals store.
4. **Video byte‑range cache (`video-blocks/`) is NOT under our local cache key.** It persists the
   **Proton‑encrypted** Drive blocks (ciphertext as delivered by the SDK) and decrypts them only in memory
   on playback — so no clear video lands on disk — but the blobs are protected by Proton's block crypto,
   not by our `ThisDeviceOnly` Keychain key, and they are not AES‑GCM‑wrapped like the thumbnail/preview
   cache. It is purged on sign‑out / delete‑cache. Stated explicitly as a non‑uniform local‑encryption
   surface, not an at‑rest plaintext exposure.
5. **The aspect registry (`*.json`)** persists plaintext thumbnail aspect ratios — non‑sensitive, but
   non‑encrypted local data, listed for completeness.
6. **Network‑layer starvation** is only mitigated app‑side. A 429 tripped by background traffic still
   shares one back‑off window with visible loads. True priority lanes (separate `URLSession`/rate‑limit)
   require SDK request tagging the SDK does not expose.
7. **SDK secret cache in‑memory** removes the at‑rest exposure but does **not** verify the native core
   never spills secrets elsewhere; this is unobservable from the Swift layer.
8. **Unsandboxed app, no `NSFileProtection`** — encrypted caches are still only as private as the user's
   home directory + the Keychain. The cache keys (the actual protection) are `ThisDeviceOnly` in the
   Keychain, so the encrypted blobs are unreadable without an unlocked device + Keychain access.

Because of (1)–(5), **full local security acceptance is explicitly NOT claimed** — only the
thumbnail/preview caches use our AES‑GCM + Keychain protection and the SDK secret cache is in‑memory; the
SDK `entities.sqlite`, the app timeline metadata, temp originals, the video byte‑range cache, and the
aspect registry remain non‑(locally‑)encrypted on disk.

---

## 9. Tests, build, and results

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test    # in Packages/ProtonPhotosKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build    # in Packages/ProtonPhotosKit
# full app:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project ProtonPhotos.xcodeproj -scheme ProtonPhotos \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DD.noindex \
  -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=YES
```

Results (latest run, after the review‑blocker fixes):
- `swift test` → **Test run with 268 tests in 41 suites passed** (0 failures). (Suite/test counts shifted from the first pass: the 3 focusRow‑crossfade proof suites were deleted with that machinery; validated‑presence, debounce‑rearm, corrupt‑blob, and production‑route‑guard tests were added.)
- `swift build` → success. Full app `xcodebuild` → **BUILD SUCCEEDED**.

New/updated tests (all green):

| Test | Proves |
|---|---|
| `ThumbnailCrawlYieldTests.offlineDisabledStillAllowsThumbnailCrawl` | Offline‑off still crawls (policy split) |
| `ThumbnailCrawlYieldTests.crawlRunsIndependentlyOfAnyOfflineFlag` | Crawl runs with no offline flag involved |
| `ThumbnailCrawlYieldTests.corruptDiskBlobDoesNotStarveVisibleFetch` | A corrupt on‑disk blob still triggers a visible network fetch (not skipped) |
| `SecureThumbnailCacheTests.hasUsableDiskDataRejectsAndDeletesCorruptBlob` | `hasUsableDiskData` validates decryptability + deletes corrupt blobs |
| `SecureThumbnailCacheTests.configuredCacheSurvivesAcrossInstances` | A configured cache survives relaunch (new instance, same key) |
| `ViewportRequestDebouncerTests.rearmDecisionEmitsFinalSetExactlyOnce` | Debounce re‑arms off the debouncer's pending state; final viewport emitted once |
| `ProductionRouteGuardTests.*` | No anim‑tuning/TuningView/AnimationTuning.shared/focusRowTransition route remains; grid feed uses the shared cache |
| `ThumbnailCrawlOrderTests.*` | Crawl order is newest→oldest (incl. shuffled input + stable ties) |
| `ThumbnailCrawlYieldTests.visibleDemandPausesSequentialCrawl` | Visible priority preempts the crawl; crawl yields to demand |
| `ThumbnailCrawlYieldTests.rateLimitedBatchBacksOffSequentialCrawl` | 429/empty batch backs the crawl off |
| `ViewportRequestDebouncerTests.*` | Stable‑viewport debounce enqueues once, not every frame |
| `ThumbnailCrawlYieldTests.diskHitWarmsRamWithoutNetwork` | Disk hit warms RAM with zero network |
| `SecureThumbnailCacheTests.encryptedBlobHasNoPlaintext` | Encrypted file does not contain plaintext input (or PNG header) |
| `SecureThumbnailCacheTests.wrongContextFailsDecrypt` | Wrong AAD (account/namespace/derivative/uid) or key fails decrypt |
| `SecureThumbnailCacheTests.freshNoncePerBlob` | Fresh random nonce per blob |
| `SecureThumbnailCacheTests.missingKeyIsCacheMissNotCrash` | Missing Keychain key → cache miss, not crash |
| `SecureThumbnailCacheTests.corruptBlobIsMissAndDeleted` | Auth failure → miss + corrupt blob deleted |
| `SecureThumbnailCacheTests.signOutRemovesBlobsAndKey` | Sign‑out removes blobs + cache key |
| `SecureThumbnailCacheTests.differentAccountCannotReadCacheBlob` | Account‑scoped: another account can't read the blobs |
| `SecureThumbnailCacheTests.legacyPlaintextCacheIsPurgedOnConfigure` | Legacy plaintext cache is purged |
| `SessionHardeningTests.devPlaintextSessionDisabledByDefault` | DEBUG plaintext session path off by default |
| `SessionHardeningTests.roundTripsThroughKeychainWhenPlaintextDisabled` | Default path uses the Keychain |

---

## 10. Files changed

New (MediaCache): `SecureBlobCipher.swift`, `CacheKeyStore.swift`, `ThumbnailCrawlOrder.swift`,
`ViewportRequestDebouncer.swift`, `OfflineLibraryPolicy.swift`.
Modified: `MediaCache/ThumbnailCache.swift` (encryption), `MediaCache/ThumbnailFeed.swift` (crawl‑yield),
`TimelineFeature/TimelineViewModel.swift` + `TimelineFeature/MetalGridDataSource.swift` (order + debounce),
`ProtonAuth/Session.swift` (session hardening), `App/Offline/OfflineLibraryManager.swift` (decoupling +
configure/purge), `App/AppModel.swift` (configure at sign‑in, purge at sign‑out),
`App/Drive/DriveSDKBridge.swift` (in‑memory secret cache + legacy purge), `App/Views/MainView.swift`
(dead hook removed), `Packages/ProtonPhotosKit/Package.swift` (ProtonAuthTests target).
New tests: `SecureThumbnailCacheTests.swift`, `ThumbnailCrawlOrderTests.swift`,
`ViewportRequestDebouncerTests.swift`, `ThumbnailCrawlYieldTests.swift`,
`ProtonAuthTests/SessionHardeningTests.swift`.
