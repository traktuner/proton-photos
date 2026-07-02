# Proton Photos Deep Performance + Memory Audit — Core, Metal Grid, Renderer, Cache — 2026-07-02

Scope: the shared Core + Metal grid pipeline (GridCore, MetalRenderingCore, MetalGridTextureCore,
Timeline*, Media*, PhotosCore) audited for a universal, iPhone/iPad-performant Apple-platform Core.
Branch `codex/thumbnail-prefetch-failure-fix`, clean tree at audit start and end. Full package suite
green at baseline: **508 tests / 73 suites passed**. Read-only audit — no source files changed; this
report is the only file written.

Method: parallel subsystem deep-reads (every file in the listed targets), adversarial verification of
the top findings against the *current* branch (two independent verifiers for P0/P1 candidates, both of
which compiled `-O` replica benchmarks of the disputed code), Apple/SQLite documentation research with
per-claim links, and a completeness-critic pass. The prior audit
(`PERF_DB_METAL_AUDIT_2026-07-01.md`) was used for orientation only; every claim relied on here was
re-verified in current code — several of its findings are now fixed (DB v1 reset, dimensions-in-DB,
pre-sized ImageIO decode) and are marked as such.

Legend per finding: **Severity** P0–P3 · **Confidence** confirmed/likely/hypothesis ·
**Verification** `[verified×2]` two adversarial lenses, `[verified×1]` one lens, `[self-verified]`
mechanics re-checked directly during synthesis, `[cited]` gap-phase agent with file:line evidence but
no adversarial pass.

---

## 1. Executive summary

The architecture is fundamentally right, and this audit confirms it in more detail than before: the
grid engine is closed-form and viewport-windowed (per-frame cost is **independent of library size** —
20k/100k/500k cost identically per frame), the settled render path is one command buffer / one
encoder / one pass with a triple-buffered vertex ring, the MTKView is draw-on-demand with a
self-pausing display link, decode is pre-sized ImageIO off-main, no SQLite ever runs on the main
thread, and GridCore/MetalRenderingCore/MetalGridTextureCore are import-clean for iOS. None of that
should be touched.

The audit found two P0-class problems and a cluster of P1s, almost all in the *policy* layer rather
than the architecture:

1. **P0 — LRU eviction full-sorts the cache on every upload frame.**
   `GridTextureResidencyPolicy.evictToBudget()` re-sorts all ~4,096 evictable two-String `PhotoUID`
   keys (two dictionary lookups per comparison) on every frame that completes ≥1 upload once the
   cache is full. Two independent `-O` replica benchmarks measured **~11–26 ms per occurrence on an
   M-series Mac** — more than an entire 60 Hz frame budget, recurring during sustained scroll after
   ~4,096 distinct thumbnails have been seen in a session (trivially reached on the 20.5k library).
   The fix is O(R) partial selection, ~an afternoon of work, semantics-preserving.

2. **P0 — the pinned set can exceed the texture budget, making residency unbounded.**
   Pinned = visible + 2×overscan; eviction only touches `resident ∖ pinned`; `selectUploads` never
   checks capacity. At L5 (30 fixed columns) a macOS portrait window pins ~5,400 tiles ≈ **2.2 GB**
   (silently bypassing the 4,096 cap); an iPhone at L5 would pin ~4,900 × 224px textures ≈ **0.99 GB
   against an intended 154 MB budget** — certain jetsam. Reproducible on macOS today; the executable
   guard test for it is specified in §16.

Behind those: uploads run count-budgeted (up to 96/frame) CGContext-normalization + `replaceRegion`
on the main thread with no time budget; the texture budget is count-based while `residentBytes` is
already tracked but unused; textures upload at a fixed 320px for 39–94px tiles at dense detents (no
mips, 11–33× bandwidth waste); the draw encoder emits ~2,000 per-quad draws at L5 because it encodes
the full 3.4×-viewport overscan band; every changed DB sync rewrites all rows (proven by the 20k
guard: +25/−100 → 19,925 upserts); every data arrival runs O(n) library passes on the main actor; the
viewer holds up to 40 *uncosted* full-resolution decodes (up to ~7.8 GB theoretical); and there is
**zero** memory-pressure, thermal, or Low Power Mode response anywhere in the codebase (grep:
0 hits), and **zero** `os_signpost` instrumentation (grep: 0 hits).

Nothing here requires an architectural rewrite. The entire top of the backlog is: fix the eviction
data structure, add a byte + pinned-overflow-aware budget, time-box and off-main the upload copy,
make the DB save O(changes), move library passes off the main actor, and add a memory-pressure
governor — all inside existing seams (GridCore policy structs + platform adapters) that were built
for exactly this.

---

## 2. Current architecture map

Production path (verified end-to-end):
`TimelineView` ([TimelineView.swift:93](Packages/ProtonPhotosKit/Sources/TimelineFeature/TimelineView.swift)) →
`MetalProductionGridView` → `MetalGridScrollHost` (NSScrollView camera, gestures, display link;
[MetalGridScrollHost.swift:210-215](Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridScrollHost.swift)) →
`MetalGridCoordinator.draw(in:)` ([MetalGridCoordinator.swift:1170](Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridCoordinator.swift)) →
`MetalGridRenderer` ([MetalGridRenderer.swift](Packages/ProtonPhotosKit/Sources/MetalRenderingCore/MetalGridRenderer.swift)).

- **Frame pacing**: MTKView `isPaused=true`, `enableSetNeedsDisplay=true`, `framebufferOnly=true`,
  bgra8Unorm. Redraws are driven by scroll notifications plus a display link that self-pauses when no
  work is pending (`MetalGridScrollHost.swift:805-822`). GPU is fully idle at rest. dt comes from
  wall clock — no 60 Hz assumption (ProMotion-safe).
- **draw(in:) branches**: resize/sidebar presentation → resize settle → overview dissolve → lattice
  transition → commit bridge → settled engine frame.
- **Settled frame**: `engine.framePlan()` (O(visibleRows×columns), row-windowed with ±overscan;
  `SquareTileGridEngine.swift:432-434, 584-594`) → `streamTextures` (dedupe window + budgeted
  uploads) → `buildRealGroups` (per visible resident tile: residency check + `TileContentFitter.fit`
  pure math + quad append) → `evictToBudget` → single-pass render. Per-tile draws:
  `.perQuadTexture` = one `setFragmentTexture` + one 6-vertex `drawPrimitives` per resident tile
  (`MetalGridRenderer.swift:192-199`); decorations batch per type.
- **Vertex path**: per-frame CPU `[Vertex]` build (64 B × 6 per quad, non-indexed) packed into a
  3-deep semaphore-bounded ring buffer (`MetalGridRenderer.swift:34-37,109-116,209-215`) — zero
  steady-state MTLBuffer allocation (matches Apple's canonical triple-buffering sample).
- **Transitions**: pinch/click plans built once per gesture/segment (detent crossing), per-frame is
  read-only `renderIntent(at: q)` — single pass, alpha-weighted, ≤~2× tile draws. Overview dissolve
  (L3↔L4↔L5) is the exception: 3 passes/3 encoders per frame, both full grids re-rasterized into two
  persistent private offscreen targets + fullscreen composite (`MetalGridRenderer.swift:249-281`).
- **Texture pipeline**: SDK bytes → AES-GCM disk blob → off-main pre-sized ImageIO decode
  (`CGImageSourceCreateThumbnailAtIndex`, MaxPixelSize=320, ShouldCacheImmediately;
  `ThumbnailImageDecoder.swift:10-21`) → decoded-CGImage NSCache (real byte costs) → main-thread
  CGContext RGBA8 normalization + `replaceRegion` inside `draw()` → count-LRU residency with
  visible+overscan pinning.
- **Data**: `TimelineMetadataStore` (raw SQLite, WAL+NORMAL, one canonical
  `ORDER BY t, vol, node` scan on `idx_photos_timeline`, plan pinned by a guard test) owned by the
  `DriveSDKBridge` actor; full-array materialization on load; digest-based no-op save skip; grid gets
  data via immutable snapshot arrays (`RealMetalGridDataSource`), never the DB.
- **Core/adapter split**: 14 Core modules with zero AppKit/UIKit (grep-verified). Policy numbers
  (texture budgets, cache budgets, DB pragmas) live in adapters
  (`AppKitMetalGridTexturePolicy` 96 uploads/4096 textures/1.2 overscan; UIKit tiers 24/768@224px,
  32/1024@256px, 48/1536@288px; DB desktop mmap only in `DriveSDKBridge`). UIKit adapters:
  MediaCache + MetalGridTexture adapters are complete; Timeline/PhotoViewer UIKit adapters are stubs;
  the entire backend (DriveSDKBridge, streaming, OfflineLibraryManager) lives in the macOS `App/`
  target — the single largest iOS port gap.

---

## 3. Confirmed hot paths

Hot-path purity matrix. "clean" = confirmed absent; "**POLLUTED**" = confirmed present at file:line;
"unknown" = needs instrumentation. Cells cover the production path only.

| Path | DB | Disk I/O | Network | Image decode | Sync cache-miss fill | Per-frame alloc | Main-thread pixel work | SwiftUI churn | Actor hops / tasks |
|---|---|---|---|---|---|---|---|---|---|
| **Scroll (settled)** | clean (no sqlite3_* outside the store; store actor-owned) | clean | clean | clean (NSCache lookup only, `ThumbnailFeed.swift:90-92`) | clean (non-resident → placeholder, never blocks) | **POLLUTED** — slot/group/UID arrays + Sets per frame (`MetalGridCoordinator.swift:1633-1733`), `[Vertex]` arrays (`MetalGridRenderer.swift:142-151`), evict Set+sort when over budget (`GridTextureResidencyPolicy.swift:74-75`) | **POLLUTED** — up to 96 CGContext normalizations + replaceRegion in `draw()` (`MetalGridTextureCache.swift:70-137`) | clean — zero SwiftUI invalidation during scroll (level binding written only on zoom commit, `MetalProductionGridView.swift:210`) | clean (no Task/await in the frame loop; feed lookup is a nonisolated NSCache read) |
| **Live pinch** | clean (`PhotoDiagnostics.recordDBQuery` tripwire, 0 during pinch) | clean | clean | clean | clean | mostly clean — `GridZoomTransaction.frame()` slots array + focusRow sort ≤cols; plan build only at detent crossing | **POLLUTED** (same upload path runs during pinch) | clean | clean — `PinchLiveZoomDriver.update()` O(1), allocation-free (`PinchLiveZoomDriver.swift:120-155`) |
| **± zoom click** | clean | clean | clean | clean | clean | **POLLUTED (per-event)** — lattice built TWICE per begin + dead eligibility dicts (`GridTransitionController.swift:37-45`) | **POLLUTED** (target-set prefetch uploads land on the begin frame) | clean | clean |
| **Resize / sidebar** | clean | clean | clean | clean | clean | clean-ish — presentation path draws cached surface; ONE settle at end; diagnostic double-framePlan throttled to 3 Hz (`MetalGridCoordinator.swift:482-496`) | clean (live resize presents scaled cached surface; deliberately avoids `presentsWithTransaction` ~80 ms stalls, `MetalGridScrollHost.swift:318-321,1013`) | clean | clean |
| **Overview dissolve** | clean | clean | clean | clean | clean | **POLLUTED** — 2× buildRealGroups + streamTextures per frame; per-group `makeBuffer` (`MetalGridRenderer.swift:180`); layers re-rastered every frame (`:262-263`) | **POLLUTED** (uploads still run) | clean | clean |

Adjacent paths traced (not in the five, but they feed them): **cold launch** — all SQLite off-main,
but every library-array pass (dedup, flatMap, `[PhotoUID:Int]` index, per-item Calendar month
markers) runs on the main actor (`TimelineViewModel.swift:243-259`, `MetalGridDataSource.swift:66-72`,
`MetalGridCoordinator.swift:289-298`, `MetalGridProductionAdapter.swift:36-45`), plus a synchronous
GPS-index decrypt on main (`OfflineLibraryManager.swift:155`). **Viewer open** — previews decrypt +
decode *on the main actor* (`PhotoViewerModel.swift:374-375,400-405`); originals correctly detached.
**Selection/accessibility** — exemplary: a11y is lazy per *visible* cell at ≤10 Hz
(`MetalGridAccessibilityProvider.swift:32-76`), marquee is viewport-bounded, selection setters
equality-guarded.

---

## 4. CPU findings

### CPU-lru-evict-fullsort-per-frame — **P0 / confirmed / CPU** `[verified×2, measured]`
- Files: [GridTextureResidencyPolicy.swift:72-86](Packages/ProtonPhotosKit/Sources/GridCore/GridTextureResidencyPolicy.swift), call sites [MetalGridCoordinator.swift:1664](Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridCoordinator.swift) (settled), :1551 (transition), :1492 (dissolve); budgets `AppKitMetalGridTexturePolicy.swift:18`, `UIKitMetalGridTexturePolicy.swift:28-41`.
- Current cost: once `resident > capacity` — i.e. **every frame with ≥1 completed upload after the
  cache first fills** (~4,096 distinct thumbnails seen; uploads complete synchronously into
  `resident` the same frame) — `evictToBudget()` allocates `resident.subtracting(pinned)` (a fresh
  ~4,096-entry Set of two-String keys) and full-sorts all evictable IDs with two `lastUsed`
  dictionary lookups per comparison. Two independent `-O` replica benchmarks: **26.3 ms/call**
  (88-char realistic Proton IDs, cap 4096) and **10.9 ms/call** (same shape, second bench) on an
  M-series Mac; cost is identical whether evicting 1 or 96 items. iOS tiers measured 1.2–6.9 ms.
- Worst-case iOS/iPadOS risk: 1–7 ms of pure bookkeeping inside an 8.3 ms 120 Hz budget, on the
  frames that are already the busiest (scroll + uploads). On macOS today it is a guaranteed
  dropped frame per upload-frame during sustained scroll.
- Recommendation: replace the full sort with O(R) partial selection of the k lowest ticks
  (k = `resident.count − capacity`, small), or a single-pass packed `[(tick: Int32, idx)]` scan with
  no dictionary lookups in the comparator; filter pinned inline instead of `subtracting`. Keep the
  O(1) under-capacity fast path.
- Expected gain: ~11–26 ms returned per upload-frame on macOS; removes a per-frame ~capacity-sized
  Set allocation. Eviction semantics unchanged.
- Regression risk: low — pure bookkeeping; must evict exactly the lowest-tick non-pinned IDs.
- Required tests: equivalence test (k evicted == k lowest-tick non-pinned); micro perf guard at
  4096 resident / 96 over (expect ≥10×). Existing `GridPolicyTests` stay green.
- Apple-doc confirmation: no. Expensive model for implementation: no.

### CPU-mainthread-upload-redraw — **P1 / confirmed / CPU** `[cited + self-verified]` *(merges the two upload findings)*
- Files: [MetalGridTextureCache.swift:70-137](Packages/ProtonPhotosKit/Sources/MetalGridTextureCore/MetalGridTextureCache.swift), [MetalGridCoordinator.swift:1783-1799](Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridCoordinator.swift), `AppKitMetalGridTexturePolicy.swift:18`.
- Current cost: `uploadVisible` runs inside `draw()` on the main thread. Each upload does a full
  CGContext RGBA8 redraw — which is a **pure format-normalization copy** in production, because the
  feed already decodes pre-sized to 320px (`ThumbnailImageDecoder.swift:10-21`, so `scale == 1`) —
  plus a ~400 KiB `replaceRegion`. Budget is count-based (96/frame macOS): worst case ≈ 77 MB of
  main-thread copies in one frame, tens of ms. `uploadMsThisFrame` is measured but never consulted.
- Worst-case iOS/iPadOS risk: the render loop shares the main thread with UIKit input; 24–48
  normalization blits per frame drop ProMotion frames during fast scroll on A-series.
- Recommendation: (a) normalize to RGBA8 once at decode time in the off-main decode lanes (store the
  ready buffer in `DecodedThumbnail`), leaving only `replaceRegion` on main; (b) convert the upload
  budget to hybrid count+time (stop after ~2 ms, carry over in priority order). Apple documents
  `replaceRegion` as a CPU copy with no GPU sync, so a time-boxed main-thread copy is legitimate
  (see §11); a staging-blit path to `.private` textures is the optional follow-on.
- Expected gain: halves per-upload main-thread cost immediately; bounds worst-case upload stall to a
  fixed ms budget; cold-fill becomes jank-free (fills over a few more frames).
- Regression risk: DecodedThumbnail transiently holds a second buffer unless the CGImage is dropped
  after normalization; exotic formats (CMYK/16-bit/gray) need the redraw fallback. First-content
  veil could lift slightly later — test it.
- Required tests: time-budget carry-over preserves priority order; normalized bytes == CGContext
  output for RGB/gray/CMYK fixtures; synthetic 500-tile cold fill asserts `uploadMsThisFrame ≤ budget`;
  first-content-ready latency.
- Apple-doc confirmation: no. Expensive model: yes (touches cache/feed/decode seams).

### CPU-mainactor-library-passes — **P1 / confirmed / CPU** `[cited ×2 agents, convergent]` *(merges gap4/gap5 findings)*
- Files: [TimelineViewModel.swift:243-259](Packages/ProtonPhotosKit/Sources/TimelineFeature/TimelineViewModel.swift), [MetalGridDataSource.swift:66-72](Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridDataSource.swift), [MetalGridCoordinator.swift:289-298](Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridCoordinator.swift), [MetalGridProductionAdapter.swift:36-45](Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridProductionAdapter.swift).
- Current cost: every data arrival (launch, refresh completion, route switch) runs on the main
  actor: `deduplicatedSections` (Set-insert hashing two strings per item) + `flatMap` copies + full
  `fresh != allItems` deep equality + crawl-order sort + `RealMetalGridDataSource` init (flatMap +
  videoUIDs Set) + `rebuildIndex` (`[PhotoUID:Int]` over the whole library) + month markers calling
  `Calendar.dateComponents` **per item**. ≈30–80 ms at 20k; ≈0.2–0.5 s at 100k; ≈1–3 s at 500k.
- Worst-case iOS/iPadOS risk: main-thread hang on every sync completion at 100k+; watchdog
  (0x8badf00d) territory at 500k.
- Recommendation: build `{sections, allItems, markers, indexMap, videoUIDs}` in a detached task
  (the functions are already pure/nonisolated-shaped) and deliver one immutable bundle for a single
  main-actor swap. Replace the O(n) equality with the store's digest/dataToken fingerprint. Derive
  month markers in one pass over the already-sorted `captureTime` (month-boundary binary search)
  instead of per-item `dateComponents`. This matches Apple's main-actor batching guidance (§11).
- Expected gain: refresh main-thread occupancy O(n)→O(1); 500k becomes viable.
- Regression risk: medium — route-switch race guards (`guard filter == f` after each await) must
  survive the extra hop; sections+markers must swap atomically with dataToken.
- Required tests: main-actor occupancy guard (<50 ms at 20k end-to-end loadAll); markers/index
  equality vs the synchronous versions; existing route-switch race tests; scroll-position
  preservation on unchanged refresh.
- Apple-doc confirmation: no. Expensive model: yes (concurrency restructuring).

### CPU-transition-lattice-built-twice — **P2 / confirmed / CPU** `[verified×1]`
- Files: [GridTransitionController.swift:37-45,61-69](Packages/ProtonPhotosKit/Sources/GridCore/GridTransitionController.swift), `ClickZoomTransitionScheduler.swift:13-15`, `PinchZoomTransitionScheduler.swift:14-16`, `GridTransitionSelectionEligibility.swift:14-29`, `GridTransitionComponentBuilder.swift:86-172`.
- Current cost: `beginClick`/`beginPinch` build the lattice (dicts, union-find, 4 sorting median
  fits, area peaks), then the scheduler's `makePlan` builds the identical lattice **again** and
  discards the first; `relocatingIdentities` additionally builds two inverse dicts + a Set
  intersection whose only consumer unconditionally returns `true` (dead work — the same dicts are
  built a third time inside `build()`). Runs per ± click and per pinch detent crossing —
  ~0.1–0.5 ms duplicated on the most hitch-sensitive frame of the gesture.
- iOS risk: detent-crossing frames on A-series also build two framePlans + fire the target prefetch;
  doubling plan-build cost there is the likeliest single-frame hitch of a chained pinch.
- Recommendation: pass the already-built lattice into `makePlan`; delete the `relocatingIdentities`
  call. Preserve the `.latticeBuildFailed` vs `.scheduleDegenerate` reason split.
- Expected gain: halves begin cost; zero behavior change (plans byte-identical).
- Regression risk: low (mechanical). Tests: fixture equality old vs new plan; existing scheduler tests.
- Apple-doc: no. Expensive model: no.

### architecture-string-pair-identity-hot-path — **P2 / likely / architecture** `[verified×1]`
- Files: [PhotosDomain.swift:6-13](Packages/ProtonPhotosKit/Sources/PhotosCore/PhotosDomain.swift), [MetalGridCoordinator.swift:1643-1655,1673-1733,1783-1798](Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridCoordinator.swift), `GridTextureStreamingPolicy.swift:14-25`.
- Current cost: the per-frame hot path is keyed by `PhotoUID` = two long base64 Strings. The verifier
  counted ~9–12 hashed Set/Dict ops per id per frame (window build, priority loops, isResident /
  noteUsed / texture / selected / favorite / isVideo, pending scan) × ~100–200 ids at L3 (up to
  ~2,000 at L5) ≈ 0.1–0.4 ms/frame at default zoom, more at overview. Also feeds the P0 evict sort
  comparator. The miss path additionally allocates an interpolated NSString key per `hasImage` call
  (`ThumbnailFeedCore.swift:693-695`).
- iOS risk: constant frame tax inside the 8.3 ms budget + allocator pressure.
- Recommendation: key the per-frame path by `Int` flat index (already the render identity in
  `GridRenderSlot`); translate to `PhotoUID` only at the loader/cache boundary (once per upload).
  Instantiate the generic policies with `Int` — GridCore needs no change.
- Expected gain: ~5–10× cheaper per-op hashing; shrinks the evict-sort constant too.
- Regression risk: medium — index↔UID mapping must invalidate atomically with data generations
  (stale indices would draw wrong thumbnails).
- Tests: data-mutation mid-scroll identity tests; micro-guard streamTextures Int vs PhotoUID.
- Apple-doc: no. Expensive model: yes.

### IO-diskcoverage-actor-stall — **P1 / confirmed / CPU-IO** `[cited]`
- Files: [ThumbnailCache.swift:263-284](Packages/ProtonPhotosKit/Sources/MediaByteCache/ThumbnailCache.swift), [ThumbnailFeedCore.swift:386-425,451](Packages/ProtonPhotosKit/Sources/MediaFeedCore/ThumbnailFeedCore.swift), `App/Offline/OfflineLibraryManager.swift:106-135`.
- Current cost: `prefetchStatus()` computes disk coverage as **one `fileExists` stat per library
  item** plus full directory enumerations, inside the feed actor, polled every 1.5 s by the toolbar
  pill during warm-up and on worker drains. 20k ≈ 20–60 ms/poll; 500k ≈ 0.5–2 s stall per poll — the
  same actor that serves visible-tile decodes is starved for the whole initial crawl.
- iOS risk: slower flash + battery burn; placeholder-heavy scrolling during warm-up.
- Recommendation: maintain an incremental counter (seed once, adjust on store/evict); move
  size/file-count enumeration to the on-demand Settings path only.
- Expected gain: feed actor freed during warm-up; visible thumbnails keep filling.
- Regression risk: low (a slightly stale percent is harmless; keep repass heuristic consistent).
- Tests: counter == directory ground truth across store/evict/clear; `prefetchStatus()` <5 ms @20k.
- Apple-doc: no. Expensive model: no.

### P3 CPU items (all `[cited]` or `[verified×1]`, fix opportunistically)
- **CPU-commit-bridge-per-frame-rebuild** [confirmed] — `GridZoomCommitBridge.frame()` rebuilds both
  endpoint frames + 4 dicts every bridge frame (~10–19 frames/160 ms) though only `progress` changes;
  release rebuilds them twice more (`GridZoomCommitBridge.swift:93-171`, `MetalGridCoordinator.swift:414-417`).
  Cache endpoints at arm; ~50–200 µs/frame back. Tests: frame(progress:) equality.
- **CPU-framePlan-micro-allocations** [confirmed] — visibleSlots lacks `reserveCapacity`; coordinator
  re-maps GridSlot→GridRenderSlot then renderTranslate maps again (3 passes over ~100–200 elements)
  (`SquareTileGridEngine.swift:514-518,421-451`; `MetalGridCoordinator.swift:1633-1635`). Reserve +
  fold one map. Do **not** cache ResolvedGrid (S=1 rebuild is ~free).
- **CPU-digest-resort-of-presorted-input** [confirmed] — `save()` re-sorts input already sorted by
  the bridge (`TimelineMetadataStore.swift:389` vs `DriveSDKBridge.swift:494`); add O(n) is-sorted
  precheck.
- **CPU-coalescer-task-per-decode-callback** [confirmed] — one unstructured Task per decode callback
  (`PhotoDimensions.swift:58`); hundreds/s during crawl; batch via lock-guarded pending dict.
- **CPU-marquee-slot-materialization + redundant filter** [verified×1, downgraded from P2] — marquee
  materializes O(items-in-rect) GridSlots + a *redundant* `.filter` copy
  (`SquareTileGridEngine.swift:643-647`; the `:646` filter duplicates the `:442` intersects guard).
  Verification refuted the escalation scenario: **no marquee autoscroll exists** (grep: zero
  `autoscroll` hits), so rects are pointer-travel-bounded today. Delete the redundant filter now;
  adopt per-row index-range queries if marquee autoscroll or iPad drag-select ever ships.
- **CPU-marquee-selection-scale** [likely] — Set-union + 3 O(selected) equality compares per marquee
  step (`GridSelectionController.swift:61-66`); fine at viewport scale; defer until profiling.
- **architecture-multisection-per-frame-resolve** [hypothesis, future-only] — `resolved()` is O(S)
  per query and section scans are linear (`SquareTileGridEngine.swift:489-543,424,457`); zero cost at
  S=1 today, but memoize + binary-search before physical date sections ever ship, else a silent
  120 Hz cliff appears only on iOS.

---

## 5. GPU / Metal findings

Confirmed per-surface budget (from code, all `[cited + self-verified]`):

| Surface | CBs | Passes | Encoders | Draw calls / binds | Notes |
|---|---|---|---|---|---|
| Settled | 1 | 1 | 1 | ~180 @L3 … **~2,000 @L5** per invalidated frame | 1 pipeline, blended quads over clear; non-resident tiles draw nothing (placeholder cost ≈ 0 fragments); typical overdraw 1–2 layers/px |
| Pinch/click lattice | 1 | 1 | 1 | ≤ ~2× tile draws | alpha-weighted single pass — TBDR-optimal |
| Overview dissolve | 1 | **3** | **3** | 2× full grid rasters + 1 composite | both layers re-rastered **every frame** though geometry is frozen; per-group `makeBuffer`; ~3 fullscreen bgra8 writes ≈ 50 MB traffic/frame @2560×1600 |

### GPU-perquad-draws-overscan-encode — **P1 / confirmed / GPU** `[cited + self-verified renderer loop]`
- Files: [MetalGridRenderer.swift:192-199](Packages/ProtonPhotosKit/Sources/MetalRenderingCore/MetalGridRenderer.swift), [MetalGridCoordinator.swift:1633-1648,1673-1733](Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridCoordinator.swift), [SquareTileGridEngine.swift:584-594](Packages/ProtonPhotosKit/Sources/GridCore/SquareTileGridEngine.swift).
- Current cost: one draw + one `setFragmentTexture` per resident tile, and the encoded set spans the
  full **3.4×-viewport overscan band** (1.2×H above + below), not just the viewport: ~2,000
  draws+binds at L5 per invalidated frame. Offscreen quads are GPU-clipped but fully paid on the CPU
  encoder. Apple documents exactly this pattern (per-draw texture binding) as the CPU cost center
  argument buffers/bindless exist to fix (§11).
- iOS risk: 2,000 draws/frame on A-series during L5 scroll blows the 120 Hz budget and burns battery.
- Recommendation, in order: (1) **cheap first step** — encode draws only for viewport-intersecting
  slots (keep the overscan set for texture streaming/pinning only): ~3.4× fewer draws, near-one-line;
  (2) evidence-gated structural step — thumbnails are a uniform ≤320px class: Tier-2
  argument-buffer/bindless table (A13+/all Apple Silicon; 1M textures per stage from Apple6) or a
  `texture2d_array` (2048 uniform slices) + one instanced draw. Gate on the counters in §14.
- Expected gain: encoder CPU at dense levels from multiple ms to <1 ms; drawCalls ~2,000 → ~600
  (filter) → ~1–6 (bindless).
- Regression risk: viewport filter must use render-space rects (post `renderTranslate`) or edge tiles
  vanish during rebase/dissolve; bindless needs `useResource`/`useHeap` residency declarations and
  GPU-family gating.
- Tests: HUD drawCalls/gpuDrawMs before/after at L5 scroll; edge-tile visibility during rebase and
  transitions; draw-count regression guard via `lastDrawCalls` on a fixture slot set.
- Apple-doc: yes (§11). Expensive model: yes (for step 2; step 1 no).

### GPU-dissolve-double-reraster — **P2 / confirmed / GPU** `[cited + self-verified]`
- Files: [MetalGridRenderer.swift:249-281,180](Packages/ProtonPhotosKit/Sources/MetalRenderingCore/MetalGridRenderer.swift), [MetalGridCoordinator.swift:1480-1502](Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridCoordinator.swift).
- Current cost: every dissolve frame re-rasterizes both frozen layers (2 offscreen passes) + a
  composite pass, re-runs buildRealGroups+streamTextures twice on the CPU, and allocates per-group
  `MTLBuffer`s (the `pooledSlot=nil` path). On TBDR every offscreen pass is a full tile-memory →
  device-memory round trip (§11) — the most bandwidth-expensive thing the app does.
- iOS risk: held pinch at overview = sustained triple-pass fullscreen bandwidth on iPad → heat +
  dropped frames.
- Recommendation: rasterize layerA/B once at `beginOverviewDissolve`; mark a layer dirty only when a
  wanted texture uploads (`uploadsThisFrame > 0` for that layer) or drawable resizes; per-frame =
  composite only. Route dissolve vertices through the pooled ring.
- Expected gain: dissolve frame → 1 fullscreen mix draw; CPU group-build → 0 for static frames;
  ~2/3 of dissolve bandwidth removed.
- Regression risk: stale layer if an upload lands mid-gesture without the dirty hook; resize
  mid-gesture must re-raster both.
- Tests: pinch-hold L3↔L4 with cold cache (tiles must still appear); resize-during-dissolve; visual
  parity of mix(A,B,t).
- Apple-doc: yes (TBDR pass cost, §11). Expensive model: no.

### GPU-fixed-320px-no-mips-detent-blind — **P2 / confirmed / GPU** `[cited + self-verified descriptor]`
- Files: [MetalGridTextureCache.swift:28,110-137](Packages/ProtonPhotosKit/Sources/MetalGridTextureCore/MetalGridTextureCache.swift), `ThumbnailFeed.swift:24`, `SquareTileGridEngine.swift:321-327`.
- Current cost: decode and upload are fixed at 320px across all six detents; `mipmapped: false`. At
  macOS L5 the tile is ~94px@2x → ~11.6× texel over-supply; iPhone L5 ~39px@3x → ~33×; minification
  without mips = bandwidth waste + scroll shimmer. Conversely L0 tiles (~940px@2x) upscale a 320px
  texture ~2.9× (soft).
- Recommendation: level-aware upload size (≈ slotSide × backingScale, re-upload on detent commit) —
  preferred because it also collapses the residency byte pressure (§7); or generate mips at upload.
- Expected gain: ~4–10× less sampling bandwidth at L4/L5; sharper L0.
- Regression risk: re-upload churn on detent change (bounded by upload budget); mixed-resolution
  layers during the L4↔L5 dissolve.
- Tests: per-level guard `uploadedTexturePixels ≤ k×(slotSide×scale)`; TileContentFitter UV
  invariance vs texture size.
- Apple-doc: yes. Expensive model: no.

### P3 GPU items
- **memory-dissolve-layers-retained** [confirmed, self-verified] — layerA/B (2 fullscreen private
  bgra8 targets, ~33 MB combined @2560×1600, more at 5K) are created lazily and **never released**
  after the first dissolve (`MetalGridRenderer.swift:219-227`). Nil them on dissolve commit or after
  N idle frames.
- **memory-no-heap-linear-thumb-textures** [confirmed] — up to 96 `makeTexture` calls/frame during
  fill; no `MTLHeap`/recycle pool, no `optimizeContentsForGPUAccess` anywhere (grep: 0). A
  fixed-size-class slab/recycle pool (dimensions-keyed) removes allocator churn; heap aliasing needs
  the same 3-frame boundary as the vertex ring. Apple: shared textures populated by `replaceRegion`
  don't get lossless bandwidth compression unless `optimizeContentsForGPUAccess` runs (§11) — one
  blit after upload, or private-via-staging.
- **CPU-perframe-group-array-churn** [confirmed] — intermediate `[Vertex]` arrays (~69 KB @L3,
  ~770 KB @L5) rebuilt per frame then memcpy'd into the ring (`MetalGridRenderer.swift:139-165`);
  write vertices directly into the pooled buffer + reuse scratch arrays with
  `removeAll(keepingCapacity:)`.

Shader notes (read in full): rounded-corner SDF + premultiplied alpha, one pipeline; dissolve
composite is an opaque fullscreen-triangle `mix(A,B,t)` — all sound. Runtime
`makeLibrary(source:)` is a one-time init cost — acceptable in SPM.

---

## 6. Memory / cache findings

Cache budget matrix (every major cache, verified owners and numbers):

| Cache | Owner (module/layer) | Representation | Bytes/item | Budget + enforcement | Pressure response | Purge | Policy home |
|---|---|---|---|---|---|---|---|
| Decoded thumbnails (RAM) | `ThumbnailFeedCore.decoded` (MediaFeedCore, Core) | NSCache<NSString, CGImage box>, cost = w·h·4 | ≤320²·4 ≈ 400 KiB, typ. ~307 KiB | macOS clamp(15% RAM, 256 MB, **20 GB**) `ThumbnailFeed.swift:58-63`; iOS clamp(8%, 96 MB, 1 GB) | NSCache implicit only | none | mechanism Core, numbers adapter — **correct split**; macOS ceiling absurd |
| NSImage wrappers | ThumbnailFeed (AppKit adapter) | NSCache, countLimit 512 + clamp(0.5%,16,96 MB) | shares CGImage backing (double-counted cost) | `ThumbnailFeed.swift:54-55` | NSCache implicit | none | adapter ✓ |
| Disk thumbs/previews | `ThumbnailCache` ×2 (MediaByteCache, Core) | AES-GCM blobs; plaintext NSCache RAM tier **dead** (no production callers) | thumb 20–40 KB, preview 0.3–1 MB | disk deliberately **uncapped**; RAM tier clamp(2%,64 MB,2 GB) each — unused | NSCache implicit | settings clear / sign-out | mechanism Core ✓; dead tier → delete or wire (P3) |
| GPU textures | `MetalGridTextureCache` (Core) | `[ID: MTLTexture]` dict | ≤400 KiB (320²·4) | **count only**: 4096 macOS / 768–1536 iOS; `residentBytes` tracked, unused | **none** | none (built once, never reset) | numbers adapter ✓; byte cap missing (P0/P1, §7) |
| Viewer full images | `PhotoViewerModel.fullImageCache` (Feature) | static NSCache, countLimit 40, **no cost** | 12 MP = 48.8 MB … 48 MP = 195 MB | none — up to **7.8 GB theoretical** | NSCache implicit | none | **no policy at all** (P1) |
| Offline originals (disk) | ThumbnailCache "originals" + OfflineLibraryManager (App) | AES-GCM blobs | 2–50 MB | 5 GB LRU, enforced off-main | n/a | toggle purge / master reset | acceptable |
| Video blocks | `VideoByteRangeCache` + resource loader (App target) | encrypted .blk disk + decrypted NSCache countLimit 20 | ~4 MB/block | disk 512 MB hard-coded; RAM ~80 MB count-based | NSCache implicit | sign-out/settings | **App-layer, no split** (P3) |
| DB + WAL | TimelineMetadataStore (Core) | SQLite; loaded `[PhotoItem]` | ~420 B/row incl. index | pragmas policy-injected (mmap 0 Core default / 256 MB desktop adapter) | n/a (clean pages) | sign-out purge incl. sidecars | **correct split**; WAL cap missing (P2) |
| Crawl bookkeeping | ThumbnailFeedCore + ThumbnailCache | `[String:Bool]` + `Set<String>` | ~230 B + ~100 B per item | **unbounded**, O(library) | none | never | P2 below |

Combined worst case @500k on a 16 GB Mac: decoded 2.4 GB + byte tiers ~1 GB + GPU 1.3–1.7 GB (or
2.2 GB with pinned overflow) + viewer 1.9–7.8 GB + bookkeeping ~170 MB ≈ **7–13 GB**, coordinated by
nothing but NSCache opportunism. On a 6 GB iPhone with existing adapters (no viewer): ≈0.7 GB+
foreground before the pinned-overflow scenario — which alone adds ~1 GB.

### memory-pinned-overflow-dense-detents — **P0 / confirmed / memory** `[cited + self-verified mechanism & arithmetic]`
- Files: [GridTextureResidencyPolicy.swift:48-57,72-86](Packages/ProtonPhotosKit/Sources/GridCore/GridTextureResidencyPolicy.swift), [GridTextureStreamingPolicy.swift:14-25](Packages/ProtonPhotosKit/Sources/GridCore/GridTextureStreamingPolicy.swift), [SquareTileGridEngine.swift:321-327](Packages/ProtonPhotosKit/Sources/GridCore/SquareTileGridEngine.swift), `UIKitMetalGridTexturePolicy.swift:28-41`.
- Current cost: `selectUploads` never checks capacity; `evictToBudget` evicts only
  `resident ∖ pinned`; pinned = visible + 2×overscan. At L5 (30 fixed columns): macOS 900×1600pt
  portrait → pitch 30pt → ~181 rows in the 3.4×H band × 30 ≈ **5,440 pinned > 4,096 cap** →
  ~2.2 GB resident, cap silently inert (self-verified arithmetic). iPhone compact L5 ≈ 4,900 pinned
  × 196 KiB ≈ **0.99 GB vs the intended 154 MB**; iPad expanded L5 ≈ 3,630 × 324 KiB ≈ 1.2 GB.
- Worst-case iOS/iPadOS risk: certain jetsam the moment a user pinches to densest overview on a big
  library — GPU allocations count fully against footprint on Apple Silicon (WWDC22 10106, §11).
- Recommendation: hybrid budget owned by GridCore (§7): byte cap + count cap + **pinned-overflow
  degradation** — when pinned cost alone exceeds the byte cap, clamp pinning to strictly-visible
  and/or drop upload pixel size at dense detents (L4/L5 need ≤128px tiles, not 320px — which also
  fixes GPU-fixed-320px). Adapters keep supplying numbers only.
- Expected gain: hard platform memory ceiling; removes the jetsam scenario; 10–30× less GPU memory
  at dense detents once uploads are tile-sized.
- Regression risk: placeholder flicker on scroll reversal at dense levels if eviction gets too eager;
  L4↔L5 dissolve must tolerate mixed-resolution layers.
- Required tests: see §16 (the static worst-case guard **fails today** — it is the executable form of
  this finding).
- Apple-doc: yes (footprint accounting). Expensive model: yes.

### memory-no-pressure-coordination — **P1 / confirmed / architecture** `[cited, grep-confirmed]`
- Files: repo-wide — grep for `DispatchSource.memoryPressure` / `didReceiveMemoryWarning` /
  `thermalState` = **zero hits**.
- Current cost: every cache has an independent static budget; non-NSCache holdings (GPU texture dict,
  viewer cache, bookkeeping dicts) never shrink at all. Under pressure nothing is deterministic.
- iOS risk: iOS delivers one memory warning and then jetsams within seconds; with no hook the app
  dies instead of degrading. Hard prerequisite for the port; also reduces swap-induced hitches on
  8–16 GB Macs.
- Recommendation: small Core `MemoryPressureGovernor` (onWarning/onCritical), sources injected by
  adapters (macOS `DispatchSource.makeMemoryPressureSource`; iOS `didReceiveMemoryWarningNotification`).
  Responders: decoded NSCache (floor the limit), byte-tier NSCaches (removeAll — disk retains),
  texture cache (evict to visible-only), viewer cache (removeAll). Follow the platform-correct
  semantics: on the *dispatch-source* signal reduce future cache sizes; on the *UIKit warning* purge
  (the two contracts differ — §11).
- Expected gain: deterministic multi-GB shedding within one runloop of a warning.
- Regression risk: over-aggressive shedding on spurious warnings → re-decode churn; keep
  visible-pinned textures.
- Tests: governor fan-out unit test; guard that all cache owners register; macOS manual
  `sudo memory_pressure -l warn` while scrolling.
- Apple-doc: yes. Expensive model: no.

### memory-viewer-fullres-cache — **P1 / confirmed / memory** `[cited ×2 agents, convergent]`
- Files: [PhotoViewerModel.swift:309-311,365,472](Packages/ProtonPhotosKit/Sources/PhotoViewerFeature/PhotoViewerModel.swift), [ViewerFullImageDecoder.swift:15-31](Packages/ProtonPhotosKit/Sources/PhotoViewerCore/ViewerFullImageDecoder.swift).
- Current cost: originals decode at **full native resolution** (fallback max 100,000 px) into a
  static NSCache with countLimit 40 and **no cost limit** — 40 × 48 MP ≈ 7.8 GB theoretical, 1–2 GB
  after casual browsing. The unbounded decoder lives in *universal* PhotoViewerCore.
- iOS risk: the single most jetsam-prone pattern in the codebase — 3–5 rapid full-res decodes exceed
  a 4 GB iPhone's limit.
- Recommendation: `maxPixelSize` parameter on the decoder, platform-injected (screen long edge ×
  scale × ~1.5); `totalCostLimit` + per-object cost (w·h·4) on the cache; escape hatch for deep-zoom
  region decode if 1:1 inspection matters.
- Expected gain: bounds the dominant unbounded RAM consumer; faster decodes.
- Regression risk: revisit shows brief preview→sharp upgrade; deep-zoom sharpness cap.
- Tests: 100 MP synthetic respects cap + EXIF orientation; cost-limit enforcement; footprint plateau
  over 50-photo swipe.
- Apple-doc: no. Expensive model: no.

### Other memory findings
- **memory-crawl-bookkeeping-unbounded — P2 confirmed** `[cited]` — `DiskPresenceCache [String:Bool]`
  (~115 MB @500k, and possibly write-only — check for readers, then delete) + `ValidatedPresence`
  Set (~50–60 MB @500k ×3 instances) (`ThumbnailFeedCore.swift:761-771`,
  `ThumbnailCache.swift:329-336`). Replace with index-keyed bitsets or delete.
- **DB-wal-highwater-no-limit — P2 likely** `[cited]` — no `journal_size_limit`, no explicit
  checkpoint anywhere; first 500k save spikes the WAL to ~DB size and it stays at high-water forever
  (`TimelineMetadataStore.swift:206-210,405`). Add `journal_size_limit=16MB` +
  `wal_checkpoint(TRUNCATE)` after large saves.
- **CPU-video-store-full-tree-walk — P2 confirmed** `[cited]` — `enforceBudget` walks the entire
  512 MB cache tree on **every 4 MB block write**, under the same lock the read path contends on
  (`VideoByteRangeCache.swift:56,73-98`). Keep a running byte total.
- **memory-percent-budget-overcommit — P3 likely** — independent budgets sum to ~21.5% of RAM in
  NSCaches alone; decoded ceiling 20 GB is effectively unbounded; wrappers double-count shared
  CGImage backing. One policy table with an explicit total; drop decoded ceiling to 1–2 GB.
- **memory-thumbs-disk-uncapped — P3 confirmed** — deliberate on macOS; on iOS `Caches/` may be
  purged by the OS → full re-crawl; decide an explicit iOS cap (enforceByteCap already exists) or
  document the re-crawl path (crawl checkpointing already survives partial purges).
- **architecture-video-cache-app-layer — P3 confirmed** — the only cache family without the
  Core-mechanism/adapter-policy split; move behind a `VideoCachePolicy` before the port.
- **architecture-dead-plaintext-byte-tier — P3 confirmed** — ThumbnailCache's RAM tier holds a 2%
  budget and has no production callers; delete it or deliberately wire it (decide, don't keep both).

---

## 7. Texture residency findings

Direct answers to the required questions:

- **Is count-only residency enough? No.** Two independent failure modes: (a) count×size is
  unbounded in bytes if pixel size ever changes (silent 2–4× growth); (b) the pinned set can exceed
  the count cap entirely (P0 above), at which point the budget is inert.
- **Worst case at current macOS settings**: 4,096 × 320²×4 = **1.68 GB** (typical mixed-aspect
  ≈1.26 GB) — plus the pinned-overflow case ≈ **2.24 GB** at L5 portrait. `residentBytes` is already
  tracked exactly (`MetalGridTextureCache.swift:25,83-86`) but drives nothing.
- **Worst case at iOS settings**: intended 154 / 268 / 510 MB (compact/regular/expanded); actual
  worst with pinned overflow ≈ **0.99 GB iPhone / 1.2 GB iPad** — against community-measured ~2 GB
  foreground limits on 4 GB devices (no official numbers exist; §11).
- **How should viewport, thumb size, pressure, surface class influence budget?** Pinned demand =
  f(viewport, detent, overscan) — computable in closed form from the engine (rows×cols in the
  3.4×H band × bytes/texture). The byte budget must be ≥ the worst pinned working set the platform
  intends to allow, or the policy must *degrade* (shrink pinning to visible, shrink upload pixel
  size) rather than overflow. Pixel size should be detent-aware (≈ slotSide×scale), which shrinks
  pinned bytes at exactly the detents where pinned count explodes: at L5 with ~128px uploads, 5,440
  pinned ≈ 356 MB instead of 2.2 GB.
- **Static, dynamic, or hybrid? Hybrid.** Static per-surface-class byte caps (adapter numbers, e.g.
  macOS min(512 MB, 5% RAM); iOS 64/96/192 MB by class) + dynamic *demand* (level-aware pixel size,
  pinned-overflow degradation) + a pressure hook that can halve the cap. Fully-static cannot work
  (pinned demand is viewport/detent-dependent); fully-dynamic (per-frame device queries) is overkill.
- **Where should dynamic memory observation live?** Platform adapters. iOS: `os_proc_available_memory`
  (iOS 13+; **not available on native macOS**) + `didReceiveMemoryWarningNotification`. macOS:
  `DispatchSource.makeMemoryPressureSource` (system-wide pressure). Both feed the Core governor as
  plain numbers/events — same pattern as `GridTextureBudget`. `MTLDevice.currentAllocatedSize` and
  `recommendedMaxWorkingSetSize` (iOS 16+) are the sanctioned GPU-side observability (§11).
- **Exact tests needed before implementation**: §16, items T3.

Also relevant here: `setPurgeableState(.volatile)` on evicted-but-cached textures is Apple's blessed
mechanism for keeping idle GPU resources out of the footprint entirely (§11) — a good follow-on after
the byte budget, not a substitute for it.

---

## 8. Thumbnail decode / upload findings

Pipeline (network → visible texture), stage by stage — 7 distinct byte buffers, 1 redundant, 2
duplicated on the settle path:

| # | Stage | Thread/actor | Copy | Verdict |
|---|---|---|---|---|
| 1 | SDK batch fetch → plaintext Data (`ThumbnailFeedCore.swift:546-577`) | detached task | 1 | OK — 20s wall-clock timeout + AIMD (4c111c2) |
| 2 | AES-GCM seal + atomic disk write (`ThumbnailCache.swift:179-189`) | loader thread | 2 | OK (security model) |
| 3 | disk read (`diskData`, `ThumbnailCache.swift:156-169`) | feed actor / warm lanes | 3 | runs **twice** via `hasUsableDiskData` probe (P3 below) |
| 4 | AES-GCM open (`SecureBlobCipher.swift:44-47`) | same | 4 | same double-decrypt |
| 5 | ImageIO pre-sized decode, MaxPixelSize=320, transform, cacheImmediately (`ThumbnailImageDecoder.swift:10-21`) | task-group lanes = core count | 5 | **GOOD** — canonical WWDC18-219 pattern, never on main; fixed 320 target is detent-blind (§5) |
| 6 | decoded NSCache, cost = w·h·4 | NSCache | ref | budget ceiling excessive (§6) |
| 7 | render-thread fetch (`ThumbnailFeed.memoryCGImage:90-92`) | main, nonisolated lookup | ref | **GOOD** — no hop, no decode on scroll path |
| 8 | CGContext RGBA8 normalization (`MetalGridTextureCache.swift:110-128`) | **main, inside draw()** | 6 | **REDUNDANT** — scale==1 in production; move to decode time (P1, §4) |
| 9 | `replaceRegion` (`:130-136`, rgba8Unorm, no mips) | main | 7 | unavoidable CPU copy; time-box it |
| 10 | residency/evict | main | — | count-only, pinned-overflow (§7) |

**Should the feed deliver pre-sized decoded CGImages to the texture layer?** It already delivers
pre-sized (320px) CGImages; what's missing is *format-normalized, Metal-ready* buffers. Deliver an
RGBA8 premultiplied, stride-aligned buffer (or keep the CGImage but guarantee its backing matches, with
a fast-path check + redraw fallback for exotic sources). Risk: transiently two pixel buffers per item
unless the original CGImage is dropped after normalization; color-space handling must stay explicit
(deviceRGB draw today ≈ sRGB assumption — fine for 8-bit thumbs, per WWDC16-712 the 8-bit sRGB clip
is a deliberate cheap trade).

Remaining pipeline findings:
- **CPU-unfetchable-visible-displaylink-busyloop — P2 likely** `[cited]` — a *visible* quarantined
  "no thumbnail" item (the 4c111c2 refusal set) can never become resident, so
  `hasPendingVisibleThumbnails` stays true forever → the display link never idles and each pump
  re-probes disk (`MetalGridCoordinator.swift:1649,1795`; `MetalGridScrollHost.swift:812,939`;
  `ThumbnailFeedCore.swift:292-318`). Also blocks `onFirstContentReady` if a refused item is in the
  first viewport. Expose `isUnfetchable` to the render side and exclude quarantined UIDs from both
  checks (clear on `onImagesAvailable`/crawl restart). *Directly relevant to this branch's feature.*
- **IO-offline-priority-retry-and-detached-loader-leak — P2 likely** `[cited]` — the crawl backoff
  doesn't gate the priority (visible) queue, so on a dead network every viewport settle spawns fresh
  20s-timeout batches; timed-out FFI loader tasks accumulate uncapped
  (`ThumbnailFeedCore.swift:546-577,604-607`). Apply a short visible backoff + cap in-flight
  detached loaders (~6); clear backoff on network-path change.
- **IO-double-decrypt-probe-then-read — P3 confirmed** — `hasUsableDiskData` fully decrypts and
  discards, then `diskData` decrypts again (`ThumbnailCache.swift:138-169`): 2× read+GCM per settle
  item; return the plaintext from the probe or use the cheap existence check.

Confirmed-good (protect): pre-sized ImageIO decode with `CreateThumbnailFromImageAlways` semantics;
decode lanes = core count; viewport debouncer (~100 ms) for network reprioritization with immediate
decode pump; AES-GCM disk tier with corrupt-blob self-healing; visible-first upload priority with
in-flight dedup; 20s wall-clock batch timeout + refusal quarantine + AIMD (4c111c2 verified sound —
no retry storm).

---

## 9. DB / core-data-flow findings

Confirmed-good (all re-verified on DB v1, several prior-audit risks now FIXED): canonical
`ORDER BY t, vol, node` riding `idx_photos_timeline` with a query-plan guard (no temp b-tree);
composite PK `(vol,node)`; WAL + synchronous=NORMAL + `PRAGMA optimize` on close; conservative Core
default pragmas (mmap 0, 2 MiB cache) with desktop numbers injected only by the macOS adapter —
**the SIGBUS/jetsam concern from the prior audit is correctly resolved**; digest-based no-op save
skip (persisted across launches); dimensions batched via coalescer actor into PK-indexed
transactions, never touching the timeline digest; **zero SQLite on the main thread; zero SQLite in
any per-frame/per-tile path** (grid aspect comes from the resident texture); no ad-hoc SQL anywhere
else in the repo (grep-verified — search is in-memory, map is an encrypted blob, albums are REST).

### IO-gen-stamp-full-table-rewrite-per-sync — **P1 / confirmed / DB** `[cited; proven by the repo's own 20k guard]`
- Files: [TimelineMetadataStore.swift:416,451-454,479-515](Packages/ProtonPhotosKit/Sources/PhotosCore/TimelineMetadataStore.swift), guard test `TimelineMetadataStoreTests.swift:322-386`.
- Current cost: any changed refresh rewrites **every** row (`gen=excluded.gen` always differs), then
  sweeps via an un-indexed full-scan DELETE, then wholesale-rewrites photo_tags/burst_members. The
  20k micro guard itself records it: **+25/−100 items → 19,925 upsertedRows**. At 500k: ~2.5–6 s in
  one transaction + 150–300 MB WAL churn per single-photo change, with the bridge actor (the whole
  media pipeline) blocked throughout.
- iOS risk: multi-second actor stall after every background sync + flash wear ∝ library size.
- Recommendation: make the changed-save O(changes): temp-table anti-join sweep + a NULL-safe
  `WHERE ... IS NOT excluded....` clause on the DO UPDATE (the `updateDimensions` pattern already in
  the file); rewrite tags/bursts only for changed anchors; `wal_checkpoint(TRUNCATE)` after large
  saves.
- Expected gain: +25/−100 @20k goes from ~19.9k row writes to ~125; 500k syncs from seconds to ms.
- Regression risk: medium — sweep semantics and digest bookkeeping must stay exactly equivalent;
  existing generation-sweep/no-op tests pin most of it.
- Tests: §16 T6. Apple-doc: no. Expensive model: yes.

### Other DB-flow findings
- **architecture-all-route-revisit-full-db-reload — P2 confirmed** `[cited]` — every sidebar return
  to All Photos does a full DB scan + joins + materialization + a full network re-enumeration
  (`TimelineViewModel.swift:148-150,236`); the `.all` route is the only one with no in-memory revisit
  cache. Serve the last `.all` snapshot instantly and refresh behind (the `loadFiltered` pattern).
- **memory-full-materialization-and-string-duplication — P2 confirmed** `[cited]` — full
  `[PhotoItem]` load allocates a fresh heap String per row for the *constant* volumeID
  (`TimelineMetadataStore.swift:318`) and the app holds ~4–6 parallel O(n) copies (~200–350 MB total
  @500k). Intern repeated strings at load (one-line dictionary); derive flat views lazily; design
  windowed loads for the 500k/iOS target (ship with iOS, not before).
- **IO-noncovering-timeline-index-and-unindexed-sweep — P3 confirmed** — index isn't covering
  (rowid lookback per row ≈2× page touches on cold 500k load); do nothing until 100k+ is real, and
  not before the O(changes) save lands (covering index doubles write cost).
- **architecture-dimensions-persisted-but-never-read — P3 confirmed** — `loadDimensions()` has zero
  production callers; the w/h pipeline (6cfb1b2/7ea3df0) currently buys nothing at runtime. Wire the
  consumer (aspect-correct placeholders before decode) or annotate as forward-only.
- Sync-point note: `load`/`save` serialize behind the **same actor** that serves thumbnails,
  previews, and video streaming — every DB stall above is also a media-pipeline stall. The O(changes)
  save and the coverage-poll fix (§4) remove the two biggest occupants.

Scaling table (store + app passes, current code): 20k ≈ 40–120 ms load / ~100–300 ms changed save /
30–80 ms main-actor passes — fine (matches the green 20k guard). 100k ≈ 0.2–0.6 s / 0.5–1.5 s /
0.2–0.5 s — noticeable stalls. 500k ≈ 1.5–4 s / 2.5–6 s / 1–3 s — unusable without the P1 fixes;
render/texture path itself stays O(viewport) throughout (the engine is scale-free).

---

## 10. iOS / iPadOS risk matrix

| Scenario | Verdict with current code | Blocking findings |
|---|---|---|
| iPhone compact viewport (~390pt) | Column math ready (`compactTimeline` profile ≤640pt: 1/2/3/5/12/20 cols); texture/cache policies exist and are conservative | none for geometry; host missing (below) |
| Dense detents (L4/L5) on any device | **jetsam** — pinned overflow ≈1 GB iPhone / 1.2 GB iPad | memory-pinned-overflow (P0), TEX byte budget, detent-aware pixel size |
| 120 Hz ProMotion scroll | evict sort (1.2–6.9 ms measured) + per-quad encode (~2,000 draws @L5) + upload bursts inside 8.3 ms | CPU-lru-evict (P0), GPU-perquad (P1), upload time-box (P1) |
| Launch/refresh at 100k+ | 0.2 s–3 s main-thread stalls per data arrival; watchdog risk at 500k | CPU-mainactor-library-passes (P1), DB O(changes) save (P1) |
| Initial crawl (large library) | feed actor starved by per-item stat polling; no thermal/LPM adaptation → thermal spiral risk | IO-diskcoverage (P1), platform-thermal-lowpower (P2) |
| Low-memory pressure | no hooks anywhere; NSCaches shed opportunistically, dicts never; viewer path fatal | memory-no-pressure-coordination (P1), viewer cache (P1) |
| Caches purge by OS | thumbnails.enc uncapped in Caches/ → full re-crawl after purge (crawl checkpoint survives) | memory-thumbs-disk-uncapped (P3, decide policy) |
| Stage Manager / foldable resize | macOS live-resize fast path is AppKit-bracket-based; naive UIKit port = full rebase per bounds tick + mid-drag profile switch at 640pt | platform-stagemanager-live-resize-gap (P2): synthesize begin/settle bracket, debounce profile switch |
| Slow network | placeholders persist ~20s+/batch (fine); visible-set retry loop on dead links (battery); viewer preview has no deadline | IO-offline-priority-retry (P2) |
| Any iOS build at all | production timeline host is 100% AppKit (scroll host 1,323 + coordinator 1,847 lines); backend lives in macOS App/ target; iOSApp/ is a demo stub | architecture-ios-timeline-host-gap (**P1 architecture**): extract backend into a package module; build UIKitTimelineScrollHost; the engine/texture/feed cores are verified platform-clean so this is host plumbing, not a rewrite |
| Thermal / Low Power Mode | zero adaptation (grep: 0 hits); crawl concurrency fixed at init | platform-thermal-lowpower-absent (P2): thermal-state → clamp concurrency/backoff; LPM → pause sequential crawl, keep visible priority. AIMD fields are already runtime-mutable |
| SwiftUI shell hygiene | `MainView.init` constructs a new ThumbnailFeed per body re-eval; orphan feeds leak, zoom-transition lookups can silently miss (`MainView.swift:86-107,227,478`) — worse on iOS scene lifecycle | architecture-mainview-feed-recreation (P2 hypothesis — verify identity across a forced re-eval, then move feed ownership to AppModel) |

Core answers platform questions correctly today: budgets are injected shapes, surface classes are
viewport-derived (`UIKitMetalGridTextureSurfaceClass.resolving(viewportSize:)`), and no Core module
branches on platform names. The missing capability inputs are **memory** (`os_proc_available_memory`
/ pressure events), **thermal state**, and **refresh-rate range** — all adapter-supplied numbers/events
feeding existing seams.

---

## 11. Apple-doc-backed recommendations

Every API-specific recommendation above, with its source:

**Metal resources & residency**
- Shared is the default/correct storage for CPU-populated textures on Apple GPUs; private for
  GPU-populated ([Choosing a resource storage mode for Apple GPUs](https://developer.apple.com/documentation/metal/choosing-a-resource-storage-mode-for-apple-gpus)).
- Shared textures populated via `replaceRegion` get lossless bandwidth compression **only** after an
  explicit `optimizeContentsForGPUAccess` blit; avoid `unknown`/`shaderWrite`/`pixelFormatView`
  usage flags ([Optimizing texture data](https://developer.apple.com/documentation/metal/optimizing-texture-data); [WWDC19 606](https://developer.apple.com/videos/play/wwdc2019/606/)).
- `replaceRegion` is a synchronous CPU copy, cannot target private textures — staging-blit is the
  documented private-upload path ([replace(region:...)](https://developer.apple.com/documentation/metal/mtltexture/1515464-replaceregion)).
- Tier-2 argument buffers: Apple6 (A13)+ — every realistic target; Metal 3 bindless needs no argument
  encoder; up to 1M textures per stage from an argument buffer on Apple6+; indirectly-referenced
  resources **must** be declared via `useResource`/`useHeap`
  ([Metal Feature Set Tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf); [WWDC22 Go bindless](https://developer.apple.com/videos/play/wwdc2022/10101/); [Improving CPU performance by using argument buffers](https://developer.apple.com/documentation/metal/improving-cpu-performance-by-using-argument-buffers)).
- `MTLResidencySet`: macOS 15 / iOS 18+, queue-level attachment, ≤32 per queue, low per-resource
  cost ([MTLResidencySet](https://developer.apple.com/documentation/metal/mtlresidencyset); [addResidencySet](https://developer.apple.com/documentation/metal/mtlcommandqueue/addresidencyset(_:))).
- `MTLHeap`: best resource-creation performance; untracked hazards are the developer's problem —
  needs the same in-flight frame boundary discipline as the vertex ring
  ([MTLHeap](https://developer.apple.com/documentation/metal/mtlheap); [WWDC21 Explore bindless rendering](https://developer.apple.com/videos/play/wwdc2021/10286/); [MTLHazardTrackingMode](https://developer.apple.com/documentation/metal/mtlhazardtrackingmode)).
- `texture2d_array`: ≤2048 slices, one pixel format + size for all slices (fits the uniform 320px
  class; costs padding for smaller thumbs) ([arrayLength](https://developer.apple.com/documentation/metal/mtltexturedescriptor/arraylength); [MTLTextureDescriptor](https://developer.apple.com/documentation/metal/mtltexturedescriptor)).
- BGRA8 vs RGBA8: identical capabilities on every Apple family — the current rgba8Unorm thumbnails
  are fine; ASTC is for pre-compressed assets, not runtime photo thumbs
  ([MTLPixelFormat](https://developer.apple.com/documentation/metal/mtlpixelformat); [Feature Set Tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf); [WWDC19 606](https://developer.apple.com/videos/play/wwdc2019/606/)).
- Purgeable resources: `setPurgeableState(.volatile)` keeps idle cached textures **out of the app
  footprint** — Apple explicitly blesses this for resource caches
  ([Reducing the memory footprint of Metal apps](https://developer.apple.com/documentation/metal/reducing-the-memory-footprint-of-metal-apps); [setPurgeableState](https://developer.apple.com/documentation/metal/mtlresource/setpurgeablestate(_:))).

**TBDR & frame pacing**
- Every offscreen pass pays a tile-memory→device-memory round trip; single-pass blending is the
  documented preference; only load/store what you need
  ([Tailor your apps for Apple GPUs and TBDR](https://developer.apple.com/documentation/metal/tailor-your-apps-for-apple-gpus-and-tile-based-deferred-rendering); [WWDC20 10602](https://developer.apple.com/videos/play/wwdc2020/10602/)) — the basis for the dissolve layer-caching fix.
- MTKView's paused + setNeedsDisplay mode is the documented event-driven drawing mode
  ([MTKView](https://developer.apple.com/documentation/metalkit/mtkview)); drawables are scarce —
  acquire late, hold briefly ([Metal Best Practices: Drawables](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/Drawables.html)).
- Triple buffering with a `DispatchSemaphore(3)` signaled from `addCompletedHandler` is Apple's
  canonical pattern — the renderer's ring matches it exactly
  ([Synchronizing CPU and GPU Work](https://developer.apple.com/documentation/metal/synchronizing-cpu-and-gpu-work)).
- `presentsWithTransaction` requires commit → `waitUntilScheduled` → `drawable.present()` and is
  CPU-blocking by design — the code's choice to avoid it during live resize (synchronous `draw()`
  instead) is consistent with the documented cost
  ([CAMetalLayer.presentsWithTransaction](https://developer.apple.com/documentation/quartzcore/cametallayer/presentswithtransaction)).
- macOS 14+: get CADisplayLink from `NSView.displayLink(target:selector:)` (auto-suspends off-screen);
  CVDisplayLink is deprecated in macOS 15 — migrate when convenient
  ([NSView.displayLink](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:)); [CVDisplayLinkStart deprecation](https://developer.apple.com/documentation/corevideo/cvdisplaylinkstart(_:))).
- ProMotion: never assume a rate; use `targetTimestamp`; request `preferredFrameRateRange` you can
  sustain; the range degrades under LPM/thermal automatically
  ([preferredFrameRateRange](https://developer.apple.com/documentation/quartzcore/cadisplaylink/preferredframeraterange); [Optimizing for ProMotion](https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays); [WWDC21 10147](https://developer.apple.com/videos/play/wwdc2021/10147/)).
- Frame-pacing observability: `addPresentedHandler`/`presentedTime` is the sanctioned way to measure
  real presentation jitter ([addPresentedHandler](https://developer.apple.com/documentation/metal/mtldrawable/addpresentedhandler(_:))).

**Memory & pressure**
- `os_proc_available_memory`: iOS-family only (not native macOS), advisory, don't cache
  ([os_proc_available_memory](https://developer.apple.com/documentation/os/os_proc_available_memory)).
- Jetsam limits are officially device-dependent and unpublished; community measurements suggest
  ~50–55% of RAM (≈2 GB on 4 GB devices) — treat as unofficial
  ([Identifying high-memory use with jetsam event reports](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports); [community forums thread](https://developer.apple.com/forums/thread/688973)); macOS enforces no such limit (DTS answer, [forums](https://developer.apple.com/forums/thread/682778)).
- **GPU allocations count against footprint on Apple Silicon** — WWDC22 10106 verbatim; this is why
  the texture byte budget is a jetsam matter, not just a VRAM matter
  ([Profile and optimize your game's memory](https://developer.apple.com/videos/play/wwdc2022/10106/)).
- Dispatch memory-pressure source semantics: reduce **future** cache sizes on elevated pressure (do
  NOT traverse/discard existing caches then); UIKit memory warning semantics: **purge now** — the
  governor must honor both contracts
  ([makeMemoryPressureSource](https://developer.apple.com/documentation/dispatch/dispatchsource/makememorypressuresource(eventmask:queue:)); [dispatch/source.h contract](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/main/dispatch/source.h); [applicationDidReceiveMemoryWarning](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/applicationdidreceivememorywarning(_:))).
- NSCache limits are officially non-strict ("could be evicted instantly, later, or possibly never") —
  never rely on NSCache alone for deterministic bounding
  ([totalCostLimit](https://developer.apple.com/documentation/foundation/nscache/totalcostlimit)).
- Thermal: Apple's per-state mitigations include "reduce target framerate 60→30" and defer
  prefetching at `.fair` — the crawl governor maps directly onto these
  ([ThermalState.serious](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum/serious); [.fair](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum/fair); [.critical](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum/critical)).
- GPU-side observability: `MTLDevice.currentAllocatedSize` (iOS 11+/macOS 10.13+) and
  `recommendedMaxWorkingSetSize` (iOS 16+) ([currentAllocatedSize](https://developer.apple.com/documentation/metal/mtldevice/currentallocatedsize); [recommendedMaxWorkingSetSize](https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize)).

**ImageIO / decode**
- The decode pipeline already implements the canonical WWDC18-219 downsample
  (`CreateThumbnailAtIndex` + MaxPixelSize + ShouldCacheImmediately) — keep it
  ([WWDC18 219](https://developer.apple.com/videos/play/wwdc2018/219/); [kCGImageSourceShouldCacheImmediately](https://developer.apple.com/documentation/imageio/kcgimagesourceshouldcacheimmediately)).
- `FromImageAlways` (not `IfAbsent`) is required to avoid the tiny-EXIF-thumbnail quality trap
  ([kCGImageSourceCreateThumbnailFromImageAlways](https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailfromimagealways); [IfAbsent](https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailfromimageifabsent)).
- The viewer's unbounded decode violates WWDC18-416's core rule (decode memory ∝ pixel dimensions —
  a 2048×1536 photo is ~10 MB decoded) ([WWDC18 416](https://developer.apple.com/videos/play/wwdc2018/416/)).
- Zero-copy upload path if ever needed: IOSurface-backed CVPixelBuffer + `CVMetalTextureCache`
  ([CVMetalTextureCacheCreateTextureFromImage](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)); [IOSurface](https://developer.apple.com/documentation/iosurface)); vImage for controlled-quality SIMD resize ([vImageScale_ARGB8888](https://developer.apple.com/documentation/accelerate/1509266-vimagescale_argb8888)).
- Wide-color: per-pixel color matching "is not for free" — the 8-bit sRGB thumbnail pipeline is the
  right cheap trade ([WWDC16 712](https://developer.apple.com/videos/play/wwdc2016/712/)).

**Concurrency / SQLite / telemetry**
- Main-actor batching ("load all items in one call, update UI once") is exactly the
  library-passes fix; heavy work belongs off-actor; main-actor hops are real context switches
  ([WWDC21 Behind the scenes](https://developer.apple.com/videos/play/wwdc2021/10254/); [WWDC22 Visualize & optimize](https://developer.apple.com/videos/play/wwdc2022/110350/)).
- Note: the renderer's `frameBoundary.wait()` (DispatchSemaphore on the main thread) is the
  documented Metal pattern but technically violates the cooperative-pool "no semaphores in tasks"
  rule only if called from a task context — it runs on the main thread's display-link path, which is
  acceptable; keep it out of any future async refactor
  ([WWDC22 110350](https://developer.apple.com/videos/play/wwdc2022/110350/)).
- WAL + synchronous=NORMAL confirmed as the documented sweet spot; default autocheckpoint is 1000
  pages — the missing `journal_size_limit` explains the WAL high-water finding
  ([SQLite WAL](https://www.sqlite.org/wal.html); [PRAGMA synchronous](https://www.sqlite.org/pragma.html#pragma_synchronous)); mmap I/O errors are signals, not SQLITE_IOERR — the Core-default mmap=0 is correct for iOS ([SQLite mmap](https://www.sqlite.org/mmap.html)).
- iOS may delete Caches/ when very low on space (never while running) — the disk-thumb purge/re-crawl
  scenario is real ([File System Programming Guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html)); `isExcludedFromBackup` for the DB is correctly applied ([isExcludedFromBackup](https://developer.apple.com/documentation/foundation/urlresourcevalues/isexcludedfrombackup)).
- Signposts are designed to be cheap enough to ship; `OSSignposter.disabled`/`isEnabled` gate any
  expensive argument prep ([OSSignposter](https://developer.apple.com/documentation/os/ossignposter); [WWDC18 405](https://developer.apple.com/videos/play/wwdc2018/405/)).
- MetricKit provides production scroll-hitch ratio and peak-memory telemetry (check the v27
  replacement API before adopting) ([MXAnimationMetric](https://developer.apple.com/documentation/metrickit/mxanimationmetric); [MXMetricManager](https://developer.apple.com/documentation/metrickit/mxmetricmanager)).

---

## 12. Ranked optimization backlog

| # | ID | Sev | Conf | Area | One-line fix | Gain | Risk |
|---|---|---|---|---|---|---|---|
| 1 | CPU-lru-evict-fullsort-per-frame | P0 | confirmed (measured) | CPU | O(R) partial selection, no dict-lookup comparator | 11–26 ms/upload-frame (macOS) | low |
| 2 | memory-pinned-overflow-dense-detents | P0 | confirmed | memory | byte budget + pinned-overflow degradation | removes 1–2.2 GB blowup / iOS jetsam | med |
| 3 | CPU-mainthread-upload-redraw | P1 | confirmed | CPU | normalize at decode; time-box uploads | kills multi-frame scroll hitches | low-med |
| 4 | TEX-byte-budget (count→bytes, level-aware px) | P1 | confirmed | memory/GPU | `maxResidentBytes` in GridTextureBudget + byte-aware evict + detent px | ~1 GB steady-state macOS; deterministic iOS | med |
| 5 | IO-gen-stamp-full-table-rewrite-per-sync | P1 | confirmed | DB | O(changes) upsert + anti-join sweep + WAL truncate | sync s→ms; unblocks media actor | med |
| 6 | CPU-mainactor-library-passes | P1 | confirmed | CPU | off-main bundle build, digest equality, marker pass | O(n)→O(1) main-thread per refresh | med |
| 7 | memory-no-pressure-coordination | P1 | confirmed | arch | Core governor + adapter sources | deterministic shedding; iOS prerequisite | low-med |
| 8 | IO-diskcoverage-actor-stall | P1 | confirmed | IO | incremental coverage counter | frees feed actor during crawl | low |
| 9 | memory-viewer-fullres-cache | P1 | confirmed | memory | decode cap + costed cache | bounds 1.9–7.8 GB | low-med |
| 10 | IO-viewer-preview-main-decrypt | P1 | confirmed | IO | detach preview read/decrypt/decode | 5–50 ms/navigation | low |
| 11 | GPU-perquad-draws-overscan-encode (step 1: viewport filter) | P1 | confirmed | GPU | encode viewport-only slots | ~3.4× fewer draws | low |
| 12 | architecture-ios-timeline-host-gap | P1 | confirmed | arch | backend→package module; UIKit scroll host | unblocks the port | med |
| 13 | GPU-dissolve-double-reraster | P2 | confirmed | GPU | cache layers, composite-only frames | dissolve → 1 draw/frame | med |
| 14 | GPU-fixed-320px-no-mips-detent-blind | P2 | confirmed | GPU | level-aware upload size (with #4) | 4–10× bandwidth @L4/L5 | med |
| 15 | CPU-unfetchable-visible-displaylink-busyloop | P2 | likely | CPU | exclude quarantined UIDs from pending | display link idles again | low |
| 16 | CPU-transition-lattice-built-twice | P2 | confirmed | CPU | pass lattice into makePlan; delete dead work | halves begin cost | low |
| 17 | architecture-string-pair-identity-hot-path | P2 | likely | arch | Int-keyed per-frame identity | 0.1–0.4+ ms/frame | med |
| 18 | architecture-all-route-revisit-full-db-reload | P2 | confirmed | arch | cache `.all` snapshot | instant route return | low |
| 19 | memory-full-materialization-and-string-duplication | P2 | confirmed | memory | intern strings; fewer copies | 30–50% metadata RAM | low-med |
| 20 | memory-crawl-bookkeeping-unbounded | P2 | confirmed | memory | bitsets or delete | ~150 MB @500k | low |
| 21 | DB-wal-highwater-no-limit | P2 | likely | DB | journal_size_limit + truncate checkpoint | bounded WAL | low |
| 22 | CPU-video-store-full-tree-walk | P2 | confirmed | CPU | running byte total | no stat storms in playback | low |
| 23 | IO-offline-priority-retry-and-detached-loader-leak | P2 | likely | IO | backoff on priority queue; cap loaders | battery/task-table | low |
| 24 | platform-thermal-lowpower-absent | P2 | confirmed | platform | thermal/LPM → crawl clamps | no thermal spiral | low |
| 25 | architecture-mainview-feed-recreation | P2 | hypothesis | arch | feed owned by AppModel | deterministic identity | low |
| 26 | platform-stagemanager-live-resize-gap | P2 | likely | platform | synthesized resize bracket (port-time) | smooth iPad resize | none now |
| 27–35 | P3 set: dissolve layers retained · texture pool/optimizeContents · vertex direct-write · commit-bridge cache · framePlan reserveCapacity · marquee filter+ranges · double-decrypt · dead byte tier · video cache module split · covering index (later) · digest is-sorted precheck · dims consumer · coalescer batching · GPS off-main · multisection memoization (future guard) | P3 | mixed | — | see §4–§9 | incremental | low |

---

## 13. "Do not do this" list

- **Do not move layout/planning to the GPU.** The control plane is a few hundred rects/frame of
  closed-form math — microseconds. GPU-driven pipelines are for 100k+ objects.
- **Do not touch the settled render shape** (1 CB / 1 encoder / 1 pass, pooled ring, draw-on-demand,
  self-pausing display link). It matches Apple's canonical patterns exactly.
- **Do not cache ResolvedGrid today** (S=1 makes the rebuild ~free; caching adds invalidation state
  for zero gain) — only when multi-section becomes physical.
- **Do not adopt bindless/argument buffers, texture arrays, MTLHeap, or MTLResidencySet before the
  §14 counters prove encode time matters** — and do the one-line viewport filter first; it may make
  the structural change unnecessary on macOS.
- **Do not switch to Core Data/SwiftData/GRDB.** DB v1 is 691 lines, correct, guarded, and
  platform-policy-injected. The O(changes) save is a targeted fix, not a redesign.
- **Do not add ASTC transcoding or texture atlas packing** for photo thumbnails (encode cost, and
  lossless bandwidth compression + right-sized uploads cover the win).
- **Do not add an LRU touch (mtime write) to the disk-thumb scroll read path** — it was deliberately
  avoided; any disk cap needs a decode-time touch strategy instead.
- **Do not build windowed DB loads for macOS now** — design the schema for it (done), ship it with
  the iOS 100k+ target.
- **Do not "fix" the marquee 500k cliff preemptively** — verification showed no autoscroll exists,
  so the cliff is unreachable today; delete the redundant filter only, and revisit if drag-autoscroll
  ships.
- **Do not trust NSCache as a budget** (officially non-strict) — every "budget" that matters must be
  enforced by owned code (the byte-aware residency policy, the governor).
- **Do not enable library evolution or split hot generic code across resilient module boundaries**;
  keep `package` access + WMO so the generic policies specialize.

---

## 14. Required instrumentation before risky work

Current state: good counters exist and are emitted — `lastDrawCalls`/`lastTextureBinds`/`lastDrawMs`
(renderer), `uploadsThisFrame`/`uploadBytesThisFrame`/`uploadMsThisFrame`/`evictionsThisFrame`/
`residentBytes` (texture cache), published via HUD (0.1 s) + `MetalGridPerf` log (0.5 s)
(`MetalGridCoordinator.swift:1801-1845`), plus `ThumbPrefetch`, `PhotoDiagnostics` thumb.* timings,
`GridResizePerf`, and `[DBHealth]`. **Zero `os_signpost` anywhere (grep-verified this audit).**

Before items #1–#5 and any Metal structural work, add (small, shippable, `OSSignposter`-based —
overhead is documented as near-zero when disabled):

1. **Emit the missing residency numbers**: `residentCount`, `pinnedCount`, and a
   `pinned > capacity` **alarm counter** (the exact P0 signature) in the existing MetalGridPerf emit.
2. **Signpost intervals** (one `OSSignposter` in PhotosCore/Diagnostics, categories mirroring the log
   channels): `framePlan`, `buildRealGroups`, `streamTextures.upload` (per-batch, with count+bytes),
   `evictToBudget`, `transition.planBuild`, `dissolve.layerPass`, `db.load`, `db.save`,
   `feed.decode`, `feed.decrypt`, `viewer.decode`. Anchor points are the exact file:lines cited in
   §4–§9.
3. **Per-frame evict duration** (`evictMsThisFrame`) — proves fix #1 and guards regression.
4. **Draw-set split**: draws encoded vs draws in-viewport (proves #11's 3.4× claim at runtime).
5. **Upload time-box telemetry**: carried-over upload count when the ms budget triggers.
6. **Presentation jitter** (optional, macOS HUD): `addPresentedHandler` deltas during pinch — the
   sanctioned measure for the transition-smoothness work this repo keeps doing.
7. **MetricKit subscription** (ship-time, iOS): scroll-hitch ratio + peak memory as the production
   regression net.

---

## 15. Exact suggested implementation order

Each step is independently shippable; tests per step in §16.

1. **Instrumentation pass** (§14 items 1–5). No behavior change.
2. **Evict fix** (#1): O(R) selection in `GridTextureResidencyPolicy.evictToBudget` + drop the
   `subtracting` alloc.
3. **Byte + overflow-aware residency** (#2/#4): `maxResidentBytes` in `GridTextureBudget`;
   `costBytes` at `completeUpload`; byte-aware evict; pinned-overflow degradation (clamp pinning to
   visible); adapter numbers (macOS min(512 MB, 5% RAM); iOS 64/96/192 MB). *Then* level-aware upload
   pixel size (#14) as a follow-up in the same seam.
4. **Upload path** (#3): decode-time RGBA8 normalization + hybrid count/time upload budget.
5. **Unfetchable-visible fix** (#15) — small, on-theme for this branch, restores display-link idle.
6. **DB O(changes) save** (#5) + `journal_size_limit`/truncate checkpoint (#21) + is-sorted precheck.
7. **Main-actor library passes off-main** (#6) + `.all` route snapshot cache (#18) + coverage
   counter (#8).
8. **Memory governor** (#7) + viewer decode cap/costed cache (#9) + preview off-main (#10).
9. **Viewport-filtered draw encoding** (#11 step 1) — then *measure*; only if L5 encode ms still
   matters on target hardware, schedule the bindless/texture-array refactor (#11 step 2) as its own
   evidence-gated project.
10. **Dissolve layer caching** (#13) + dissolve buffer pooling + release layers on commit (P3s).
11. **Identity re-keying to Int** (#17) — after 2–3 so its gains are measurable in isolation.
12. **Port-prep track (parallel, non-render)**: backend extraction to a package module (#12), video
    cache module split, thermal/LPM crawl governor (#24), feed ownership (#25), Stage-Manager resize
    bracket design (#26).
13. **Opportunistic P3 sweep**: lattice single-build (#16), commit-bridge caching, reserveCapacity,
    redundant marquee filter, double-decrypt, dead byte tier, GPS off-main, coalescer batching,
    string interning (#19), bookkeeping bitsets (#20), video store running total (#22).

---

## 16. Tests required for each future implementation task

- **T1 evict fix (#1)**: (a) equivalence — evicted set == k lowest-tick non-pinned for randomized
  states; (b) micro perf guard: evictToBudget at 4096 resident/300 pinned/96 over in <1 ms `-O`
  (expect ≥10×); (c) existing `GridPolicyTests` unchanged.
- **T2 upload path (#3)**: time-budget carry-over preserves priority order; normalized buffer ==
  CGContext output for RGB/gray/CMYK/16-bit fixtures; synthetic 500-tile cold fill asserts
  `uploadMsThisFrame ≤ budget`; `onFirstContentReady` latency unchanged at 20k.
- **T3 residency (#2/#4/#14)**: (a) byte-cap LRU eviction keeps pinned; (b) pinned-overflow
  degradation — pinned cost > cap ⇒ residentBytes ≤ cap and visible set still drawable; (c) **static
  worst-case guard** — iterate `appleLevelSpecs` × viewports {1440×900@2x, 900×1600@2x, 393×852@3x,
  1032×1376@2x}, compute pinned via `framePlan(overscan:)`, assert pinnedBytes ≤ platform cap — this
  test FAILS on current code and becomes the permanent tripwire; (d) level-aware size:
  uploaded pixels ≤ k×(slotSide×scale) per level; (e) scroll-back re-upload counters stay flat once
  warm (L5 soak).
- **T4 unfetchable-visible (#15)**: quarantined visible uid ⇒ `hasPendingVisibleThumbnails == false`
  after one frame, `onFirstContentReady` fires, display link pauses; quarantine clear on crawl
  restart re-enters pending.
- **T5 dissolve (#13)**: pinch-hold L3↔L4 cold-cache — late-arriving thumbnails still appear
  (dirty-hook test); resize mid-dissolve re-rasters; composite parity vs current output on a fixture.
- **T6 DB save (#5)**: extend the 20k micro guard — upsertedRows == changed-row count for +25/−100
  (expect ~125, currently 19,925); generation-sweep semantics preserved; rollback-mid-save; w/h
  survival (existing :511-532); WAL file ≤ journal_size_limit after save+checkpoint.
- **T7 main-actor passes (#6)**: main-actor occupancy <50 ms at 20k for end-to-end loadAll;
  markers/indexMap equality vs synchronous versions; route-switch race tests green; unchanged
  refresh does not reassign state (scroll position preserved).
- **T8 governor (#7/#9)**: fan-out unit test; all cache owners registered (guard); viewer cache cost
  == decoded pixel bytes; 100 MP decode respects cap + orientation.
- **T9 draw filter (#11)**: draw-count regression guard via `lastDrawCalls` on a fixture slot set
  (expect ~÷3.4 at L5); edge-tile visibility during scroll-rebase, transition, and dissolve frames.
- **T10 identity re-key (#17)**: insert/delete/refresh mid-scroll texture-identity correctness;
  streamTextures micro-guard Int vs PhotoUID.
- **T11 backend extraction (#12)**: package builds for iOS destination in CI
  (`verify-universal-core.sh` extension); engine/coordinator pure tests on iOS sim.
- **T12 P3 sweep**: plan byte-equality for lattice single-build; `frame(progress:)` equality for
  bridge caching; single-decrypt-per-fetch counter; coverage counter == directory ground truth.

---

## 17. Manual macOS regression checklist

After each landed step (all on the 20.5k live library, Retina display):

1. Cold launch → veil lifts → first grid frame; no placeholder holes at rest.
2. Fast flick-scroll top↔bottom at L3, cold cache: no hitches (HUD `uploadMs`, `evictMs`,
   `drawCalls` steady); thumbnails fill within a few frames; no wrong-image tiles.
3. Same at L5 (dense): watch `drawCalls` (~÷3.4 after #11), `residentMB` ≤ byte cap, no shimmer
   regression after level-aware sizes.
4. Pinch chains L0↔L5 through multiple detents in one gesture; detent-crossing frames smooth
   (no begin-frame hitch); release-commit snap correct (commit-bridge unchanged).
5. ± zoom clicks at every level; overview dissolve L3↔L4↔L5 hold-and-scrub: layers stay correct as
   thumbnails stream in (after #13), `gpuDrawMs` drops, memory returns after commit (layers freed).
6. Live window resize (corner + edge), sidebar toggle mid-scroll: content pinned to the anchor, one
   settle at end, no black flash. Window resize during dissolve.
7. Marquee selection sweep + ⇧-range + toolbar actions; a11y (VoiceOver) reads visible cells.
8. Viewer: arrow-key rapid navigation 50+ photos — no hitch (preview off-main), footprint plateaus
   (viewer cache costed), deep zoom still sharp enough; Live Photo + video playback start, seek,
   offline replay.
9. Sidebar route bounce All ↔ Favorites ↔ album: instant return to All (after #18), scroll position
   preserved, background refresh still lands.
10. Refresh with no changes (relaunch): `[DBHealth]` shows digest skip, zero upserts. Refresh after
    upload/delete: only changed rows written (after #5).
11. Quarantined "no thumbnail" items visible: display link idles (Activity Monitor GPU ≈ 0% at
    rest), veil lifts (after #15).
12. `sudo memory_pressure -l warn` during scroll (after #7): footprint drops, no crash, thumbnails
    re-fill.
13. Sign-out → sign-in: all caches purged (no orphan files), DB rebuilt, no stale textures.
14. Full suite: `swift test` (508+) green; `verify-universal-core.sh` green.

---

*Audit artifacts: subsystem read + verification transcripts under the session workflow directory;
replica benchmarks were built in the session scratchpad (not committed). Worktree confirmed clean
before and after; the only file created is this report.*
