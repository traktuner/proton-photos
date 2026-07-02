# ProtonPhotos - Full Codebase Audit

**Date:** 2026-06-30 · **Scope:** entire repo (~20.2k LOC source across 123 files + 8.6k LOC tests) · **Method:** multi-agent fan-out - 14 per-unit deep-audit agents + 8 dead-code-verification agents + 4 cross-cutting (security / performance / modularity / docs) agents, each finding adversarially verified before action.

## Headline verdict
This reads like a codebase built by an experienced macOS engineer, not "vibe-coded slop." The architecture is genuinely modular (protocol-seam boundary is clean and SDK-drop-in ready), the E2EE story holds end-to-end, there is **no commented-out code**, and the test suite is dense (432 tests, many *contract guard* tests that pin behavior to source). The issues found are almost all **low/nit**: stale comments, vestigial diagnostics, and unused API surface - now largely cleaned up. A handful of real-but-bounded structural items (one main-thread decode, a few Metal per-frame allocations, two metadata/crypto trust notes) are documented below for follow-up.

---

## 1. Applied this pass (safe fixes - build + 432 tests green)

| Change | Count | Notes |
|---|---|---|
| **Comment-accuracy corrections** | 29 | Stale references to the deleted Metal "lab"/"synthetic" data source, "blur-up" → crossfade, wrong method names, contradicted magnitudes, etc. Each adversarially verified; guard-pinned phrases left untouched. |
| **Dead-code removals** | 52 symbols / 20 files | Every symbol re-verified zero-reference (production **and** tests) before deletion. Behavior-preserving by definition. |
| **Doc currency** | 5 docs | Superseded banners on 3 `LIQUID_GLASS_*` docs; historical/pointer banners on `OFFLINE_THUMBNAIL_SECURITY_REPORT.md` and `docs/grid-zoom-apple-model.md`. |
| **Orphaned localization key** | 1 | Pruned `error.album_not_found` (dead after removing `AlbumError.notFound`). |

Net: **39 files, +61 / −388 lines.** No test files altered. `swift test` → 432 passing; App `xcodebuild` → BUILD SUCCEEDED.

Representative removals: unused Metal diagnostics accessors (`cacheStats`, `drawState` forwarder, `totalEvictions`, `memoryEstimateBytes`), `MetalGridScrollHost.scrollToTop()`, `MetalGridSelectionController.replaceExternally()`, `SquareTileGridEngine.GridEngineInput`/`GridDebugInfo`, 7 unused `ProtonColor` tokens, 8 unused `PhotoDiagnostics` emitters, `VideoPlaybackController.playLocalFile()` (forbidden by the E2EE rule, no callers), `UploadManager.stats()`, and several write-only fields (`MainView.aspects`, `SDKAccountClient.emailToAddressID`, `ExtendedAttributes.Camera.orientation`).

---

## 2. Security / E2EE - **all 6 invariants hold** (2 low notes)

An external security reviewer would, on this code, trust the zero-knowledge claims. Verified end-to-end: no decrypted plaintext is persisted to the app's own cache/temp (originals, Live-Photo motion, thumbnails, ZIP export all go only to the user's chosen path or stay in RAM); thumbnail/preview/originals caches are AES-GCM sealed with a Keychain/HKDF key; SDK secret material is in-memory only (`secrets.sqlite` purged, no `secretCachePath`); account-data cache is AES-GCM + HKDF + cleared on sign-out; video streaming decrypts only in RAM; no secrets are logged (DEBUG-gated, grep-clean).

| Sev | Area | Note / recommendation |
|---|---|---|
| low | **Residual metadata at rest** - `App/Drive/DriveSDKBridge.swift:70` | `entities.sqlite` + `timeline-v3-<uid>.sqlite` hold *non-secret* node metadata (IDs, capture time, MIME, live flag) and are not deleted on sign-out / master-reset. No plaintext media, filenames, GPS, or keys. **Recommend** deleting them on sign-out + master-reset for completeness. |
| low | **Streaming skips signature verification** - `App/Drive/Streaming/DriveCrypto.swift:61` | `decryptBlock`/`decryptArmored` pass `verifyKey: nil` (matches Proton web/CLI, which can't verify without the full download). Content stays confidential; authenticity of streamed media isn't cryptographically verified. **Recommend** documenting this as an explicit trust assumption. |

---

## 3. Performance - 1 high, 4 medium (report-only; no functional bug)

| Sev | File:line | Issue | Suggested fix |
|---|---|---|---|
| **high** | `PhotoViewerFeature/PhotoViewerModel.swift:374` | Full-resolution original is decoded on the `@MainActor` (`NSImage`→bitmap) - can hitch the UI on large photos. | Decode on a background actor/`Task.detached`, hand the ready `NSImage`/`CGImage` back to main. |
| medium | `TimelineFeature/MetalGridRenderer.swift:169` | A fresh `MTLBuffer` is allocated every frame per render group (`device.makeBuffer`). | Triple-buffered ring of pre-sized buffers, or `setVertexBytes` for small counts. |
| medium | `TimelineFeature/MetalGridTextureCache.swift:119` | `makeTexture` does a `.high` CGContext resample + synchronous `texture.replace` on the render thread (bounded to 24/frame). | `.medium` interpolation for thumbnails, and/or resample off-main in `ThumbnailFeed`. |
| medium | `TimelineFeature/MetalGridDataSource.swift:73` | `image(for:)` calls `nsImage.cgImage(...)` on the render-data path. | Cache the `CGImage` alongside the `NSImage`. |
| medium | `TimelineFeature/MetalGridRenderer.swift:177` | Per-quad texture binding in the settled draw. | Batch into a texture array / atlas if it shows up in GPU capture. |

These affect frame-time/responsiveness under stress, not correctness. Recommend tackling the `@MainActor` decode first.

---

## 4. Modularity / SDK-swap / generic-ness - **clean, drop-in ready**

Confirmed: the `ProtonPhotosKit` package imports **no** SDK type, `URLSession`, or App concretion (the one `URLSession` use is the self-contained `ProtonForkAuthenticator`); 18 protocol seams; every backend capability behind a protocol implemented once in `App/Drive`. Swapping the SDK in/out touches `App/Drive` only - no feature rewrite. An external architect would rate the boundary highly.

Recommendations (report-only):
- **3 known frictions** to revisit when the SDK matures: REST tag-enrichment in `DriveSDKBridge.loadTimeline()` becomes dead once the SDK ships photo tags; `AuthenticationService` protocol (`PhotosDomain.swift:144`) is defined but unimplemented; album writes throw `.unsupported` pending album-write crypto.
- **Generic-ness dedup (nice-to-have):** `AlbumManaging` vs `AlbumBackend` are near-duplicate protocols; three parallel hand-rolled `Capabilities` structs share one shape; the server-tag↔`PhotoTag` Int mapping is repeated across `DriveSDKBridge`. Factor each into one place.

---

## 5. Dead code intentionally **not** removed

| Class | Items | Recommendation |
|---|---|---|
| **test-only** (8) | `MetalGridGeometry.contentPoint`/`overscanRect`, `GridZoomCommitDelta.anchorDeltaDistance`/`anchorColumnShift`, `ViewerChromeLayout` frame helpers, `ThumbnailFeed.setUserInteractionActive`/`interactionActive`, the whole `ThumbnailPrefetcher` actor, `SupportedMedia.kind(for:)` | Kept alive only by tests. Notably `MetalGridGeometry.contentPoint`/`overscanRect` are referenced **only** by `MetalGridLabTests.swift`, which tests the already-deleted Metal "lab." **Recommend** deleting that vestigial test file and the two helpers together; review whether `ThumbnailPrefetcher` is a planned-but-unwired feature. |
| **guarded-api** (1) | `MetalGridScrollHost.beginResizeSettle`/`advanceResizeSettle` morph branch | Production-wired + pinned by `GridResizePresentationTests`; dormant under fixed columns by design. **Keep.** |
| **uncertain** (3) | `MetalGridScrollStats` (dead diagnostics, coupled to `MetalGridHUD.scroll`), `GridTransitionFallbackReason.selectionRelocates`, `TimelineSearch` selfies-haystack fallback | **Recommend** removing `MetalGridScrollStats` together with the unused `MetalGridHUD.scroll` field in a small follow-up. |
| **live** (4 false positives) | `isSelfAdvancing`, `SDKCapabilities` fields, `MainView.selectionMode`, `ProtonLoadingView.caption` | Real callers exist - correctly retained. |

Also: the dead-diagnostics cluster in `MetalGridCoordinator.publishLightDiagnostics` only populates a few HUD fields and leaves `hud.cache`/`hud.scroll` unset - either wire the HUD or finish removing its unused fields (started above).

---

## 6. Documentation

The **live contracts are accurate** - all five named contracts (`docs/metalgrid-engine-contract.md`, `docs/apple-photos-parity-master-spec.md`, `RESIZE_PRESENTATION_LAYER_DESIGN.md`, `SECURITY_E2EE_AUDIT_2026-06-30.md`, `grid-zoom-transaction.md`) were verified against the code and hold. Comments were realigned to the code in §1.

**Repo hygiene recommendation (needs your OK - file moves):** the repo root holds ~14 dated spike reports that bury the live docs. Recommend moving the historical/superseded ones into `reports/archive/`:
`GRID_SIZE_BASED_RESIZE_DESIGN.md`, `PHASE_B_SPIKE_REPORT.md`, `PHASE_B_ENTRY_EXIT_GEOMETRY_REPORT.md`, `PHASE_B_PINCH_LIVE_DRIVER_REPORT.md`, `PHASE_B_PINCH_MULTI_LEVEL_REPORT.md`, `PHASE_B_OVERVIEW_LAYER_DISSOLVE_REPORT.md`, `LIQUID_GLASS_PHASE1_AUDIT.md`, `LIQUID_GLASS_TOOLBAR_SIDEBAR_FIX.md`, `LIQUID_GLASS_UIUX_AUDIT.md` (+ the dated audit/refresh reports). Caveat: `PHASE_B_OVERVIEW_LAYER_DISSOLVE_REPORT.md` is referenced by a comment in `OverviewLayerDissolve.swift` - update that link if moved. (Not done automatically since it's a structural move touching a code reference.)

---

## 7. Prioritized follow-ups (need approval - structural)

1. **(perf, high)** Move the full-res original decode off the main actor (`PhotoViewerModel.swift:374`).
2. **(security, low)** Purge `entities.sqlite` + `timeline-v3-<uid>.sqlite` on sign-out / master-reset.
3. **(cleanup)** Delete vestigial `MetalGridLabTests.swift` + the 2 geometry helpers it keeps alive; remove `MetalGridScrollStats` + `MetalGridHUD.scroll`.
4. **(perf, medium)** Pool the per-frame `MTLBuffer` allocations; lower thumbnail resample interpolation.
5. **(hygiene)** Archive historical spike reports to `reports/archive/`.
6. **(generic-ness)** Unify `AlbumManaging`/`AlbumBackend`, the three `Capabilities` structs, and the tag↔Int mapping.
7. **(security, doc)** Record the streaming "no signature verification" trust assumption explicitly.

*Items 1–7 are deliberately left for review per the agreed "fix safe directly, report the rest" scope.*
