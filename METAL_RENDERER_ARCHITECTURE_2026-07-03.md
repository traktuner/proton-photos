# Metal Renderer Architecture Decision — Proton Photos — 2026-07-03

Scope: the next renderer architecture step after the 2026-07-02 performance wave, for a Metal 3-only,
macOS/iOS/iPadOS-universal renderer. Branch `codex/thumbnail-prefetch-failure-fix`, clean tree.
Baseline at audit start: **609 tests / 82 suites green** (`xcrun swift test --package-path
Packages/ProtonPhotosKit`). Read-only run — this report is the only file written.

Evidence used, in order: (1) current source (every claim re-verified against the working tree, not the
old report), (2) runtime `MetalGridPerf` captures from the 2026-07-02 owner-run measurement sessions,
(3) official Apple documentation re-fetched this session (§7), (4) the source audit
`PERF_CORE_RENDERER_DEEP_AUDIT_2026-07-02.md`, (5) clearly-labeled inferences.

Governing constraint (owner addendum, 2026-07-03): **no platform-specific Core or renderer forks.**
One Core bug fix fixes all platforms; platform code adapts only presentation, resources, and OS
integration. Allowed: injected budgets/signals, viewport-derived surface classes, host adapters.
Forbidden: `#if os(...)` behavioral branches in Core, per-platform renderer algorithms, any fix that
leaves iOS structurally weaker than macOS. Every option below was evaluated against this rule first.

---

## 1. Current-state verification

### 1.1 Audit findings that are FIXED in current code (verified in source, not from the report)

| Audit finding | Commit | Where verified |
|---|---|---|
| P0 LRU evict full-sort per frame | `829f21b9` | [GridTextureResidencyPolicy.swift:139-213](Packages/ProtonPhotosKit/Sources/GridCore/GridTextureResidencyPolicy.swift:139) — heap-based partial selection of the k lowest ticks, no full sort, no `subtracting` allocation; O(1) under-budget fast path |
| P0 pinned overflow / unbounded residency | `c2fb6b70` | Structural admission: [GridTextureResidencyPolicy.swift:85-90](Packages/ProtonPhotosKit/Sources/GridCore/GridTextureResidencyPolicy.swift:85) (`canAdmitUpload` enforces the pinned byte floor); pin clamping: `maxSafePinnedCount` [MetalGridTextureCache.swift:97-100](Packages/ProtonPhotosKit/Sources/MetalGridTextureCore/MetalGridTextureCache.swift:97) fed into `GridTextureStreamingPolicy.window(maxPinned:)` at [MetalGridCoordinator.swift:1906-1910](Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridCoordinator.swift:1906) |
| P1 count-only texture budget | `c2fb6b70` | `GridTextureBudget.maxResidentBytes`; macOS **512 MiB** / count 16,384 ([AppKitMetalGridTexturePolicy.swift](Packages/ProtonPhotosKit/Sources/MetalGridTextureAppKitAdapter/AppKitMetalGridTexturePolicy.swift)); iOS **64/96/192 MiB** by surface class ([UIKitMetalGridTexturePolicy.swift](Packages/ProtonPhotosKit/Sources/MetalGridTextureUIKitAdapter/UIKitMetalGridTexturePolicy.swift)) |
| P2 fixed 320 px detent-blind uploads | `742bea4e`, `bbfa0a54` | [GridTextureUploadSizing.swift](Packages/ProtonPhotosKit/Sources/GridCore/GridTextureUploadSizing.swift) (slotSide×scale×headroom, clamped `[floor, cap]`), `setEffectiveMaxTexturePixels` per frame at [MetalGridCoordinator.swift:1901](Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridCoordinator.swift:1901), in-place soft→sharp upgrades [MetalGridTextureCache.swift:233-266](Packages/ProtonPhotosKit/Sources/MetalGridTextureCore/MetalGridTextureCache.swift:233) |
| P1 unbudgeted main-thread uploads | `c2fb6b70`, `abf8f00a` | Hybrid count+byte+measured-ms upload budget with carry-over ([MetalGridTextureCache.swift:177-220](Packages/ProtonPhotosKit/Sources/MetalGridTextureCore/MetalGridTextureCache.swift:177); macOS 48 / 6 MiB / 6.0 ms; iOS 16-32 / 2-4 MiB / 2.5-4.5 ms); direct-upload fast path skips CGContext normalization via GPU sampler swizzle ([CGImageDirectUpload.swift](Packages/ProtonPhotosKit/Sources/MetalGridTextureCore/CGImageDirectUpload.swift), `makeTextureDirect` :338-351) |
| P1 no memory-pressure coordination | `89458dcf`, `7e99fc40` | Core [MemoryPressureGovernor.swift](Packages/ProtonPhotosKit/Sources/PhotosCore/MemoryPressureGovernor.swift) (pressure+thermal+LPM → tier → budgetScale), texture-cache responder `setResidencyPressureScale` → `evictToReducedBudget` keeps visible pinned set |
| P1 per-quad draws over the full 3.4×-viewport band | `7b5d8a33` | `viewportDrawSlots` filter [MetalGridCoordinator.swift:1761-1763](Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridCoordinator.swift:1761); overscan band still feeds streaming/pinning only (:1737-1740) |
| P2 dissolve double re-raster + retained layers | `e5d6cdb2` | [DissolveLayerCache.swift](Packages/ProtonPhotosKit/Sources/MetalRenderingCore/DissolveLayerCache.swift) — steady scrub re-runs NEITHER offscreen pass nor its `buildRealGroups` (group closures lazily evaluated, [MetalGridRenderer.swift:272-312](Packages/ProtonPhotosKit/Sources/MetalRenderingCore/MetalGridRenderer.swift:272)); `endLayerDissolve` releases both layers on commit (:239-243) |
| P1 DB full-table rewrite per sync | `bd872fce` | O(changes) upsert with NULL-safe `IS NOT excluded` guards, temp-table anti-join sweep, `journal_size_limit` + `wal_checkpoint(TRUNCATE)` ([TimelineMetadataStore.swift:399-550](Packages/ProtonPhotosKit/Sources/PhotosCore/TimelineMetadataStore.swift:399)) |
| P2 lattice built twice per gesture begin | (fixed) | [GridTransitionController.swift:35-75](Packages/ProtonPhotosKit/Sources/GridCore/GridTransitionController.swift:35) — lattice built once, passed into the scheduler; dead `relocatingIdentities` work gone |
| §14 instrumentation gap (zero signposts) | `fd06a28b` | `PhotoPerformanceSignposts` (OSSignposter, subsystem `me.protonphotos`, categories Database/Grid/MediaFeed/Viewer); intervals `buildRealGroups`, `streamTextures.upload`, `streamTextures.upgrade`, `evictToBudget` live in the coordinator |
| Feed NSString-key alloc per lookup | `0ebc3de6` | Decoded RAM tier is a PhotoUID-keyed, byte-costed LRU (`DecodedThumbnailCache`); no per-lookup key alloc |
| Data-flow P3s | `0da5796d`, `e57952f8` | One-pass month markers; PhotoUID-keyed disk-presence cache |

The `MetalGridPerf` emit (0.5 s cadence, [MetalGridCoordinator.swift:2016-2049](Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridCoordinator.swift:2016))
now carries everything §14 of the audit asked for: `drawCalls`, `textureBinds`, `instances`,
`gpuDrawMs`, `uploads/uploadBytes/uploadMs/deferredUploads`, `evictions/evictMs`,
`residentTextures/pinnedTextures/pinnedOverflow`, `residentMB/residentBudgetMB/byteBudgetOverflow`,
`residencySaturated`, `encodedSlots` (band) vs `drawCalls` (viewport-filtered) — the draw-set split —
plus `directUploads/normalizedUploads/upgrades/effectivePixels`.

### 1.2 Renderer findings that REMAIN open

1. **Per-quad texture binding.** The settled path still does one `setFragmentTexture` + one 6-vertex
   `drawPrimitives` per resident visible tile ([MetalGridRenderer.swift:196-203](Packages/ProtonPhotosKit/Sources/MetalRenderingCore/MetalGridRenderer.swift:196)).
   `drawCalls == textureBinds == resident visible tiles`. Whether this still matters is §3/§4.
2. **Per-frame `[Vertex]` array churn.** Each group builds a fresh Swift array, then memcpy's it into
   the pooled ring (:146-169). ~600-1,700 quads × 384 B at L5 = 0.2-0.65 MB of transient alloc+copy
   per invalidated frame. The ring itself (`4c4dc63f`) is sound and Apple-canonical.
3. **Per-group `makeBuffer` on dissolve re-raster frames** (:184, `pooledSlot=nil` path). Post-
   `e5d6cdb2` this runs only on layer-dirty frames (upload arrived / resize), no longer every frame —
   demoted to cosmetic.
4. **No texture pool / heap / purgeable state / `optimizeContentsForGPUAccess` / mips** (repo-wide
   grep: zero hits). Every upload allocates a fresh `MTLTexture`
   ([MetalGridTextureCache.swift:378-385](Packages/ProtonPhotosKit/Sources/MetalGridTextureCore/MetalGridTextureCache.swift:378));
   every eviction frees one. Allocation cost is *inside* the measured, capped `uploadMs` — see §4.
5. **PhotoUID (2×String) per-frame identity residual.** The NSString alloc is gone (`0ebc3de6`); the
   remaining Set/Dict hashing is ~1.1-1.3 ms/frame at L5 (2026-07-02 microbench-derived estimate).
   Int re-keying stays REJECTED (wrong-thumbnail risk; see `identity-hotpath-measured` decision).
6. **`gpuDrawMs` is not GPU time.** It is CPU wall time across `render()` (vertex build + encode +
   commit) — the right metric for the encode question, mislabeled. True GPU time is not captured
   anywhere (no `gpuStartTime/gpuEndTime`).
7. **The frame loop exists twice — the finding the owner addendum makes load-bearing.**
   The AppKit path composes frames in `MetalGridCoordinator` (~2,050 lines, AppKit-locked via
   MTKView/NSClipView/NSColor): window build → pin clamp → upload/upgrade → warm → evict → group
   build → stats. The iOS scaffold ([UIKitTimelineGridHost.swift](Packages/ProtonPhotosKit/Sources/TimelineUIKitFeature/UIKitTimelineGridHost.swift),
   322 lines, `63d1f4a0`) **re-implements a minimal copy of the same loop** (framePlan :207,
   uploadVisible :232, evictToBudget :238, its own group build :275-277). Today a bug fixed in the
   coordinator's streaming logic is NOT fixed on iOS. This violates "any implementation that requires
   fixing the same Core bug more than once" and is the actual structural debt of the renderer — not
   the binding model.

Core hygiene baseline: the only platform conditional in any universal Core module is a
`#if canImport(CoreGraphics)` availability guard in CGImageDirectUpload.swift — no behavioral forks.
`scripts/verify-universal-core.sh` builds every Core + Metal target for both destinations and runs
`CoreArchitectureGateTests`.

---

## 2. The key architecture question, answered with evidence

**Do we still need a structural renderer refactor (bindless/argument buffers) after viewport-only
draws? — No, not now. The evidence puts the per-quad path comfortably under budget on macOS, and the
honest answer for iOS/iPadOS is "unmeasured, projected tight-but-viable" — which is a measurement
task, not a refactor trigger.**

- **L5 drawCalls/textureBinds after viewport filtering** (closed-form from the engine spec, L5 = 30
  fixed columns, pitch = layoutWidth/30; draws = resident visible tiles only, placeholders draw
  nothing): ~**630** for a 1440×900 window, ~**545** fullscreen 2560×1440, worst case ~**1,710** for
  a tall-narrow 900×1600 window. Before `7b5d8a33` the encoder paid the full 3.4×-viewport band
  (~2,100-5,800). `encodedSlots` vs `drawCalls` in `MetalGridPerf` proves the split at runtime.
- **Measured CPU encode cost**: the 2026-07-02 owner capture recorded the *worst case in the app* —
  overview dissolve at **3,751 draws = 2.91 ms** `gpuDrawMs` (CPU-side, and that frame included two
  offscreen layer passes with per-group `makeBuffer`). Upper bound ≈ **0.78 µs/draw**. Settled L5
  therefore costs ≈ **0.4-1.3 ms** encode on this M-series Mac — ≤8% of a 16.7 ms frame, ≤16% of an
  8.3 ms one. L3 (~180 draws) is noise.
- **Upload and residency behavior**: `uploadMs` is budget-capped and was measured pegged at ~**6 ms**
  during pinch storms with `deferredUploads` absorbing the excess — the deliberate, dominant
  per-frame cost. `residentMB` peaked ~**427** under the 512 MiB cap, `residencySaturated=false`,
  `byteBudgetOverflow=false` throughout. Memory is bounded by construction now (structural admission),
  not by luck.
- **Is per-quad binding above budget on target hardware?** macOS: **no** (numbers above). iOS/iPadOS:
  **no device measurement exists**. Inference (labeled as such): A-series ≈2× the per-draw CPU cost →
  iPad-expanded L5 portrait (~1,230 visible tiles) ≈ 1.9-2.6 ms encode inside an 8.3 ms ProMotion
  budget that also carries a 4.5 ms upload cap — tight but not structurally broken, and the *same*
  numbers argue the fix is thinner uploads/fewer pins (already adapter policy), not a new binding
  model.
- **Would bindless/argument buffers provide a visible win now?** It would cut 0.4-1.3 ms (macOS) of
  encode to ~0.1 ms and collapse `textureBinds` to ~a handful. Nothing user-visible depends on that
  today; the frame budget is spent elsewhere (uploads, by design). It becomes a real win only at the
  iOS thresholds in §5.

This lands exactly on the run's stop condition: *"current viewport-filtered per-quad path is already
below budget and bindless would be complexity-only"* — so this document specifies the bindless design
and its go/no-go gates, and does **not** green-light its implementation.

What the evidence *does* justify now: (a) the universal frame-composer extraction (§1.2 item 7 —
mandated by the addendum, and the precondition for ever measuring iOS honestly), (b) closing the
vertex-churn remnant, (c) true-GPU-time telemetry so the next decision is made on split CPU/GPU
numbers instead of one blended figure.

---

## 3. Measurement plan

All macOS captures use the Debug build (`scripts/rebuild.sh` installs Debug to
`/Applications/ProtonPhotos.app`; `PhotoDiagnostics.emit` prints only in DEBUG).

**Capture commands**

```bash
# 1. Stdout counters (0.5 s cadence):
/Applications/ProtonPhotos.app/Contents/MacOS/ProtonPhotos 2>&1 | tee /tmp/gridperf.log
grep '\[MetalGridPerf\]' /tmp/gridperf.log            # per-frame-window counters
grep '\[FirstContent\]'  /tmp/gridperf.log            # cold-start latency
# 2. Signpost intervals (buildRealGroups / streamTextures.upload / evictToBudget):
xcrun xctrace record --template 'Metal System Trace' \
  --launch /Applications/ProtonPhotos.app --output /tmp/grid.trace
#    → Instruments: os_signpost track, subsystem me.protonphotos, category Grid.
# 3. Governor behavior under pressure:
sudo memory_pressure -l warn        # while scrolling; watch residentMB + evictions
# 4. Footprint ground truth:
footprint ProtonPhotos
```

**Counters to record per scenario** (from `MetalGridPerf`): `drawCalls`, `textureBinds`,
`encodedSlots`, `gpuDrawMs` (CPU encode until S1 renames/splits it), `uploads`, `uploadMs`,
`deferredUploads`, `directUploads` vs `normalizedUploads`, `evictions`, `evictMs`, `residentMB`,
`pinnedTextures`, `pinnedOverflow`, `residencySaturated`, `byteBudgetOverflow`, `effectivePixels`,
`level`, `phase`.

**Scenarios** (all on the ~20.5k live library, Retina):

| # | Scenario | Watch for | Current expectation |
|---|---|---|---|
| 1 | L3 fast flick-scroll, warm cache | drawCalls ~180, gpuDrawMs ≪1 ms, evictMs ~0 | steady |
| 2 | L5 fast flick-scroll, warm + cold | drawCalls 550-1,700 by window shape; uploadMs ≤6; deferred>0 during cold is CORRECT | encode ≤1.3 ms |
| 3 | Pinch chain L0↔L5 multi-detent | detent-crossing frame spikes; uploadMs cap respected | no >16.7 ms frame |
| 4 | ± zoom clicks each level | begin-frame cost (lattice single-build) | smooth |
| 5 | Overview dissolve hold + scrub L3↔L4↔L5 | drawCalls collapses to ~1 on steady scrub (layer cache); re-raster only on upload arrival | verified by e5d6cdb2 tests |
| 6 | Sidebar toggle + live window resize mid-scroll | presentation path; one settle; no black flash | unchanged |
| 7 | Cold cache fill (sign-out/in or purge) | uploadMs pegged at budget, frame pacing held, FirstContent ready time | ~100 ms first content |
| 8 | `memory_pressure -l warn` during 2 | residentMB drops to scaled ceiling; visible tiles never evicted | governor path |

**iOS/iPadOS (the measurement that actually gates §5):** after Slice 2 lands, the same `MetalGridPerf`
print runs inside the iOS host (it is Core code). Run the `ProtonPhotosMobile` shell on a physical
A-series/M-series iPad at 120 Hz, repeat scenarios 1-3 + 7, and record the same fields. No new
infrastructure is needed — that is the point of the extraction.

**S1 adds** (before any structural decision): true GPU time per command buffer
(`gpuEndTime - gpuStartTime` in the completed handler → `lastGpuMs`, emitted as `gpuMs`) so encode
(CPU) and execution (GPU) stop sharing one number.

---

## 4. Decision matrix

Candidates evaluated under the addendum rule (single algorithm, capability-gated, no platform forks).

| Criterion | A. Per-quad + local churn fixes | B. Metal 3 argument-buffer bindless | C. `texture2d_array` | D. MTLHeap / texture pool |
|---|---|---|---|---|
| CPU encode @L5 | 0.4-1.3 ms today; churn fixes shave ~0.1-0.4 ms + allocator pressure | ~0.1-0.3 ms (1-6 draws); useResource cost moved out of frame via MTLResidencySet (queue-level, macOS 15/iOS 18 — inside the OS 26 floor) | ~0.1-0.3 ms (few draws) | unchanged (targets alloc, not encode) |
| GPU | unchanged (2.91 ms at 3,751 draws proves GPU is not the constraint) | neutral-to-slightly-better | neutral | neutral |
| Memory | bounded (512 MiB / 64-192 MiB caps, admission-enforced) | + one small resource-ID buffer | **worse**: uniform slice size forces square padding (~25-33% waste on aspect thumbs); 2,048-slice ceiling vs 16,384 count cap → multiple arrays | neutral-to-better (aliasing) but adds fragmentation management |
| Fit with landed level-aware sizing / in-place upgrades | perfect (is the current design) | perfect — individual textures keep heterogeneous sizes | **conflicts head-on**: slices share one W×H/format; per-level size change and soft→sharp grow force whole-slice/array reallocation | orthogonal |
| iOS/iPadOS | works today; projected 1.9-2.6 ms encode worst case (inference, unmeasured) | Tier-2 argument buffers guaranteed on 100% of the fleet (OS 26 floor ⇒ A13+/Apple6+; direct `gpuResourceID` encoding needs only iOS 16/macOS 13) | supported, but the memory penalty hits iOS hardest | supported; hazard discipline on us |
| Complexity / regression risk | minimal / minimal | medium: shader change, per-quad texture index, residency-set bookkeeping on upload/evict, wrong-index = wrong thumbnail; needs pixel-parity proof | medium-high AND structurally regressive here | medium: untracked-heap aliasing hazards need the same 3-frame discipline as the vertex ring |
| Fallback | n/a (is the fallback) | REQUIRED and cheap: keep `.perQuadTexture` path; runtime `device.argumentBuffersSupport == .tier2` gate (a capability query, not a platform fork — addendum-compliant) | same gating, but why | n/a |
| Evidence it is needed now | — | **none on macOS; none yet on iOS** (unmeasured) | none, and negative fit | **none**: `makeTexture` cost lives inside the measured, capped `uploadMs ≤ 6 ms`; no allocation churn signal exists |

**C is rejected** outright: the 2026-07-02 wave deliberately made textures variable-sized
(level-aware, aspect-preserving, upgradable in place); a texture array un-does that to save binds
that measurably cost ~1 ms. **D is deferred, evidence-gated**: if signpost data ever shows
`makeTexture` as a distinct cost inside `uploadMs`, the first response is a dimensions-keyed recycle
pool (simple, no hazard surface), with `MTLHeap` only as part of a later bindless+heap package
(`useHeap` then covers residency of read-only heap resources in one call — doc-verified §7).

---

## 5. Recommendation

**Primary path: Option A + the universal frame composer.** Keep the per-quad renderer as the
production binding model. Spend the structural effort where the addendum demands it: extract the
frame-composition loop into universal Core so macOS and iOS render through literally the same code,
then close the two measured local inefficiencies (vertex churn, blended timing metric). Slices in §6.

**Fallback / next structural step (specified, gated, not scheduled): Option B — Metal 3 bindless.**
Design sketch so the gate can be pulled without re-research:
- One `MTLBuffer` table of texture `gpuResourceID`s (Tier-2 direct encoding — no argument encoder;
  doc-verified §7), rebuilt incrementally by the texture cache on upload/evict, slot index reused via
  a free-list so the table does not compact per frame.
- Per-quad `textureIndex` joins the existing `Vertex` payload; the image group becomes ONE
  `drawPrimitives` (or a handful, batched by pipeline state); MSL fragment indexes
  `array<texture2d<float>>` from the argument buffer.
- Residency: one `MTLResidencySet` attached to the command queue, `addAllocation`/`removeAllocation`
  on upload/evict, `commit()` once per mutation batch — zero per-frame `useResource` traffic
  (macOS 15/iOS 18+, inside the OS 26 floor). Per-encoder `useResources(_:usage:.read)` batch call
  retained as the correctness fallback.
- Gate: `device.argumentBuffersSupport == .tier2` at renderer init — a capability query on all
  platforms, satisfied by the entire OS 26 device fleet; the per-quad path remains compiled-in and is
  the automatic fallback. No `#if os`, identical algorithm everywhere. Addendum-compliant.
- Parity proof before flip: offscreen-render both paths against a fixture slot set and byte-compare;
  drawCalls/instances counters asserted; the flag ships default-OFF for one release.

**Do NOT implement the structural refactor while** (all true):
- sustained settled L5 fast-scroll encode (`drawMs` CPU, post-S1 split) ≤ **2.0 ms** on the slowest
  supported device, and
- `textureBinds` ≤ ~2,000/frame in real windows, and
- frame misses correlate with `uploadMs`/decode (policy-tunable) rather than encode.

**Implement bindless when** (any one, measured on device, post-S2/S3):
- iOS/iPadOS settled L5 scroll shows encode > **~2 ms sustained** (>25% of the 8.3 ms ProMotion
  budget), or
- macOS shows encode > **~4 ms sustained** in a supported window shape, or
- product direction densifies the grid past ~3,000 viewport draws (e.g. a >30-column level or
  multi-window dense surfaces).

---

## 6. Implementation slices (each independently shippable, commit after each)

**S1 — Timing split + true GPU time.** `MTLCommandBuffer.gpuStartTime/gpuEndTime` captured in the
completed handler → `lastGpuMs`; rename the existing blended metric internally to encode time; emit
both (`drawMs` CPU-encode, `gpuMs` GPU) in stats/HUD/`MetalGridPerf`.
*Files*: `MetalRenderingCore/MetalGridRenderer.swift`, `TimelineFeature/MetalGridTypes.swift`,
`TimelineFeature/MetalGridCoordinator.swift`, `TimelineUIKitFeature/UIKitTimelineGridHost.swift`.
*Tests*: stats-plumbing unit test (fields present, non-negative, gpuMs=0 before first completion).
*Manual*: HUD shows both numbers; L5 scroll capture shows encode ≈ prior `gpuDrawMs`, gpuMs ≪ encode.

**S2 — Universal frame composer (the addendum-mandated step).** New Core module (working name
`MetalGridComposeCore`, depends on GridCore + MetalGridTextureCore + MetalRenderingCore; zero
AppKit/UIKit) owning the settled-frame sequence currently duplicated: streaming window build + pin
clamp + effective-pixel sizing + upload/upgrade/warm orchestration + `buildRealGroups` (decorations
included; accent color, display mode, selection/favorite/video predicates injected as data) +
viewport draw filtering + evict + per-frame stats assembly. `MetalGridCoordinator` delegates to it
(macOS behavior byte-identical); `UIKitTimelineGridHost` deletes its private mini-loop and adopts it.
Two sub-commits: (a) extract + macOS delegation, (b) iOS adoption.
*Files*: new module + `Package.swift`; `MetalGridCoordinator.swift` (delegation),
`UIKitTimelineGridHost.swift` (adoption), `scripts/verify-universal-core.sh` (add the module).
*Tests*: group-parity fixture (old builder vs composer, identical groups/quads/order for a synthetic
slot set incl. selection/favorites/video badges); streaming-window parity; existing 609 stay green;
core-gate builds for both destinations.
*Manual*: full §8 checklist on macOS; iOS sim/device smoke — grid renders, scrolls, fills.

**S3 — Vertex direct-write.** Compute per-group byte offsets from quad counts up front (counts are
known before building), write `Vertex` structs straight into the pooled ring buffer's contents
pointer, drop the intermediate `[Vertex]` arrays; keep a reused scratch array only for group
metadata. Dissolve layer passes keep transient buffers (they run only on dirty frames now).
*Files*: `MetalRenderingCore/MetalGridRenderer.swift`.
*Tests*: draw-parity fixture (drawCalls/instances/textureBinds identical pre/post on a mixed group
set); existing renderer/production-grid tests.
*Manual*: scroll L3/L5, pinch chain, dissolve scrub — visual parity, encode ms flat-or-better.

**S4 (gated by §5 thresholds — do not start without a measured trigger + owner ask).** Bindless per
the §5 design. *Files*: `MetalGridRenderer.swift` (+shader), `MetalGridTextureCache.swift`
(resource-ID table + residency-set maintenance), flag plumbing. *Tests*: pixel-parity offscreen
compare, draw-count guards, upload/evict residency-set consistency test.

**S5 (research notes only, evidence-gated, unscheduled).** (a) Dimensions-keyed texture recycle pool
if signposts ever isolate `makeTexture` cost; (b) `setPurgeableState(.volatile)` on evicted-but-kept
textures — doc-verified to remove them from the app's accounted footprint (§7), interesting for iOS
scroll-reversal warmth, but interacts with the governor and needs the query-and-handle-`.empty`
protocol; (c) `optimizeContentsForGPUAccess` post-upload blit for lossless bandwidth compression —
usage flags already qualify (`shaderRead` only), but the win is unmeasured and costs a blit per
upload. None of these change the architecture; all fit behind existing seams.

---

## 7. Apple-doc verification (re-fetched this session, official sources only)

| Claim the design relies on | Verdict | Source |
|---|---|---|
| Tier-2 argument buffers: mutable, pointer-indexed in MSL, dynamic indexing; **direct encoding without `MTLArgumentEncoder`** by writing `gpuAddress`/`gpuResourceID` on iOS 16+/macOS 13+ | CONFIRMED | [Improving CPU performance by using argument buffers](https://developer.apple.com/documentation/metal/improving-cpu-performance-by-using-argument-buffers) |
| Indirectly referenced resources must be made resident: `useResource`/`useResources` per encoder ("call before encoding draw calls that may access the elements through an argument buffer"; typical for bindless); `useHeap` covers read-only heap-backed resources in one call, writable still need `useResource` | CONFIRMED | [useResources(_:usage:stages:)](https://developer.apple.com/documentation/metal/mtlrendercommandencoder/useresources(_:usage:stages:)), same article |
| `MTLResidencySet`: macOS 15 / iOS 18+; attaches to a command queue (auto-attached to every committed command buffer); lower overhead than encoder residency methods | CONFIRMED (within the project's OS 26 floor — NOT Metal 4) | [MTLResidencySet](https://developer.apple.com/documentation/metal/mtlresidencyset) |
| `replace(region:…)`: synchronous CPU copy; cannot target `.private`; performs **no GPU synchronization** — caller must ensure no in-flight GPU access | CONFIRMED — current design complies structurally (every upload/upgrade fills a *fresh* texture the GPU has never seen, then swaps the reference) | [replace(region:…)](https://developer.apple.com/documentation/metal/mtltexture/replace(region:mipmaplevel:withbytes:bytesperrow:)) |
| Apple-GPU storage modes: `.shared` is the documented default/correct mode for CPU-populated, GPU-sampled textures; `.private` for GPU-populated; `.memoryless` for transient render targets | CONFIRMED — current thumbnail textures (.shared) and dissolve layers (.private render targets) both match | [Choosing a resource storage mode for Apple GPUs](https://developer.apple.com/documentation/metal/choosing-a-resource-storage-mode-for-apple-gpus) |
| `setPurgeableState(.volatile)`: OS may discard; **volatile resources do not count toward the app memory limit** — sanctioned idle-resource-cache pattern | CONFIRMED | [Reducing the memory footprint of Metal apps](https://developer.apple.com/documentation/metal/reducing-the-memory-footprint-of-metal-apps) |
| `optimizeContentsForGPUAccess`: blit that enables optimal GPU access/lossless compression for CPU-populated textures; blocked by `unknown`/`shaderWrite`/`pixelFormatView` usage | CONFIRMED (thumb textures qualify: `.shaderRead`) | [Optimizing texture data](https://developer.apple.com/documentation/metal/optimizing-texture-data) |
| `texture2d_array`: `arrayLength` 1…**2048**; slices share one size/format by construction | CONFIRMED — the basis for rejecting Option C | [MTLTextureDescriptor.arrayLength](https://developer.apple.com/documentation/metal/mtltexturedescriptor/arraylength) |
| `MTLHeap`: suballocation + aliasing control; developer owns hazard discipline for untracked heaps | CONFIRMED (heap-type details deferred until D is ever triggered) | [MTLHeap](https://developer.apple.com/documentation/metal/mtlheap) |
| GPU allocations count against app footprint / jetsam on Apple Silicon; iOS terminates over-limit apps | CONFIRMED (footprint doc; WWDC22 10106 per prior audit) | same footprint doc + [WWDC22 10106](https://developer.apple.com/videos/play/wwdc2022/10106/) |

Not re-fetched this session (verified with links in the 2026-07-02 audit §11, unchanged and not
load-bearing for this decision): TBDR offscreen-pass cost (already acted on via `e5d6cdb2`), MTKView
paused/`enableSetNeedsDisplay` event-driven mode (already the shipped configuration), ProMotion
`preferredFrameRateRange`/`targetTimestamp` guidance (host-adapter concern, dt already wall-clock).
**No Metal 4-only API appears anywhere in this design.**

---

## 8. Acceptance criteria (every slice)

1. `DEVELOPER_DIR=/Applications/Xcode.app xcrun swift test --package-path Packages/ProtonPhotosKit`
   — full suite green (609+ at baseline; parity/plumbing tests added per slice).
2. `scripts/verify-universal-core.sh` green (S2 adds the new module to its matrix).
3. `scripts/rebuild.sh` builds, installs, launches the single canonical app.
4. No new AppKit/UIKit imports in universal Core (core-gate test + grep; baseline: only the
   CoreGraphics availability guard).
5. Runtime `MetalGridPerf` before/after capture per §3 scenarios: `drawCalls`, encode ms, `uploadMs`,
   `evictMs`, `residentMB` all flat-or-better; `pinnedOverflow=false`, `byteBudgetOverflow=false`,
   `residencySaturated=false` in scenarios 1-7.
6. Memory bounded under L5 dense grid: `residentMB` ≤ `residentBudgetMB` (512 macOS / 64-192 iOS);
   scenario 8 shows governor shedding without evicting visible tiles.
7. Visual parity: scroll (L3/L5), pinch chains, ± zoom at every level, overview dissolve
   hold/scrub/commit, sidebar/window resize, viewer open + navigation, video + Live Photo playback —
   per the audit §17 checklist.

## 9. Stop-condition assessment for this run

Condition 1 of the run's stop list is met: the viewport-filtered per-quad path is **below budget on
macOS today**, so implementing bindless now would be complexity-only. Accordingly this run delivers
architecture only. S1-S3 are ready to implement on owner approval; S4 stays behind the §5 measured
thresholds; no design here requires Metal 4 APIs or platform-specific Core branches, and every
proposed path keeps the existing per-quad renderer as a working fallback until parity is proven.

---

*Verification inputs: direct source reads of MetalGridRenderer / MetalGridTextureCache /
GridTextureResidencyPolicy / MetalGridCoordinator / UIKitTimelineGridHost + a repo-wide landed-fix
sweep; runtime numbers from the 2026-07-02 owner-run captures (dissolve draw-call and identity
measurement sessions); Apple docs re-fetched 2026-07-03 via the developer.apple.com JSON endpoints.
Tree clean before and after; this report is the only file written.*
