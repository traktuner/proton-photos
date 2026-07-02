# Core Performance Run — DB O(changes) Save + Memory-Pressure Governor — 2026-07-02

Branch `codex/thumbnail-prefetch-failure-fix`. Driven by `PERF_CORE_RENDERER_DEEP_AUDIT_2026-07-02.md`.
Baseline at start: **551 tests / 76 suites green**, clean tree.

## Executive summary

Most of the audit's P0/P1 backlog was **already fixed in prior commits on this branch** (LRU
full-sort, byte-aware residency, level-aware upload sizing, upload time-boxing, WAL cap, crawl
coverage counter, viewer cache bound, viewer preview off-main, video full-tree-walk removal,
viewport-only draw encoding, transition lattice reuse, hot-path buffer reserve, generalized overview
render bounds). This run confirmed that from the code/tests and then delivered the **two highest-value
still-open structural items**, each fully tested and build-verified:

1. **Package 1 — Timeline DB save is now O(changes)** (`bd872fce`).
2. **Package 2 — Core memory-pressure / thermal governor + adapter wiring** (`89458dcf`, `7e99fc40`).

Package 3 (grid-transition genericity) was found **already satisfied and comprehensively tested**;
Package 4 (Int identity re-key) is a **stop-and-report** (regression risk); Package 5 was mostly
already-fixed or investigation-gated. Details and rationale below.

---

## What changed

### Package 1 — DB + refresh pipeline (`bd872fce`)

`TimelineMetadataStore.save` previously rewrote **every** row on any changed refresh: each row was
upserted with a bumped per-row `gen`, then `DELETE … WHERE gen < current` swept vanished rows. The
repo's own 20k guard recorded the cost: a `+25 / −100` refresh performed **19,925 upserts** and spiked
the WAL. The write amplification was O(library) per single-photo change.

New save is **O(changes)**:
- **NULL-safe conditional upsert** — `INSERT … ON CONFLICT(vol,node) DO UPDATE SET … WHERE t IS NOT
  excluded.t OR mime IS NOT … OR …`. Only rows whose persisted content actually differs are written;
  `upsertedRows` now accumulates `sqlite3_changes` (0 for an unchanged survivor, 1 for an insert or a
  real update). `w`/`h` are never referenced, so learned dimensions still survive a refresh.
- **Key-based anti-join sweep** — every incoming `(vol,node)` key is recorded in a connection-scoped
  `TEMP` scratch table (`WITHOUT ROWID` PK, so it lives in SQLite's temp store, off the durable WAL);
  the sweep is `DELETE FROM photos WHERE NOT EXISTS (SELECT 1 FROM save_incoming_keys …)`. This
  replaces the generation sweep, so the now-dead per-row `gen` column was **removed from the schema**.
- **O(n) is-sorted precheck** skips a redundant `O(n log n)` resort when the enumeration is already in
  canonical order (the common case — the bridge pre-sorts by the same comparator).

Only production caller is `DriveSDKBridge`, which uses the save result for **diagnostics logging
only** (verified) — no behavior change for callers. `load()` never exposed `gen`.

### Package 2 — Memory / thermal / low-power governor (`89458dcf` core, `7e99fc40` wiring)

There was **zero** memory-pressure/thermal/low-power handling anywhere (grep: 0 hits). Every cache had
an independent static budget and the non-NSCache stores (GPU texture dict) never shrank — a hard
prerequisite for the iOS/iPadOS port, where a single memory warning precedes jetsam within seconds.

**Core mechanism (PhotosCore, platform-pure):**
- `MemoryConditions` (adapter-fed `pressure` / `thermal` / `lowPowerMode`) — Core never reads
  `ProcessInfo` / `DispatchSource`; adapters push values, exactly like `GridTextureBudget` /
  `LibraryDatabasePolicy` inject platform numbers.
- `MemoryBudgetTier` (`normal` / `reduced` / `minimal`, with `budgetScale` and `requiresImmediatePurge`).
- `MemoryBudgetPolicy.tier(for:)` — the single, pure `(pressure, thermal) → tier` decision. Follows
  the documented split: **dispatch-source elevated pressure → reduce future budgets**, **critical /
  UIKit warning → purge now**. `.fair` thermal and Low Power Mode intentionally **do not** shrink
  caches (that would add re-decode work — the wrong response for battery / heat).
- `MemoryPressureGovernor` — register responders; `update(conditions)` resolves the tier and fans out
  **only on a real change**. Mirrors `NetworkMonitor`'s shape (`@MainActor`, `.shared` + injectable).

**Deterministic shrink/purge primitives on each owner** (decoupled — no governor-type import; the app
maps `tier → primitive`, so the dependency-light GridCore/MetalGridTextureCore stay PhotosCore-free):
- `GridTextureResidencyPolicy.evictToReducedBudget(maxCount:maxCost:)` — sheds offscreen LRU to a
  reduced ceiling, **never below the pinned visible set** (stays drawable), clamped so it can only
  shrink. `evictToBudget()` now delegates to the same extracted core, so its behavior is byte-identical.
- `MetalGridTextureCache.setResidencyPressureScale` — scales the per-frame evict ceiling; scale `1.0`
  keeps the original eviction path exactly.
- `ThumbnailFeedCore` / `ThumbnailCache` / `PhotoViewerModel` / `ThumbnailFeed` —
  `nonisolated applyMemoryPressure(scale:purge:)` lowering the NSCache cost limit / dropping now
  (thread-safe NSCache, so the governor never hops those actors).

**AppKit adapter + wiring (`7e99fc40`):**
- `App/AppMemoryPressureCoordinator` — a `DispatchSource` memory-pressure source (`[.normal, .warning,
  .critical]`) + a `ProcessInfo.thermalStateDidChangeNotification` observer feed the governor.
  Registers the app-lifetime responders (static viewer cache, byte-tier singleton) and the live feed
  (idempotent by identity, so SwiftUI re-creating `MainView` never double-registers a stale feed).
  Installed once from `AppModel.prepareBackend`.
- `MetalGridCoordinator` self-registers its GPU texture cache via an **injected** `MemoryPressureGovernor?`
  (`nil` in tests; `.shared` from the production-only scroll host). Injection was required: reaching the
  `@MainActor` shared singleton from concurrent swift-testing coordinator inits crashed (SIGSEGV);
  passing `nil` in tests and wiring on the real main actor in production is correct and safe.

---

## Audit findings addressed / still open

| Audit ID | Sev | Status this run |
|---|---|---|
| `IO-gen-stamp-full-table-rewrite-per-sync` (#5) | P1 | **FIXED** — conditional upsert + anti-join sweep (`bd872fce`) |
| `CPU-digest-resort-of-presorted-input` (P3) | P3 | **FIXED** — is-sorted precheck (`bd872fce`) |
| `memory-no-pressure-coordination` (#7) | P1 | **FIXED** — governor + adapter + responders (`89458dcf`/`7e99fc40`) |
| `memory-viewer-fullres-cache` (#9) | P1 | Bound already landed (`ec8e181e`); **now also governed** (shrink/purge) |
| TEX residency runtime shrink (part of #2/#4) | P1 | **ADDED** — `evictToReducedBudget` + `setResidencyPressureScale` (governed) |
| `CPU-mainactor-library-passes` (#6) | P1 | **OPEN** — deferred (concurrency restructuring; medium risk, needs runtime race validation) |
| `architecture-all-route-revisit-full-db-reload` (#18) | P2 | **OPEN** — deferred (route-switch race + scroll-preservation risk) |
| `memory-full-materialization-and-string-duplication` (#19) | P2 | **OPEN** — deferred (audit says ship with iOS 500k target; premature now) |
| `GPU-dissolve-double-reraster` / dissolve layer release (#13) | P2/P3 | **OPEN** — deferred (GPU-lifetime risk; current behavior is correct, see Package 3) |
| `architecture-string-pair-identity-hot-path` (#17) | P2 | **STOP-AND-REPORT** — see Package 4 |
| covering index (P3) | P3 | **NOT DONE** — audit explicitly says not before iOS 100k+ and not with the O(changes) save |

---

## Package 3 — grid transition / dissolve genericity (already satisfied)

A dedicated read-only investigation confirmed the Package-3 **requirements are already met** by prior
commits (notably `9f6b4fb6` "Generalize overview grid render bounds" and `6630d98e` "Reuse transition
lattice"), with comprehensive tests:
- Source/target layouts carry explicit render bounds (`GridRenderBounds`, per-level via
  `isOverviewBoundary()` — **no hardcoded L3/L4 / 9→7** anywhere in transition/dissolve code).
- `q=0` == settled source and `q=1` == first settled target are pinned by
  `GridTransitionScheduleTests.renderIntentEndpointsExact` and
  `OverviewLayerDissolveTests.layerOpacityEndpointsAndComplementarity`.
- `+/-` and pinch share one `GridTransitionComponentBuilder` (differ only in scheduling windows).
- Profile-agnostic; `OverviewLayerDissolveTests` covers **regular and compact** profiles and
  sidebar-inset changes for every overview boundary in both directions.
- Cold-cache dissolve shows late-arriving thumbnails today (layers re-raster each frame + `streamTextures`).

The only remaining item is the **optional** perf work under "Also investigate" — dissolve layer
caching / composite-only frames / releasing the retained layer textures. I **deferred** it: the current
re-raster-every-frame path is *correct* and is exactly what guarantees late thumbnails appear; layer
caching trades that guarantee for a dirty-hook and frees two live `MTLTexture`s (a GPU-lifetime hazard
against in-flight command buffers). Under the no-regression mandate the risk outweighs the ~33 MB /
bandwidth reward without runtime validation. No genericity change was needed or made.

## Package 4 — hot-path Int identity re-key — STOP AND REPORT

Not attempted. The audit rates it P2/**likely** with **medium** regression risk and the explicit
failure mode "stale indices would draw **wrong thumbnails**"; it is gated on Packages 1–3 being
low-risk. It requires an index↔UID map that invalidates atomically with every data generation across
the whole per-frame streaming path — an invasive change whose correctness can only be proven with
runtime mid-scroll insert/delete testing. Per the task's stop conditions ("If this becomes invasive,
stop and report"), this is deferred as its own evidence-gated project.

## Package 5 — P3 cleanup sweep

- **is-sorted precheck** — done (folded into `bd872fce`).
- **`GridRenderBounds.translate` reserveCapacity** — **not needed**: it uses `Array.map`, which already
  pre-sizes the result to the source count. The audit note is moot.
- **double-decrypt probe-then-read**, **video full-tree-walk**, **coalescer batching**, **commit-bridge
  cache** — investigation found these **already fixed** (video walk in `99dbac5b`; coalescer already
  uses a lock-guarded pending dict) or **not worth the coupling risk** (double-decrypt only on the
  cache-miss path; bridge cache saves ~20% of a 160 ms window). Skipped with rationale.
- **dead plaintext byte tier** — investigation showed it is **not dead** (live via `ThumbnailCache.data`),
  so the audit's "delete it" is unsafe. Skipped.
- **GPS off-main** — low value (one-time sign-in decrypt), adds a Map async gap; skipped.

---

## Performance impact

- **I/O (biggest win):** changed DB saves drop from O(library) to O(changes) durable writes. The 20k
  guard's `+25 / −100` refresh went from **19,925 upserts → 25** (+100 swept), and the WAL no longer
  spikes on single-photo changes. At 500k this turns multi-second, multi-hundred-MB-WAL saves that
  block the whole media-pipeline actor into millisecond, few-row writes. Flash wear ∝ changes, not
  library size.
- **CPU:** the is-sorted precheck removes a full resort of the (already-ordered) enumeration on every
  production save. On the render thread there is **no change at the normal tier** — `evictToBudget()`
  delegates to a byte-identical path and `setResidencyPressureScale(1.0)` is a no-op.
  Measured DB micro-guard (M-series, 20k synthetic): initial save ≈ 338 ms, changed save ≈ 359 ms — at
  20k the wall-clock is dominated by the (inherent) canonical sort + SHA-256 digest, so it is roughly
  flat; the win is in **durable writes / WAL / actor-hold**, which scale, not in 20k wall-clock.
- **Memory:** under real system pressure the governor now deterministically sheds the RAM caches
  (viewer full-image up to 512 MB, decoded thumbnails, byte-tier, NSImage wrappers) and offscreen GPU
  textures **within one main-actor turn of a warning**, keeping visible tiles drawable — versus the
  previous "NSCache opportunism, dicts never shrink, viewer path fatal". This is the iOS jetsam-survival
  prerequisite.
- **Storage:** DB WAL is smaller and bounded on changed saves (fewer dirty pages per change; the WAL
  cap from `6a2cda63` still truncates large saves). Removing the `gen` column marginally shrinks each
  `photos` row. No new persistent caches were added.

## Regression risk

- **DB save (low–medium):** semantics are pinned by the extended guard suite (see below), including
  change-detection, NULL-safe value→NULL transitions, anti-join sweep, dimensions survival, WAL bound,
  and query-plan. The digest short-circuit and ordering tests are unchanged and green.
- **Governor core (low):** additive; fan-out only fires on a tier change and is unit-tested. At the
  normal tier every owner path is unchanged.
- **Governor wiring (low):** compile-verified for macOS (app build) and iOS (universal-core gate);
  responders act only under pressure; the texture-cache registration is `nil` in tests (crash-safe) and
  main-actor-only in production. Runtime pressure behavior is the one thing unit tests can't cover — see
  the manual checklist.

---

## Exact tests run

- `xcrun swift test --package-path Packages/ProtonPhotosKit` — **553 tests / 76 suites pass** (was 551;
  +8 new: 6 governor + 2 reduced-budget eviction). New/changed DB tests: `…SaveLoadSkipAndChangedUpsertGuard`
  (asserts `upsertedRows == 25`), `testOnlyRowsWithChangedContentAreRewrittenNullSafe` (new),
  `testAntiJoinSweepRemovesRowsMissingFromLatestRefresh` (asserts unchanged survivors not rewritten).
- `./scripts/verify-universal-core.sh` — Core + shared-UI + Metal-Core + platform-adapter proof gate
  for **iOS and macOS** (passed after the governor core, and re-run after the full change set).
- macOS app compile (`xcodebuild … -destination generic/platform=macOS`, no signing) — **BUILD SUCCEEDED**.

Not run: `./scripts/rebuild.sh` in full (it also installs to `/Applications` and launches). Compile
was validated via `xcodebuild build`; the runtime steps are the manual checklist below.

## Exact commits created

- `bd872fce` — Make timeline DB save O(changes)
- `89458dcf` — Add Core memory-pressure governor + cache-owner shrink primitives
- `7e99fc40` — Wire memory-pressure governor into the macOS app

(Commits `21afa2dd` / `d410f0f0` between them are **NOT mine** — a concurrent process committed unrelated
Drive-API security hardening + a README during this session. Left untouched, as required.)

## What the user should manually test

Run `./scripts/rebuild.sh` on the live 20.5k library, then:
1. Launch → veil lifts → first grid frame; no placeholder holes at rest.
2. Fast flick-scroll L0/L3/L5 top↔bottom cold-cache: no hitches, no wrong-image tiles (HUD `evictMs`,
   `uploadMs`, `drawCalls` steady).
3. Pinch chains L0↔L5; `+/-` at every level; overview dissolve L3↔L4↔L5 hold-and-scrub — layers stay
   correct as thumbnails stream in.
4. Collapse/expand sidebar mid-scroll; live window resize (corner + edge). One settle at end, no black flash.
5. Open viewer, arrow-navigate 50+ photos; play a video; open a Live Photo; navigate old timeline regions.
6. **Refresh skip:** relaunch → `[DBHealth]` should show the digest skip (zero upserts). Then upload or
   delete one item and refresh → the log should show **only the changed/deleted rows** written (not ~20k).
7. **Memory pressure (the new behavior):** with the app scrolling, run `sudo memory_pressure -l warn`
   (and `-l critical`), or Xcode Debug ▸ Simulate Memory Warning. Expect footprint to drop and scrolling
   to continue without a crash; visible tiles stay drawn and re-fill. `[MetalGridPerf]` `residentMB`
   should fall under pressure and recover after. Repeat while the viewer is open and while a video plays.
8. Sign-out → sign-in: all caches purged, DB rebuilt, no stale textures.

---

## Apple / SQLite documentation consulted

- DispatchSource memory-pressure semantics (elevated → *reduce future* cache sizes, not discard):
  <https://developer.apple.com/documentation/dispatch/dispatchsource/makememorypressuresource(eventmask:queue:)>
- UIKit memory-warning contract (purge now) — `applicationDidReceiveMemoryWarning`:
  <https://developer.apple.com/documentation/uikit/uiapplicationdelegate/applicationdidreceivememorywarning(_:)>
- `NSCache` limits are officially non-strict — never a hard budget:
  <https://developer.apple.com/documentation/foundation/nscache/totalcostlimit>
- GPU allocations count against footprint on Apple Silicon (why the texture cache is a jetsam matter),
  WWDC22 10106: <https://developer.apple.com/videos/play/wwdc2022/10106/>
- `ProcessInfo.thermalState` per-state mitigations (defer prefetch at `.fair`, shed at `.serious`):
  <https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum>
- `os_proc_available_memory` is iOS-family only (why memory observation lives in adapters):
  <https://developer.apple.com/documentation/os/os_proc_available_memory>
- SQLite WAL + `synchronous=NORMAL` + `journal_size_limit` (bounded WAL after checkpoint):
  <https://www.sqlite.org/wal.html>, <https://www.sqlite.org/pragma.html#pragma_synchronous>
- SQLite UPSERT / `ON CONFLICT DO UPDATE … WHERE` (the conditional-write idiom the save relies on):
  <https://www.sqlite.org/lang_UPSERT.html>
- Main-actor batching guidance (deliver one immutable bundle, update UI once), WWDC21 10254:
  <https://developer.apple.com/videos/play/wwdc2021/10254/>

## Intentionally skipped (and why)

- **Package 4 (Int identity re-key)** — medium wrong-image regression risk, invasive, gated; stop-and-report.
- **Main-actor library passes / `.all` snapshot / string interning** — medium risk (route races,
  concurrency) or premature (audit: ship the materialization work with the iOS 500k target); deferred to
  keep this pass regression-free.
- **Dissolve layer caching / release** — GPU-lifetime risk for a small reward; current behavior is correct.
- **Video-cache governor wiring** — the disk tier is not a RAM-pressure contributor; its small decrypted
  RAM tier is best wired once the video cache moves behind a Core policy (audit `architecture-video-cache-app-layer`).
- **Covering index, windowed DB loads** — audit explicitly says not before the iOS 100k+ target.
