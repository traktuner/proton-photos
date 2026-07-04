# iOS/iPadOS Memory & Cache Budget Audit

**Date:** 2026-07-03  ·  **Branch:** `claude/ios-polish-perf-pass`  ·  **Scope:** read-only architecture audit (no production code changed)
**Method:** direct source reads of the named files + a 12‑agent parallel deep‑read sweep, cross‑checked by two adversarial verifiers (budget recompute + pressure‑response matrix). All numbers below were read from source; file:line citations throughout.

---

## 1. Executive summary — is the 4 GB budget safe or too aggressive?

**The budget *numbers* are only mildly too aggressive on 4 GB. The real problem is that the memory‑pressure machinery is dead on iOS.** Core owns a correct, tested `MemoryPressureGovernor`, and the two biggest hot caches (decoded thumbnails, GPU textures) expose pressure hooks — but **no iOS adapter ever drives the governor, and the iOS grid caches never register with it.** So on iOS the budgets are *static ceilings that only ever grow to their maximum and never shrink*, even under a `didReceiveMemoryWarning`.

Two of the largest hot caches are **custom (non‑`NSCache`) allocators**, so they don't even get UIKit's automatic eviction:

- **Decoded‑thumbnail RAM (`DecodedThumbnailCache`, custom LRU): ~328 MiB on a 4 GB device, zero pressure response on iOS.** This is the single largest and least‑protected consumer.
- **GPU texture residency (`MetalGridTextureCache`, custom): 64 MiB (compact), zero pressure response on iOS** (its `setResidencyPressureScale` hook is wired to the governor **only on macOS**, via `MetalGridCoordinator`; the iOS host `UIKitTimelineGridHost` never calls it).

The `NSCache`‑based tiers (compressed byte RAM, UIImage wrappers, viewer display cache) get *weak, uncoordinated* automatic eviction from UIKit on a memory warning, so they are partially self‑protecting; the two custom caches above are not protected at all.

**Verdict:**
1. **Priority 1 — wire pressure response on iOS** (an `iOSMemoryPressureCoordinator` + a `UIKitThumbnailFeed.applyMemoryPressure` + register the feed, byte cache, texture cache, and viewer). This is worth more than any renumbering.
2. **Priority 2 — trim the static 4 GB decoded target** from ~328 MiB toward **~200–224 MiB** (≈5.5–7% at ≤4 GB), keeping the compressed‑byte and encrypted‑disk tiers so re‑decode stays cheap.
3. Everything else (grid snappiness, corner radius) is tractable *without* growing RAM.

Nothing here requires 8 GB for a good baseline; the disk cache is already AES‑GCM encrypted (no plaintext‑on‑disk risk); and macOS desktop budgets are correctly confined to AppKit adapters (Core holds none).

---

## 2. Current budget table (4 / 6 / 8 / 12 GB)

Formulas (iOS/iPadOS), read from source:

| Cache | Source | Fraction | Floor | Ceiling |
|---|---|---|---|---|
| Compressed/decrypted **byte RAM** | `UIKitMediaCachePolicy.swift:14‑15` | 1.0% | 32 MiB | 512 MiB |
| **Decoded thumbnail RAM** | `UIKitMediaCachePolicy.swift:18‑19` | 8.0% | 96 MiB | 1024 MiB |
| **UIImage wrapper RAM** | `UIKitMediaCachePolicy.swift:22‑23` | 0.25% | 8 MiB | 48 MiB |
| **GPU texture residency** | `UIKitMetalGridTexturePolicy.swift:35/40/45` | *(surface‑class, not physical)* | — | compact 64 / regular 96 / expanded 192 MiB |

Resolved budgets (1 GiB = 1024 MiB; GPU shown for **compact iPhone**). Independently recomputed and confirmed by the verifier:

| Physical RAM | Byte RAM | Decoded RAM | Wrapper | GPU (compact) | **Grid‑hot subtotal** |
|---:|---:|---:|---:|---:|---:|
| **4 GB** | 41 MiB | **328 MiB** | 10 MiB | 64 MiB | **~443 MiB** |
| **6 GB** | 61 MiB | 492 MiB | 15 MiB | 64 MiB | ~632 MiB |
| **8 GB** | 82 MiB | 655 MiB | 20 MiB | 64 MiB | ~822 MiB |
| **12 GB** | 123 MiB | 983 MiB | 31 MiB | 64* MiB | ~1201 MiB |

\* 12 GB devices are iPads → `regular`/`expanded` GPU class (96/192 MiB), so iPad grid‑hot is ~1233–1329 MiB. **No floor/ceiling clamp binds at any of these four sizes** — all three physical‑derived budgets scale linearly; the nearest approach is 12 GB decoded (983 MiB) just under its 1024 MiB ceiling (a 16 GB iPad Pro would clamp there).

**Separated by memory type:**

| Class | What lives here | Bounded? |
|---|---|---|
| **RAM (app footprint)** | byte RAM, decoded RAM, wrapper RAM (all above) + viewer display cache (48 MiB, `MobileViewerImageStore.swift:44`) + AVPlayer forward buffer (~30 s, `VideoPlaybackController.swift:96`) | mostly yes; AVPlayer buffer is AVFoundation‑managed |
| **GPU / IOSurface residency** | Metal texture cache, 64/96/192 MiB by surface class; **counts fully against app footprint on Apple Silicon** | yes (byte + count caps, `evictToBudget`) |
| **Disk** | AES‑GCM encrypted thumbnail/preview blobs (uncapped by design), encrypted video blocks (512 MiB LRU, `VideoByteRangeCache.swift:21`), encrypted originals LRU cache | thumbnails/previews **uncapped**; video/originals capped |
| **Transient decode/upload** | per‑frame texture upload budget (compact 2 MiB / ≤2.5 ms, `UIKitMetalGridTexturePolicy.swift:35`); off‑main decode task‑group (≤4 lanes) | yes |

macOS comparison (confirms iOS is **not** inheriting desktop assumptions — all desktop values live only in AppKit adapters):

| Cache | macOS | iOS |
|---|---|---|
| byte RAM | 2% / 64–2048 MiB | 1% / 32–512 MiB |
| decoded RAM | 15% / 256 MiB–20 GiB (`ThumbnailFeed.swift:58‑63`) | 8% / 96–1024 MiB |
| wrapper RAM | 0.5% / 16–96 MiB | 0.25% / 8–48 MiB |
| GPU residency | 512 MiB fixed (`AppKitMetalGridTexturePolicy.swift:28`) | 64 / 96 / 192 MiB by surface class |

Core holds **only portable shapes** (`GridTextureBudget`, `ThumbnailCacheConfiguration` default 128 MiB, `ThumbnailFeedCoreConfiguration` default 128 MiB); a grep of `*Core` for the macOS byte constants returns zero matches. ✔ Non‑goal "don't move macOS budgets into Core" is currently satisfied — keep it that way.

---

## 3. Risk findings, ordered by severity

**R1 — CRITICAL: the memory‑pressure governor is never driven on iOS.**
`AppMemoryPressureCoordinator` is macOS‑only (`import AppKit`, drives the governor from `DispatchSource.makeMemoryPressureSource` + thermal). `iOSApp/` has **zero** references to `MemoryPressureGovernor`, `MemoryConditions`, or `didReceiveMemoryWarning` (verified by repo‑wide grep). `MemoryPressureGovernor.shared.update(...)` is never called on iOS → the tier is frozen at `.normal` forever. The coordinator's own header even documents the missing iOS adapter (`AppMemoryPressureCoordinator.swift:13‑15`).

**R2 — CRITICAL: the two largest grid‑hot caches have no pressure response at all on iOS.**
- `DecodedThumbnailCache` (~328 MiB @4 GB) is a custom `NSLock` LRU (`ThumbnailFeedCore.swift:934`), **not** an `NSCache`, so it gets *no* automatic UIKit eviction. Its hook `applyDecodedMemoryPressure` (`ThumbnailFeedCore.swift:166`) exists but is unreachable on iOS: `UIKitThumbnailFeed` **exposes no `applyMemoryPressure` method at all** (macOS `ThumbnailFeed.swift:76` does), and `MobileLibraryModel` never registers the feed.
- `MetalGridTextureCache` (64 MiB) is custom; `setResidencyPressureScale` (`MetalGridTextureCache.swift:298`) is wired to the governor **only** through `MetalGridCoordinator` (macOS path). The iOS host `UIKitTimelineGridHost` / `MetalGridComposeCore` never reference a governor (grep‑confirmed).

Net effect on a 4 GB iPhone under a memory warning: ~392 MiB of custom‑cache RAM+GPU (328 decoded + 64 GPU) **does not shrink**. That is the jetsam exposure.

**R3 — HIGH: static 4 GB decoded target (~328 MiB) is larger than needed and unprotected.**
At a 320 px decode target, one RGBA thumbnail ≈ 320×320×4 ≈ 410 KB, so 328 MiB ≈ ~800 decoded thumbnails ≈ 2–5 dense screens. Visible + a couple screens of overscan needs ~300–500. The surplus buys little snappiness while raising the un‑purgeable floor on the most jetsam‑prone device (see §2, R2). **Recommend ~200–224 MiB at ≤4 GB** (≈5.5–7%).

**R4 — MEDIUM: no iOS‑side coordinated viewer purge; relies on `NSCache` luck.**
`MobileViewerImageStore` (48 MiB, `NSCache`) is per‑viewer and released on close (`MobilePhotoViewer.swift` teardown) — good — but it never registers with the governor, so under warning it depends on `NSCache`'s opaque automatic eviction rather than a coordinated purge. macOS registers `PhotoViewerModel.applyMemoryPressure` (`AppMemoryPressureCoordinator.swift:83‑85`); iOS has no equivalent.

**R5 — MEDIUM (visual + minor perf): dense square thumbnails render forced‑round corners.**
`MetalGridFrameComposer.clampedRadius` (`MetalGridFrameComposer.swift:202‑205`) clamps the 11 pt radius **up to 50% of the slot** — literally "keeps tiny dense cells round." That is the opposite of the owner's intent, and it means every dense tile is drawn as an anti‑aliased rounded quad (per‑fragment SDF + `smoothstep`, `MetalGridRenderer.swift:452‑465`) that must alpha‑blend its edges against the background instead of drawing as an opaque square. See §10.

**R6 — LOW: thumbnail/preview disk cache is uncapped.**
By design (`ThumbnailCache.swift:209`) thumbnails/previews grow unbounded on disk (only *originals* and *video* are LRU‑capped). Encrypted and safe, but on a small device a very large library could accumulate a large `.enc` directory. Not a RAM/jetsam risk; worth a soft cap eventually.

**R7 — LOW: budget signal is `physicalMemory`, which ignores the real jetsam headroom.** iOS jetsam is governed by *available* memory, not physical. `os_proc_available_memory()` is the correct headroom signal and is not consulted anywhere. See §4.

---

## 4. What should budgets be based on? (recommended model)

Evaluation of the four candidate signals:

| Signal | Verdict |
|---|---|
| `ProcessInfo.physicalMemory` | Keep as the *coarse device‑class* input, but it over‑estimates usable RAM on 4 GB devices (jetsam kills long before physical is exhausted). Fine for picking a device class; wrong as the sole ceiling. |
| Surface class (compact/regular/expanded, `UIKitMetalGridTexturePolicy.swift:9‑14`) | **Right abstraction for GPU residency** (screen area drives working‑set size). Keep; extend to viewer transient budget. |
| `MemoryPressureGovernor` (Core) | **Correct mechanism, already built and tested — just not driven on iOS.** This is the runtime‑pressure axis. Wire it. |
| UIKit memory‑warning notifications | The *iOS event source* the governor needs. Map `didReceiveMemoryWarning → .critical/purge` and thermal → tiers, exactly as the macOS `DispatchSource` path does. |

**Recommended layering (no platform forks in Core):**

- **Core owns budget *shape* + pressure *scale semantics* only.** `MemoryConditions`, `MemoryBudgetTier {normal 1.0, reduced 0.5, minimal 0.0+purge}`, `MemoryBudgetPolicy`, `GridTextureBudget`, `ThumbnailCacheConfiguration` — already correct. Core names **no bytes**. ✔ Keep.
- **UIKit adapter owns concrete iPhone/iPad numbers** (`UIKitMediaCachePolicy`, `UIKitMetalGridTexturePolicy`). Add: a **device‑memory‑class curve** for decoded RAM (lower fraction/ceiling at ≤4 GB), and consult `os_proc_available_memory()` as a dynamic ceiling. No device‑name special cases — key on memory class + surface class + pressure class.
- **Metal texture adapter owns GPU residency numbers** (already does, by surface class). ✔
- **Viewer owns its own transient caches with explicit purge hooks** and registers them with the governor (currently only macOS does).
- **New: an `iOSMemoryPressureCoordinator`** (the platform half, mirroring `AppMemoryPressureCoordinator`) drives the *same* Core governor from `UIApplication.didReceiveMemoryWarning` + `ProcessInfo.thermalStateDidChange` + `scenePhase == .background`.

This keeps the exact "adapters supply numbers/events, Core supplies mechanism" contract the codebase already documents.

---

## 5. What should happen under memory pressure? (target behavior)

Current matrix on **iOS** (skeptical — "scales" only where a registration/hook is actually reachable):

| Resource | normal | warning (`.reduced`) | critical (`.minimal`) | backgrounding | viewer close |
|---|---|---|---|---|---|
| Byte RAM (`NSCache`) | full | *weak auto only* (governor **not wired**) | *weak auto only* | none | n/a |
| **Decoded RAM (custom LRU)** | full | **no response — GAP** | **no response — GAP** | none | n/a |
| Wrapper RAM (`NSCache`) | full | *weak auto only* | *weak auto only* | none | n/a |
| **GPU texture residency (custom)** | full | **no response — GAP** | **no response — GAP** | none | n/a |
| Viewer display cache (`NSCache`) | full | *weak auto only* | *weak auto only* | none | **released ✔** |
| Video range/decrypted buffers | disk‑bounded | none (RAM buffer AVFoundation‑managed) | none | released on teardown | **released ✔** |
| Live Photo motion | disk blocks | none | none | released on teardown | **released ✔** |

"weak auto" = `NSCache`'s own opaque eviction on a system memory warning; not coordinated, not guaranteed.

**Target behavior (proposed), driven by the wired governor:**

- **normal (tier 1.0):** full budgets.
- **warning / `.reduced` (0.5):** halve *future* budgets on byte, decoded, wrapper, and GPU residency (evict offscreen down to the new ceiling; **visible/pinned never evicted** — the texture cache already guarantees this, `MetalGridTextureCache.swift:275`). Pause the background crawl (`setUserInteractionActive`/`pausePrefetch`). Do **not** touch the encrypted disk tier.
- **critical / `.minimal` (0.0 + purge):** immediately drop all non‑visible holdings — decoded LRU `removeAll`, wrapper purge, texture residency down to the visible pinned set, viewer display cache purge (keep only the on‑screen page), byte RAM purge. Disk stays intact (bytes re‑read/re‑decoded on demand).
- **backgrounding (`scenePhase == .background`):** treat as ≥`.reduced` (Apple reclaims backgrounded apps first). Purge the decoded LRU and non‑visible textures; keep byte RAM small; tear down any live viewer video/motion.
- **viewer close:** already correct on iOS (motion/video/display released). Add: register the display cache so a warning *while the viewer is open* purges non‑visible pages.

**Acceptance:** after warning/critical, only visible or immediately‑needed resources remain resident; the AES‑GCM disk cache is never deleted by pressure (only re‑read).

---

## 6. Can we make the grid snappy *without* more RAM? (yes — the pipeline is already good)

The warm/prefetch engine (`ThumbnailFeedCore`) is already close to the ideal; the wins are wiring + small policy, not bigger caches:

| Goal | Current state | file:line | Action |
|---|---|---|---|
| Visible‑first | ✔ 5‑tier priority (`.visibleNow` … `.idleLibraryCrawl`); priority queue drained before crawl | `ThumbnailFeedCore.swift:210,689‑712`; `Diagnostics.swift` enum | keep |
| Scroll‑direction next viewport | ✖ no velocity/direction look‑ahead; only a 100 ms settle debounce coalesces the visible set | `MetalGridDataSource.swift:71,135` | **add** a direction‑biased overscan on settle (cheap: warm N rows ahead in the scroll direction at `.nearViewportScrollAhead`) |
| RAM‑ready before GPU upload | ✔ decode→`DecodedThumbnailCache`→GPU pulls from RAM only; no GPU‑triggered decode | `ThumbnailFeedCore.swift:283‑313,846`; `GridTextureResidencyPolicy` | keep |
| Settled soft→sharp upgrades | ✔ upgrade only when `zoomTransaction == nil` | `MetalGridCoordinator.swift:1742‑1747` | keep; ensure iOS host takes the same gate |
| No per‑frame disk/decrypt/decode | ✔ hot read (`memoryImage`/`memoryDecoded`) is a nonisolated O(1) LRU lookup; decode is off‑main | `ThumbnailFeedCore.swift:191,958‑962`; `UIKitThumbnailFeed.swift:66,75` | keep |
| Don't warm too far during fast scroll | ✔ 3 layers: 100 ms coalesce, `recentVisibleDemand` crawl backoff (0.25 s), `setUserInteractionActive` pause | `ThumbnailFeedCore.swift:716,432` | keep |
| Don't starve visible with crawl | ✔ crawl yields to demand; coverage rescan is single‑flight + 512‑item chunked + aborts on demand | `ThumbnailFeedCore.swift:536‑562,757‑768` | keep |

The one genuinely missing piece is **scroll‑direction‑aware overscan** (a small, RAM‑neutral scheduling change: bias the settle warm batch toward the scroll direction). Everything else is already implemented and tested — so "snappy on 4 GB" is achievable by wiring pressure response (§5) + this small scheduling tweak, **without** enlarging any cache.

---

## 7. Diagnostics required before tuning

**Already present** (use these; do not re‑invent):

| Signal | Where |
|---|---|
| `diskMissing` | `thumb.diskCacheMiss` counter (`ThumbnailFeedCore.swift:187,340`) |
| `diskHitRamMissing` | `thumb.diskCacheHit` + `thumb.ramDecodeMiss` (`:181,315‑318`) |
| decode‑queue latency | `recordDecodeStarted/Completed(durationMs, queueDepth)` (`:828,837`) + `feed.decode` signpost (`:830`) |
| decrypt/read latency | `feed.decrypt` signpost (`:288,332`) |
| crawl coverage / prefetch health | `[ThumbCoverage]` (`:812`), `[ThumbPrefetch]` throttled 1 s (`:867`) |
| texture upload/evict internals | `evictionsThisFrame`, `uploadMsThisFrame`, `upgradesThisFrame`, `pendingUpgradesThisFrame` (in `MetalGridTextureCache`) — *counters exist but are not emitted as a log line on iOS* |

**Missing — add (no per‑frame spam; emit on state change or ≥1 s throttle):**

1. **`ramHitGpuMissing`** — RAM‑decoded but not yet GPU‑resident. Needs a cross‑counter (feed knows RAM; texture cache knows residency). Add to a coalesced `[MobileGridPerf]` line.
2. **`[MobileGridPerf]`** (settle‑throttled) — texture‑budget **saturation** (resident vs cap), `pendingUpgradesThisFrame` (**upload‑budget deferrals**), evictions/frame, RAM‑hit/GPU‑miss count. Surfaces R2/R5 on device.
3. **`[MemBudget]`** — one line **per governor tier change**: `tier`, `pressure`, `thermal`, `os_proc_available_memory()`, and the resulting scaled byte/decoded/GPU ceilings. This is the primary "did the valve fire?" trace. (Currently there is *no* log when the tier changes.)
4. **Viewer full‑res cache pressure** — `[ViewerPerf]` already logs fetch/decode ms (`MobileViewerImageStore.swift`); add cache‑cost/limit + evictions and a purge line on tier change.
5. **`os_proc_available_memory()` + footprint sample** on each `[MemBudget]` line so 4/6/8/12 GB behavior is measurable against real jetsam headroom, not physical RAM.

---

## 8. Tests to add before implementation (deterministic, fast)

1. **Budget calculation, 4/6/8/12 GB** — call `UIKitMediaCachePolicy.dataMemoryBudgetBytes(physicalMemory:)` / `decodedRAMBudgetBytes` / `wrapperRAMBudgetBytes` with injected physical values (the param already exists) and assert exact MiB, incl. clamp edges (e.g. 2 GB hits the 96 MiB decoded floor; 16 GB hits the 1024 MiB ceiling). *No existing test covers this — biggest gap.*
2. **Device‑memory‑class decoded curve** — assert the new ≤4 GB decoded target lands in ~200–224 MiB while ≥6 GB keeps 8%.
3. **Memory‑pressure scale/purge through the iOS feed** — extend the existing `decodedRamTierRespondsToMemoryPressureThroughFeed` (`ThumbnailFeedCoreTests.swift:434`) to the *new* `UIKitThumbnailFeed.applyMemoryPressure` so it scales **both** the wrapper `NSCache` and the decoded core.
4. **Texture residency caps by surface class** — assert compact/regular/expanded resident caps and that `.reduced`/`.minimal` shed offscreen but keep the visible pinned set (build on `GridPolicyTests.swift:289‑319`).
5. **Governor fan‑out through an iOS coordinator** — a portable test that a simulated `didReceiveMemoryWarning` → `.minimal` reaches every registered responder (byte, decoded, wrapper, texture, viewer) exactly once. *No end‑to‑end adapter test exists today.*
6. **Viewer cache purge on close + on warning** — assert `MobileViewerImageStore` drops non‑visible pages on a `.minimal` tier and frees on close.
7. **No disk/decode in the render read path** — strengthen `firstWarmPassFetchesVisibleNetworkMissesButNotDiskHits` (`ThumbnailHealthTests.swift:90`) into an assertion that `memoryImage`/`memoryDecoded` never call `diskData`/`downsample`.
8. **Visible warm preempts crawl** — already covered (`ThumbnailCrawlYieldTests.swift:64‑100`); keep as a regression guard.
9. **Corner‑radius policy thresholds** — new `GridCornerRadiusPolicy` unit tests (see §10): large→11, medium→reduced, tiny square→0, monotonic in `slotSidePoints`.

---

## 9. Staged implementation plan

**Stage 1 — Measurement / diagnostics only (lowest risk, do first).**
Add `[MemBudget]` (tier changes + `os_proc_available_memory`), `[MobileGridPerf]` (residency saturation, upload deferrals, RAM‑hit/GPU‑miss), and viewer cache‑pressure logging. Files: `PhotosCore/Diagnostics.swift`, `MetalGridTextureCache.swift` (emit existing counters), `TimelineUIKitFeature/UIKitTimelineGridHost.swift`, `iOSApp/MobileViewerImageStore.swift`. **Risk: negligible.** Effect: none on perf; gives the numbers to justify Stage 2/3. Manual test: scroll + simulate memory warning, read log tags.

**Stage 2 — Budget‑policy tests + calibrated numbers.**
Add the §8.1–8.2 tests, then introduce a device‑memory‑class decoded curve in `UIKitMediaCachePolicy` (≤4 GB → ~200–224 MiB) and consult `os_proc_available_memory()` as a dynamic ceiling. Files: `MediaCacheUIKitAdapter/UIKitMediaCachePolicy.swift`, new tests in `MediaCacheUIKitAdapterTests`. **Risk: low** (pure policy, guarded by tests). Effect: −100–130 MiB resident on 4 GB, negligible on ≥8 GB; small increase in scroll‑back re‑decode (mitigated by byte + disk tiers). Manual test: 4 GB sim + real 4 GB iPhone footprint before/after.

**Stage 3 — Memory‑pressure wiring gaps (the core fix).**
Add `iOSMemoryPressureCoordinator` (mirror of the macOS one) driving the Core governor from `didReceiveMemoryWarning` + thermal + background. Add `UIKitThumbnailFeed.applyMemoryPressure(scale:purge:)` (scales wrapper `NSCache` + calls `core.applyDecodedMemoryPressure`). Register feed, byte cache, viewer store, and texture cache. Wire the iOS grid host to call `setResidencyPressureScale`. Files: new `iOSApp/iOSMemoryPressureCoordinator.swift`, `MediaCacheUIKitAdapter/UIKitThumbnailFeed.swift`, `iOSApp/MobileLibraryModel.swift` (register on `configure`), `iOSApp/MobilePhotoViewer.swift`/`MobileViewerImageStore.swift`, `TimelineUIKitFeature/UIKitTimelineGridHost.swift`. **Risk: medium** (touches lifecycle; keep purge on visible‑protected paths only — the texture cache already never evicts visible). Effect: bounded resident under pressure → materially lower jetsam rate; the 328→200 MiB static number matters far less once `.reduced` halves and `.minimal` purges. Manual test: Instruments "Simulate Memory Warning" + real‑device background/return.

**Stage 4 — Smarter warm/prefetch scheduling (RAM‑neutral).**
Add scroll‑direction‑biased overscan on the 100 ms settle batch (warm N rows ahead in the travel direction at `.nearViewportScrollAhead`). Files: `TimelineFeature/MetalGridDataSource.swift`, `TimelineUIKitFeature/UIKitTimelineGridHost.swift`. **Risk: low‑medium.** Effect: fewer visible misses when resuming scroll, no cache growth. Manual test: fast fling then stop; count blank tiles.

**Stage 5 — Optional disk/layout improvements (only if Stage‑1 evidence supports).**
Soft cap on the thumbnail/preview `.enc` disk directory (LRU, generous), keyed off measured growth on small devices. Files: `MediaByteCache/ThumbnailCache.swift` (extend `enforceByteCap` to thumbnails behind a policy flag). **Risk: low.** Effect: bounds long‑term disk on 64 GB phones. Manual test: large‑library device disk‑size before/after.

---

## 10. Corner‑radius finding (dense square tiles should have no rounding)

**Where it's defined & applied:**
- Master constant `GridVisualConstants.thumbnailCornerRadius = 11` pt (`GridVisualConstants.swift:8`) — the single source of truth.
- Passed into the **shared** composer `MetalGridFrameComposer.buildGroups(cornerRadius:)` (`MetalGridFrameComposer.swift:145`) from **both** platforms: macOS `MetalGridCoordinator.swift:1798` and iOS `UIKitTimelineGridHost.swift:612`.
- **Clamped per tile on the CPU** by `clampedRadius(base, cell) = min(base, slotSide*0.5)` (`MetalGridFrameComposer.swift:202‑205`) — comment: *"keeps tiny dense cells round."* This is exactly the wrong behavior: on a 44 px dense tile the radius becomes 22 px → a squircle/blob.
- **Evaluated per fragment** in the shader: `roundedRectSDF` + `smoothstep` AA, unconditionally, for every quad (`MetalGridRenderer.swift:452‑465`). No `radius==0` fast path; every tile's edges are anti‑aliased and alpha‑blended against the background.

**Cost at dense levels:** the SDF math itself is cheap (~6–8 FLOPs, no branch/discard — measured by the reader at <5% of fragment cost, texture fetch dominates). The real costs of forcing rounding on tiny tiles are (a) **visual** (blobby squares — the owner's complaint), and (b) **modest bandwidth/overdraw**: a rounded tile can't be drawn as a fully opaque quad, so every dense tile's perimeter fragments are partial‑coverage blends, and the perimeter‑to‑area ratio is high when tiles are tiny. Both are avoidable.

**Proposed generic policy (shared Core, not iOS‑level‑specific):**
Add a pure function in **GridCore**, a peer of `GridSizePolicy.slotSide`:

```
// GridCore — platform‑neutral, value‑type, no UIKit/AppKit.
enum GridCornerRadiusPolicy {
    /// Corner radius (pt) for a square slot of the given side.
    /// large → base(11); medium → reduced (∝ side); tiny square → 0.
    static func radius(forSlotSidePoints side: CGFloat,
                       base: CGFloat = GridVisualConstants.thumbnailCornerRadius) -> CGFloat {
        switch side {
        case ..<64:  return 0          // dense/tiny square → sharp 90° corners
        case ..<120: return min(base, side * 0.10)   // medium → reduced
        default:     return base       // large → normal
        }
    }
}
```

Then **replace** `clampedRadius` so the composer derives the radius from the tile side via this policy (it already has `cell` per tile). Adapters supply only the visual scale/profile inputs (`slotSidePoints`, size class) — the *decision* stays in Core, so iOS/iPad/foldable profiles inherit it automatically. Thresholds are in **points**, so macOS large tiles keep radius 11 and only genuinely dense square levels go sharp (the same generic policy applies to macOS dense levels by design — acceptable per the brief; document it).

**Optional renderer micro‑opt (measure‑gated):** add a `radius == 0` fast path in `metalGridFragment` that skips the SDF + `smoothstep` and returns the full‑coverage sample (or a dedicated `mode == squareOpaque`). Dense levels share radius 0 → the branch is coherent → the renderer stops paying rounded‑corner + edge‑blend cost for tiny square cells. Keep AA for the rounded (large) path.

**Tests:** `GridCornerRadiusPolicyTests` — `radius(48)==0`, `radius(96)` reduced & `< base`, `radius(200)==11`, monotonic non‑decreasing in side, never exceeds `side*0.5`. Add a compose‑parity assertion that a dense profile yields `MetalGridQuad.radius == 0`.

**Acceptance:** dense square grid → sharp 90° corners; larger grids still polished at 11 pt; renderer avoids unnecessary rounded‑corner cost for tiny cells; no macOS regression except intentional dense‑level parity.

---

## 11. "Do not do" list

- ❌ **Do not "just cache everything."** The fix is a working pressure valve + a *smaller* protected decoded budget, not a bigger one.
- ❌ **Do not add a plaintext disk cache.** The disk tier is already AES‑GCM sealed with per‑account keys (`SecureBlobCipher`); pressure must only re‑read/re‑decode, never write plaintext or delete blobs.
- ❌ **Do not move macOS budgets into Core.** Core holds only shapes today; keep the ≤4 GB decoded curve in `UIKitMediaCachePolicy`, GPU numbers in the Metal UIKit adapter.
- ❌ **Do not require 8 GB for a good baseline.** All Stage‑3/4 changes target the 4 GB compact device first.
- ❌ **Do not add device‑name special cases.** Key on memory class + surface class + pressure class only.
- ❌ **Do not add a big tiny‑thumbnail derivative cache** without quantifying CPU/storage/security and making it optional/deferred (out of scope here).
- ❌ **Do not redesign the Metal renderer.** The corner change is one Core policy function + an optional coherent shader branch.
- ❌ **Do not add per‑frame logging.** All new diagnostics are tier‑change‑ or settle‑throttled.

---

## 12. Manual validation checklist (owner)

**Simulator (Xcode, iOS 4 GB‑class device profile):**
- [ ] Cold launch → scroll a large library. Confirm no blank‑grid stall; watch `[ThumbPrefetch]`/`[ThumbCoverage]` and (Stage 1) `[MobileGridPerf]`.
- [ ] **Debug ▸ Simulate Memory Warning** while scrolling. **Before fix:** decoded + GPU footprint unchanged (Xcode Memory gauge). **After Stage 3:** `[MemBudget]` logs a `.minimal` tier; footprint drops; on‑screen tiles stay drawn; scrolling back re‑decodes without jank.
- [ ] Open the viewer, trigger a memory warning: non‑visible pages purge, current page stays.
- [ ] Pinch to the densest square level: corners are **sharp 90°** (after §10); larger levels still rounded at 11 pt.

**Real iPhone (a 4 GB‑class device, e.g. a ~5‑year‑old model):**
- [ ] Instruments **Allocations + VM Tracker**: capture *grid‑hot* resident during a long scroll. Target ≤ ~300 MiB grid‑hot (Stage 2/3), total app while scrolling comfortably under the device's jetsam ceiling (sample `os_proc_available_memory()` via `[MemBudget]`).
- [ ] Instruments **os_signpost** (`feed.decode`, `feed.decrypt`): confirm no decode/decrypt on the render thread; decode stays off‑main.
- [ ] Background the app, open several other apps, return: grid restores from disk quickly; confirm no jetsam relaunch (Console: no `jetsam` / `memorystatus` kill for the app).
- [ ] Thermal: run a sustained scroll until `.serious`; confirm crawl backs off and budgets go `.reduced` (`[MemBudget]`), scrolling stays smooth.
- [ ] 30‑minute soak scrolling + viewer paging: footprint plateaus (no unbounded growth); disk `.enc` size reasonable (Stage 5 gate).
- [ ] Live Photo long‑press + video playback then dismiss: confirm player/motion/display resources free on close (Memory graph shows the store deallocated).

---

*Read‑only audit — no production code was modified. No build was run (not required for a read‑only audit; the tree is clean on `claude/ios-polish-perf-pass`). Implementation is gated on owner approval of §9.*
