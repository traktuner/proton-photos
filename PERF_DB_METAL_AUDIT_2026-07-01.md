# Performance + Database Schema + Metal Grid Pipeline Deep Audit — 2026-07-01

Scope: app-owned persistence, SDK store boundaries, and the Metal grid CPU/GPU pipeline, audited
against official Apple/SQLite/Metal guidance for the universal-Core (macOS → iOS/iPadOS) target.
Branch `apple-normal-focusrow-transition`, clean tree at audit start. All 499 package tests green.

Legend: **[C]** confirmed in source (file:line) · **[H]** evidence-backed hypothesis (needs measurement)
· **[R]** recommendation · **[X]** do not touch / do not do now.

---

## 1. Research summary (official sources)

### SQLite / persistence on Apple platforms
- Raw SQLite C API (`libsqlite3`) is public, supported API on macOS/iOS/iPadOS and normal for
  App Store apps (Apple QA1809 discusses raw WAL files; Signal ships GRDB/SQLite on the store).
  Nothing from Apple discourages it. (developer.apple.com/library/archive/qa/qa1809, sqlite.org)
- Apple publishes **no** perf numbers for Core Data/SwiftData at 100k+ rows. Community benchmarks
  consistently rank direct SQLite > Core Data > SwiftData for bulk writes and large ordered scans;
  SwiftData is still maturing as of 2026. Core Data's own Photos.sqlite proves single-file SQLite
  at photo-library scale — but its Z-schema overhead is exactly what we don't need.
- WAL facts (sqlite.org/wal.html): auto-checkpoint ~4MB; checkpoint starvation under overlapping
  readers grows the `-wal` unboundedly; db + `-wal` + `-shm` must be treated as one unit for
  purge/backup (we already do — `SDKMetadataStore.metadataFileNames`).
- `synchronous=NORMAL` + WAL is the documented sweet spot (corruption-safe, last-commit durability
  trade). Default 4096 page size is recommended; page size can't change while in WAL.
- `mmap_size`: I/O errors surface as **signals (SIGBUS), not `SQLITE_IOERR`** (sqlite.org/mmap.html).
  Fine on macOS; on iOS the crash risk + jetsam accounting argue for small/zero mmap → platform policy.
- Directories: `Library/Caches` is **not backed up and may be purged by the OS under storage
  pressure on iOS**; Application Support is the documented home for "files the app needs to run",
  with `isExcludedFromBackup` for server-derivable data. File protection default (Class C /
  CompleteUntilFirstUserAuthentication) is right for background-refresh workloads; Class A breaks
  background DB access (Signal hit this).
- FTS5 is compiled into Apple's system SQLite (iOS 11+; verify at runtime with
  `sqlite_compileoption_used('ENABLE_FTS5')`). Run-time extension loading is **disabled** in the
  system build → sqlite-vec on iOS means statically linking it with a bundled SQLite. Proven
  on-device CLIP pattern (Queryable, Apple MobileCLIP): precompute embeddings, brute-force
  simd/Accelerate scan — <1s for 10k photos on an iPhone 12 mini; fine below ~1M vectors.

### Metal on Apple platforms
- Apple's documented CPU cost center is exactly our pattern: many small draws with per-draw
  `setFragmentTexture`. First-line fixes: instancing, and Tier-2 argument buffers / Metal-3
  bindless (supported on **every** Apple Silicon Mac and A13+ — all realistic targets).
  Indirectly-referenced textures then need `useResource`/`useHeap` (or queue-level
  `MTLResidencySet` on macOS 15/iOS 18+).
- Storage modes on Apple GPUs: "Shared is usually the correct choice" — but shared textures miss
  Apple Silicon's automatic **lossless bandwidth compression** unless
  `optimizeContentsForGPUAccess` runs (or the texture is private via blit). Explicit `usage` flags
  matter (we set them). ASTC/BC transcoding of photo thumbnails is not worth the encode cost
  unless texture memory becomes the binding constraint on iOS.
- TBDR (all Apple GPUs): every offscreen pass costs a full tile-memory store + system-memory
  round-trip. Single-pass rendering with per-instance alpha is the documented preference over
  offscreen-compose — our single-lattice pinch/click transition already matches this; the
  overview dissolve does not (by design, but it should stop re-rasterizing static layers, §6).
- Canonical frame pattern: one command buffer, triple-buffered dynamic data ring with a
  `DispatchSemaphore(3)` signaled from the completion handler, no per-frame `makeBuffer` — the
  steady render path already implements this correctly.
- `MTLIOCommandQueue` (fast resource loading) does **no image decoding** → useless for our
  AES-GCM-encrypted JPEG cache. Background ImageIO decode + budgeted upload is the right pipeline
  (we have it, with one main-thread caveat, §6).
- iOS-specific: jetsam memory caps (budget from `os_proc_available_memory`, not constants),
  `ProcessInfo.thermalState` downshifts, `CADisplayLink.preferredFrameRateRange` for ProMotion,
  draw-on-demand when idle (we already pause the display link).

---

## 2. Current persistence map **[C]**

| Store | Path (`~/Library/Caches/ProtonPhotos/`) | Format | Encrypted | Owner | Purged on sign-out |
|---|---|---|---|---|---|
| Timeline metadata | `sdk/timeline-v3-<uid>.sqlite` (+wal/shm) | SQLite | No | App ([DriveSDKBridge.swift:501](App/Drive/DriveSDKBridge.swift:501)) | Yes (SDKMetadataStore) |
| SDK entity cache | `sdk/entities.sqlite` (+wal/shm) | SQLite | No | **SDK** (path injected at [DriveSDKBridge.swift:84](App/Drive/DriveSDKBridge.swift:84)) | Yes |
| Thumbnails | `thumbnails.enc/` | AES-GCM blobs | Yes (HKDF from session keyPassword, key in Keychain) | App | Yes |
| Previews | `previews.enc/` | AES-GCM blobs | Yes | App | Yes |
| Originals (offline lib) | `originals.enc/` | AES-GCM blobs, LRU cap (default 5GB) | Yes | App | Yes |
| Video blocks | `video-blocks/` | encrypted stream blocks, 512MB budget | Yes (transport form) | App | Yes |
| Locations (GPS) | `locations/locations.v1.enc` | single AES-GCM JSON blob | Yes | App | Yes |
| Account cold-start | `sdk/account-*.enc` | AES-GCM JSON | Yes | App | Yes |
| **Aspect ratios** | `aspects.json` | **plaintext JSON** | **No** | App ([AspectRegistry.swift:20](Packages/ProtonPhotosKit/Sources/MediaCacheCore/AspectRegistry.swift:20)) | **No — gap** |
| Session / cache keys | Keychain (`WhenUnlockedThisDeviceOnly`) | — | System | App | Yes |

Timeline schema ([DriveSDKBridge.swift:513](App/Drive/DriveSDKBridge.swift:513)):
`photos(node TEXT PRIMARY KEY, vol, t REAL, mime, live INTEGER, relvid, tags TEXT '', burst TEXT '')`
+ `idx_photos_t(t ASC)` + `idx_photos_vol_node(vol, node)`. PRAGMAs: WAL, synchronous=NORMAL,
busy_timeout=3000, cache_size=-8192, **mmap_size=256MB**. `tags` = CSV of Int rawValues; `burst` =
newline-joined node IDs.

Access pattern **[C]**: opened once, owned by the `DriveSDKBridge` actor (no main-thread DB work).
`load()` = one full scan `ORDER BY t ASC` (rides `idx_photos_t`, no temp b-tree — guard test
verifies). `save()` = **full replace**: `BEGIN; DELETE FROM photos; INSERT…; COMMIT` on every
timeline refresh ([DriveSDKBridge.swift:576](App/Drive/DriveSDKBridge.swift:576)). Cold start reads
the cached table into a full `[PhotoItem]` array; no windowing. **No DB queries occur during
pinch/scroll/zoom** — the grid works entirely from in-memory arrays, and
`PhotoDiagnostics.recordDBQuery` tags any query that would happen `duringActivePinch`.

---

## 3. Current Metal grid CPU/GPU pipeline map **[C]**

Frame loop: `CADisplayLink` (main thread, `.common`) → `MetalGridScrollHost.step()`; MTKView is
`isPaused=true, enableSetNeedsDisplay=true` (draw-on-demand). Display link **pauses when idle**
(0.25s grace) — quiescent at rest. `MetalGridCoordinator.draw(in:)`
([MetalGridCoordinator.swift:1169](Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridCoordinator.swift:1169))
branches: presentation-resize / sidebar / resize-settle / overview-dissolve / transition /
commit-bridge / settled.

Per frame (settled): 1× `engine.framePlan()` (O(visible) slot query, no full relayout),
`buildRealGroups()` (per visible tile: residency check + `TileContentFitter.fit` pure math +
quad append), texture streaming tick (budgeted), LRU evict, then render. **One command buffer,
one encoder, one pass.** Vertex data goes through a **triple-buffered pooled ring**
(`DispatchSemaphore(3)` + completion-handler signal — the canonical Apple pattern,
[MetalGridRenderer.swift:33](Packages/ProtonPhotosKit/Sources/MetalRenderingCore/MetalGridRenderer.swift:33)).

Draw structure ([MetalGridRenderer.swift:188](Packages/ProtonPhotosKit/Sources/MetalRenderingCore/MetalGridRenderer.swift:188)):
images use `.perQuadTexture` → **one `setFragmentTexture` + one 6-vertex `drawPrimitives` per
visible tile**; decorations batch per type via `.sharedTexture`. No instancing, no argument
buffers, no atlases/arrays/heaps. Vertices are 64B × 6 per quad, non-indexed.

Texture pipeline ([MetalGridTextureCache.swift](Packages/ProtonPhotosKit/Sources/MetalGridTextureCore/MetalGridTextureCache.swift)):
decode off-main (feed layer) → **main-thread** CGContext downsample to ≤320px RGBA8 +
`texture.replace(region:)` upload, budgeted per frame → LRU residency (`GridTextureResidencyPolicy`,
pinned = visible+overscan). Textures are default-storage `shaderRead`; **no
`optimizeContentsForGPUAccess`**. Platform policies are correctly adapter-owned: macOS = 96
uploads/frame, 4096 textures, overscan 1.2 ([AppKitMetalGridTexturePolicy.swift:18](Packages/ProtonPhotosKit/Sources/MetalGridTextureAppKitAdapter/AppKitMetalGridTexturePolicy.swift:18));
UIKit tiers = 24/32/48 uploads, 768/1024/1536 textures.

Transitions: pinch/click build a `GridTransitionPlan` **once per segment** (2× `framePlan` +
component builder + target-set prefetch at detent crossings only); per frame just
`plan.renderIntent(at: q)` → `[GridTransitionDraw]` → same single-pass renderer with per-draw
alpha — **TBDR-optimal, single pass**. `PinchLiveZoomDriver.update()` is O(1) per event; no DB,
no datasource queries in the hot path. Overview dissolve renders source+target settled grids to
two private offscreen textures and composites `mix(A,B,t)` — 3 encoders/frame, and **both layers
are re-rasterized every frame** even though the plans are static
([MetalGridRenderer.swift:244](Packages/ProtonPhotosKit/Sources/MetalRenderingCore/MetalGridRenderer.swift:244));
this path also allocates a fresh `MTLBuffer` per group per frame
([MetalGridRenderer.swift:177](Packages/ProtonPhotosKit/Sources/MetalRenderingCore/MetalGridRenderer.swift:177)).

Core/adapter split: `GridCore` + `MetalRenderingCore` + `MetalGridTextureCore` are
platform-clean (budgets injected); AppKit specifics (display link, NSScrollView, gestures,
`presentsWithTransaction` live-resize sync) live in `TimelineFeature`/App. UIKit seams already
exist. **CPU-based effects vs GPU:** all transition *control* (planning, easing, slot roles) is
CPU; all *pixel* work (SDF corners, blending, dissolve mix) is GPU. That division is correct and
should not move.

---

## 4. Schema risks, ranked **[C unless noted]**

1. **Full-replace save scales linearly and churns WAL.** Every refresh rewrites the whole table.
   ~20k rows ≈ tens of ms (fine); 100k–500k ≈ high-hundreds of ms to seconds **[H]**, plus a WAL
   the size of the table per refresh, on every timeline load — including no-change refreshes.
2. **Unstable ordering: `ORDER BY t ASC` with no tie-breaker.** Equal-`t` rows (same-second
   captures; synthetic burst anchors at +1ms offsets) come back in b-tree/insertion order, which
   the full-replace save reshuffles. Grid identity is index-based → photos can silently swap
   positions between launches.
3. **`node` alone as PRIMARY KEY.** Identity everywhere else is `(vol, node)` (`PhotoUID`). Node
   IDs colliding across volumes would corrupt the row set; the composite index exists but the PK
   is wrong-shaped.
4. **DB lives in `Caches/`** — correct-ish for macOS, **wrong for iOS** where the OS may purge it
   under storage pressure (so may the encrypted thumbnail/originals caches — acceptable for
   caches, not for the "offline library" promise). Also `mmap_size=256MB` inside universal code is
   a desktop assumption (SIGBUS-on-error + jetsam accounting on iOS).
5. **`tags` CSV / `burst` newline-joined TEXT.** Untyped, unqueryable (sidebar filters like
   "videos"/"favorites" require full-scan + decode), and a per-row parse cost on every load.
6. **`aspects.json`:** plaintext, not per-account, not purged on sign-out (leaks node IDs across
   accounts), unbounded growth, and the whole dict is re-encoded + rewritten **on the main actor**
   on every coalesced flush ([AspectRegistry.swift:57](Packages/ProtonPhotosKit/Sources/MediaCacheCore/AspectRegistry.swift:57)).
   These are photo *dimensions* — they belong in the metadata store.
7. **Full-array cold load.** 500k `PhotoItem`s ≈ 100–250MB of Swift string-heavy heap **[H]** —
   fine on a 32GB Mac, jetsam-fatal on a 4GB iPhone. Schema should support windowed loads even if
   macOS keeps loading everything.
8. Ad-hoc migrations (`columnExists` + ALTER TABLE) with no schema version record.
9. Test litter: 2,182 files (`tests-aspects-*`, `yield-*`, `burst-filmstrip-*`) written into the
   **real** user cache dir because test namespaces still resolve to the production directory.
10. Query-plan guard test schema drift — **fixed in this audit** (test now mirrors production
    columns exactly; suite green).

Sensitivity classification is otherwise sound: secrets in Keychain, GPS + bytes AES-GCM-encrypted
with per-account HKDF keys, plaintext confined to non-secret metadata (IDs, times, MIME). The
separation of encrypted byte caches from metadata **must stay**.

---

## 5. Recommended target architecture (DB) **[R]**

**Keep raw SQLite via the C API.** Measured fit: ordered scans + bulk writes + tiny per-row
decode is SQLite's home turf; Core Data/SwiftData add object-graph overhead we'd fight at 500k
rows; the store is ~130 lines today. GRDB is the fallback if feature tables multiply past ~4–5
and migrations/typed rows start hurting — it's proven (Signal), but adopting it now fails the
"clear value over migration cost" bar. **Do not** move to SwiftData for this workload.

**Clean v1 app-owned schema reset — yes, warranted** (no production users; current schema fails
risks 1–3 structurally). One DB per account, **feature-owned tables**, explicit versioning:

```sql
-- Application Support/ProtonPhotos/<uid>/library-v1.sqlite  (backup-excluded; re-derivable)
PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;          -- mmap/cache_size: platform-injected
CREATE TABLE schema_info(feature TEXT PRIMARY KEY, version INTEGER NOT NULL);

CREATE TABLE photos(              -- hot path: ONLY what the timeline needs
  vol TEXT NOT NULL, node TEXT NOT NULL,
  t REAL NOT NULL,
  mime TEXT NOT NULL DEFAULT 'image/jpeg',
  live INTEGER NOT NULL DEFAULT 0, relvid TEXT,
  w INTEGER, h INTEGER,           -- learned dimensions (replaces aspects.json)
  dur REAL,                       -- video duration when known
  gen INTEGER NOT NULL DEFAULT 0, -- refresh generation (incremental delete sweep)
  PRIMARY KEY (vol, node));
CREATE INDEX idx_photos_timeline ON photos(t, vol, node);    -- stable total order

CREATE TABLE photo_tags(vol TEXT NOT NULL, node TEXT NOT NULL, tag INTEGER NOT NULL,
  PRIMARY KEY (tag, vol, node));                             -- sidebar filters = index range scan
CREATE TABLE burst_members(anchor_vol TEXT NOT NULL, anchor_node TEXT NOT NULL,
  member_node TEXT NOT NULL, seq INTEGER NOT NULL,
  PRIMARY KEY (anchor_vol, anchor_node, seq));
-- future, each guarded by its own schema_info row, absent until the feature is enabled:
-- albums / album_members ; favorites-as-tag or table ; video_meta ; hashes
```

Rules that make this future-proof without promising "no migrations":
- **Timeline order is `(t, vol, node)` everywhere** — DB index, in-memory comparator, grid
  identity. Deterministic across replaces, devices, platforms.
- **Hot path touches only `photos`.** Feature tables (albums, ML, search) are joined only inside
  their feature module; a disabled feature costs zero on the timeline scan.
- **Separate DBs for heavy features:** `embeddings-v1.sqlite` (or per-model blob files) for
  CLIP/LLM vectors — BLOB rows scanned brute-force via Accelerate/simd; add statically-linked
  sqlite-vec only if >~1M vectors ever materialize. `search-v1.sqlite` for FTS5 (system build has
  it). Keeps the timeline DB small, keeps WAL churn isolated, lets features be deleted wholesale.
- **Location stays in its own encrypted store** (privacy class differs from plaintext metadata);
  same for all byte caches. Album *names* are E2EE — ciphertext or nothing in the DB.
- **Save becomes incremental:** upsert changed rows, bump `gen`, `DELETE WHERE gen < current`
  after a full enumeration; and short-circuit entirely when the refresh is a no-op (digest
  compare). Full-replace remains acceptable as the v1 fallback if implementation time is scarce —
  but the no-op short-circuit should land regardless.
- **Platform policy injection** for PRAGMAs (mmap 256MB macOS / 0–32MB iOS, cache_size) — same
  code, adapter-supplied numbers, mirroring `GridTextureBudget`.
- SDK-owned `entities.sqlite` stays untouched behind its path-injection boundary; never redesign
  it from the app side.

---

## 6. Render/performance risks + Metal recommendations, ranked

### Confirmed-good (leave alone)
- Single command buffer/encoder/pass; pooled triple-buffered vertices; draw-on-demand +
  display-link pause; budgeted, pinned, LRU texture streaming; transitions planned once per
  segment and rendered single-pass with per-draw alpha; zero DB work in hot paths; clean
  Core/adapter split with platform-injected budgets. This architecture is already right-shaped
  for iOS — the *control plane belongs on the CPU* at this scale (a few hundred rects/frame is
  microseconds; GPU-driven pipelines are for 100k+ objects) **[X: do not move layout/planning to GPU]**.

### No-risk cleanup
1. **Emit the counters that already exist.** `renderer.lastDrawCalls/lastInstanceCount/lastDrawMs`
   and `uploadsThisFrame/uploadBytesThisFrame/uploadMsThisFrame` are tracked but not surfaced in
   `[GridZoomPerf]`/`[ThumbHealth]`. Add: draws/frame, binds/frame, transition draw count, plan-build
   ms vs group-build ms, dissolve pass ms, upload count/bytes during pinch, cache hit/miss split.
   Every optimization below is gated on these numbers.
2. **Test directory seam.** Route `AspectRegistry`/`ThumbnailCache` roots through an injectable
   base URL; tests use scratch dirs. Kills the 2,182-file litter in the real user cache.
3. One-off: delete existing `tests-*`/`yield-*`/`burst-filmstrip-*` litter (propose, not executed).

### Low-risk batching/cache improvements
4. **Stop re-rasterizing static dissolve layers.** Overview dissolve: render layerA/layerB once at
   `beginOverviewDissolve`, re-render a layer only when one of its wanted textures uploads
   (invalidation hook already implicit in `uploadsThisFrame > 0`); per frame becomes composite-only.
   Cuts 2 full offscreen passes/frame → the single biggest bandwidth win, and TBDR-critical for iOS.
5. **Move the CGContext downsample off the main thread.** `makeTexture(from:)` resamples on the
   render thread (up to 96×/frame worst case on macOS policy). Have the feed deliver pre-sized
   CGImages (it already decodes off-main); keep only `makeTexture` + `replaceRegion` on main.
6. **`optimizeContentsForGPUAccess`** (one blit after upload, or switch thumbnails to private via
   blit) to get Apple Silicon lossless bandwidth compression on sampled thumbnails.
7. **Pool the dissolve path's vertex buffers** — it bypasses the ring and calls `makeBuffer` per
   group per frame ([MetalGridRenderer.swift:177](Packages/ProtonPhotosKit/Sources/MetalRenderingCore/MetalGridRenderer.swift:177)).

### Medium-risk render refactor (evidence-gated: do only if counters show encoder time matters)
8. **Collapse per-quad draws.** Two safe paths:
   - **Path A (preferred): Tier-2 argument buffer / bindless** — write texture ResourceIDs into a
     per-frame buffer, one instanced draw for all image quads, `useResource`/`useHeap` (or
     `MTLResidencySet` on macOS 15/iOS 18+). Keeps individual textures + LRU exactly as today.
   - **Path B: `texture2d_array`** — fixed 320×320 slices, upload into subregions, UV-window via
     the existing `TileContentFitter` output; instance index selects slice. Simpler shader story,
     costs padding memory and a slot allocator.
   Either path folds in indexed/instanced vertices (384B/quad → ~64B/instance). On an M-series Mac
   ~300 draws/frame is likely fine **[H]**; on iPhone the encoder overhead argues for Path A before
   iOS ships.
9. **Heap-allocate thumbnail textures** (`MTLHeap`) to cut allocator churn under scroll — only
   meaningful alongside 8.

### Future larger redesign **[X for now]**
- Metal 4 command allocators / residency-set-first binding; GPU-driven culling/ICBs; ASTC
  transcoding of the thumbnail cache; texture atlas packing; `MTLIOCommandQueue` (does no image
  decode — useless for encrypted JPEGs); offline `.metal` compilation is a nicety (runtime
  `makeLibrary(source:)` costs one-time init ms, acceptable in SPM).

### iOS/iPadOS-specific (adapter policy work, pre-port)
- Texture + RAM budgets derived from `os_proc_available_memory`, not constants; thermal-state
  downshift for prefetch/frame-rate; `preferredFrameRateRange` (ProMotion pinch at 120, idle low);
  keep `presentsWithTransaction` AppKit-only (already is); uncapped `thumbnails.enc` (827MB
  observed here) needs an iOS cap policy.

---

## 7. DB/storage performance recommendations, ranked

- **No-risk:** keep the query-plan guard in exact sync (done); add save-skip digest (no-op
  refreshes stop rewriting 20k rows + WAL); emit `[DBHealth]` save/load ms at INFO throttle
  (exists); add `PRAGMA optimize` on close.
- **Low-risk:** move `aspects.json` → `w/h` columns (fixes risks 4+6 together); add
  `(t, vol, node)` index + tie-broken ORDER BY (can be done on the *current* schema without the
  v1 reset, if reset is deferred).
- **Medium (the v1 reset, §5):** composite PK, normalized tags/bursts, Application Support move,
  platform PRAGMA policy, incremental upsert with `gen` sweep, schema_info versioning. One-time
  cost: new store + delete-old-file migration (users: none). Wire purge lists to the new paths.
- **Future:** windowed timeline loads (LIMIT/OFFSET by `t` anchor) for iOS memory ceilings;
  embeddings/search side-DBs when those features land.

---

## 8. Tests & benchmarks to add

Tests: (a) ordering stability — equal-`t` rows keep identical order across save/load cycles;
(b) save-skip digest correctness; (c) purge coverage asserts **every** app-owned file (incl.
aspects/dimension data) is enumerated — a "no orphan stores" test that walks the cache root after
simulated sign-out; (d) query-plan guards for any new feature-table query; (e) residency-policy
invariants under budget shrink (memory-pressure simulation); (f) renderer draw-count regression
test via `lastDrawCalls` against a fixture slot set.

Benchmarks (XCTest `measure` or swift-testing + signposts): timeline save/load at 20k/100k/500k
synthetic rows; `framePlan` + `buildRealGroups` at max visible density; upload-path ms per
texture; dissolve frame ms before/after layer caching.

Manual (macOS app): pinch L0↔L5 chains, overview dissolve, live window resize, fast scroll on a
cold cache — verify `[GridZoomPerf]`/HUD numbers and zero `dbQueryCountDuringActivePinch`.
Later on iOS/iPadOS: same scenarios on lowest-supported hardware + memory-pressure simulation
(`os_proc_available_memory` headroom), thermal soak, ProMotion pinch smoothness, and Caches-purge
recovery (delete caches while suspended → relaunch must rebuild gracefully).

## 9. Do-not-implement-yet list
Bindless/argument-buffer refactor (needs counters first) · MTLHeap · Metal 4 API adoption ·
ASTC/atlas work · GRDB migration · vector-search extension bundling · album-write crypto ·
any SDK-store redesign · windowed loading on macOS (design schema for it, ship it with iOS).

## 10. Changes made during this audit
- [AppInfrastructureTests.swift:210](Packages/ProtonPhotosKit/Tests/TimelineFeatureTests/AppInfrastructureTests.swift:210)
  — query-plan guard now mirrors the production schema (`tags`/`burst` columns, 8-column SELECT).
  Focused test + full suite (499 tests / 73 suites) green. No production code touched.
