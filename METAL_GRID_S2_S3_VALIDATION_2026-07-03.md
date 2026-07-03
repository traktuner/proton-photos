# Metal Grid S2–S3 Validation — Proton Photos — 2026-07-03

Executes slices S2 (universal frame composer) and S3 (vertex direct-write) from
`METAL_RENDERER_ARCHITECTURE_2026-07-03.md` §6, plus the local measurement gate. S4 Bindless was **not**
implemented (out of scope, and its §5 measured trigger is not met). Branch `codex/metal-grid-s2-s3-measurement`,
off `6bae2193` (the `drawMs`/`gpuMs` timing split). Owner architecture contract respected throughout: no
`#if os(...)` behavioural forks in Core, no AppKit/UIKit/SwiftUI/MetalKit in the new Core module, one shared
algorithm for macOS/iOS/iPadOS.

---

## 1. Commits produced

| # | Hash | Message |
|---|------|---------|
| 1 | `b1b74ea1` | S2a: Extract universal MetalGridComposeCore; macOS delegates to it |
| 2 | `2eea8035` | S2b: UIKit timeline host adopts the universal frame composer |
| 3 | `198deec4` | S3: Direct-write grid vertices into the pooled ring buffer |
| 4 | *(this report)* | Measurement/validation report only |

Baseline `6bae2193`. No `git reset`/`checkout --`/revert of user work. `gpuDrawMs` did not return (guarded).

---

## 2. What S2 changed — universal frame composer (the addendum-mandated step)

**Problem (architecture doc §1.2 item 7):** the settled frame loop existed twice. `MetalGridCoordinator`
(macOS) owned the full sequence; `UIKitTimelineGridHost` (iOS) re-implemented a smaller copy. A
streaming/rendering bug fixed on macOS was **not** fixed on iOS — a direct violation of the owner rule.

**New module `MetalGridComposeCore`** (`Sources/MetalGridComposeCore/MetalGridFrameComposer.swift`):
- Dependencies: `GridCore`, `MetalGridTextureCore`, `MetalRenderingCore` only. No AppKit/UIKit/SwiftUI/MetalKit,
  no `PhotosCore` — **generic over the item ID** (`ID: Hashable & Sendable`), so no photo-domain coupling.
- Data-in/data-out; retains no platform objects; mutates only the injected `MetalGridTextureCache`.
- Owns the four previously-duplicated pieces:
  - `classifyVisibility(slots:flatUIDs:viewportSize:)` — visible vs overscan UID split.
  - `viewportDrawSlots(_:viewportSize:)` — viewport-only draw filter.
  - `stream(...)` — effective-pixel cap → window + byte-budget pin clamp → `beginFrame` → visible upload →
    soft→sharp upgrade → warm selection. Returns `(warm, pendingVisibleQualityUpgrade)`.
  - `buildGroups(...)` — resident/placeholder image group + production decoration groups (selection outline,
    favorite/checkmark/video badges), in fixed order.

**S2a — macOS delegation (`b1b74ea1`).** `MetalGridCoordinator.streamTextures` / `buildRealGroups` /
`viewportDrawSlots` are now thin wrappers over the composer, **byte-identical** in behaviour. The host keeps
only what is genuinely platform: the level-aware upload-pixel size, the cold-visible pin policy
(`pinOverscan`), the warm pump (`dataSource.warm`), the `[FirstContent]` trace, the AppKit accent-colour
conversion for decorations (`MetalGridGlyphColor(.controlAccentColor)` stays at the adapter edge), and the
`streamTextures.upload`/`streamTextures.upgrade` signpost intervals — injected into the composer through a
neutral `MetalGridComposeSignposts` seam so Core imports no diagnostics module.

**S2b — iOS adoption (`2eea8035`).** `UIKitTimelineGridHost` deleted its private `classifyUIDs` /
`viewportSlots` / `buildGroups` and now calls the same composer. It keeps only iOS plumbing (CAMetalLayer
drawable, CADisplayLink, UIScrollView, upload size, warm pump). A cached flat `itemUIDs` backs the composer
input so the per-frame path never re-maps the library. iOS corner radius converged from a local literal `6`
to the canonical `GridVisualConstants.thumbnailCornerRadius` (11) — a config value, not an algorithm fork; the
composer clamps it to ≤ half-slot exactly as macOS does.

**Net:** the duplicated macOS/iOS frame loop is **eliminated**. Both platforms now render through literally the
same Core code; a future streaming/rendering fix lands once for all platforms.

---

## 3. What S3 changed — vertex direct-write (`198deec4`)

**Problem (architecture doc §1.2 item 2):** the steady `render(...)` path built a fresh Swift `[Vertex]`
array per group, then `memcpy`'d each into the pooled ring buffer — ~0.2–0.65 MB of transient allocation +
copy per invalidated L5 frame, on top of the (sound, Apple-canonical) ring itself.

**Change:** `MetalGridRenderer.encode(...)` on the pooled path now computes each non-empty group's vertex
offset up front, grows the ring slot once, and writes each quad's six vertices **directly** into
`buffer.contents()` through a typed `UnsafeMutablePointer<Vertex>` (`writeQuad`). No intermediate array, no
`memcpy`. `Vertex` is a trivial struct, so writing into uninitialised buffer memory is safe. The vertex layout
is single-sourced in a new `quadVertices(_:)` helper shared by `writeQuad` (pointer) and `appendQuad` (array),
so the two paths can never diverge.

**Preserved exactly:** group order, draw order, `drawCalls` / `instanceCount` / `textureBinds` (all derived
from each group's quad count), per-quad texture handling, shared-texture groups, and — untouched — the
offscreen dissolve path (`pooledSlot == nil`), which keeps transient per-group buffers (it runs only on
layer-dirty frames, per `e5d6cdb2`). No shader change, no binding-model change, no visual change.

---

## 4. Tests run and results

| Gate | Command | Result |
|---|---|---|
| Full package suite | `swift test --package-path Packages/ProtonPhotosKit` | **621 tests / 84 suites green** (baseline 611 + 10 new) |
| Universal-core gate | `./scripts/verify-universal-core.sh` | **green** — every Core target incl. `MetalGridComposeCore` builds for **iOS + macOS**; `TimelineUIKitFeature` builds for iOS |
| App build/install/launch | `./scripts/rebuild.sh` | **green** — `BUILD SUCCEEDED`, installed to `/Applications/ProtonPhotos.app`, launched |
| macOS renderer target | `swift build --target TimelineFeature` / `MetalRenderingCore` | green |
| iOS module builds | `xcodebuild -scheme MetalGridComposeCore / TimelineUIKitFeature -destination generic/platform=iOS` | `BUILD SUCCEEDED` |

New tests added (10):
- `CoreArchitectureGateTests.testMetalGridComposeCoreStaysCompositionOnly` — import/token/boundary gate for the
  new module (forbids AppKit/UIKit/SwiftUI/MetalKit/`PhotoUID`/host diagnostics; pins deps + product).
- `MetalGridComposeParityTests` (7) — classification split, viewport draw filter, streaming window/pin
  (incl. `pinOverscan:false` clamp), RAM-ready-upload vs warm-missing selection, render-group order + quad
  rect/UV/mode parity, no-decoration case. Device-backed tests skip cleanly with no GPU.
- `MetalGridVertexDirectWriteTests` (3) — locks the direct-write structure: no `memcpy(` call, single-sourced
  vertex layout, preserved draw/instance/bind accounting.
- `testTimelineUIKitFeatureOwnsIOSPhotoGridAssembly` updated: requires the composer dep/import + delegation,
  forbids re-introducing `GridTextureStreamingPolicy.window` or a private `buildGroups`/`classifyUIDs`.
- `rendererDoesNotComputeAspectGeometry` retargeted at the composer (composition's new home).

---

## 5. Runtime measurement summary

**Interactive `[MetalGridPerf]` / `[FirstContent]` capture was NOT run in this environment.** The macOS app
builds, installs, and launches, but the grid renders only after an authenticated Proton session and a live
library, and the scenarios (L3/L5 fast scroll, L0↔L5 pinch, ± zoom, sidebar/window resize, overview dissolve)
require GUI interaction — neither login nor interaction is available to a headless agent. A bounded headless
launch produced only the pre-login window (no grid diagnostics), as expected.

**Draw-count parity for S3 is guaranteed by construction, not yet by runtime A/B.** `drawCalls`,
`instanceCount`, and `textureBinds` are computed from the identical per-group quad counts before and after the
change (verified by code inspection and locked by `MetalGridVertexDirectWriteTests`). S2 is byte-identical on
macOS by delegation. The owner capture below will confirm the numbers on-device.

**Owner capture commands** (Debug build; `PhotoDiagnostics.emit` prints only in DEBUG):

```bash
./scripts/rebuild.sh
pkill -9 -f "ProtonPhotos.app/Contents/MacOS" 2>/dev/null || true
/Applications/ProtonPhotos.app/Contents/MacOS/ProtonPhotos 2>&1 | tee /tmp/protonphotos-metal-s2-s3.log
# …sign in, then exercise the §7 checklist, then:
grep '\[MetalGridPerf\]' /tmp/protonphotos-metal-s2-s3.log | tail -80
grep '\[FirstContent\]'  /tmp/protonphotos-metal-s2-s3.log | tail -20
```

Fields to record per scenario: `drawMs`, `gpuMs`, `drawCalls`, `textureBinds`, `instances`, `uploads`,
`uploadMs`, `deferredUploads`, `evictions`, `evictMs`, `residentMB`, `residentBudgetMB`, `pinnedOverflow`,
`byteBudgetOverflow`, `residencySaturated`, `effectivePixels`, `directUploads`, `normalizedUploads`,
`encodedSlots`. Acceptance: all flat-or-better vs the pre-S2/S3 baseline; `pinnedOverflow`/`byteBudgetOverflow`/
`residencySaturated` false in scenarios 1–7. Confirm the block contains `drawMs=` and `gpuMs=`, never
`gpuDrawMs=`.

---

## 6. Performance impact & the S4 Bindless decision

**Impact: neutral-to-positive, no regression path introduced.**
- S2 macOS: byte-identical delegation → neutral. Same upload order, pin set, visible/overscan split, group
  order, quads, draw counts, and stats semantics.
- S2 iOS: adopts the (superior) shared algorithm — pre-filters uploads by RAM readiness and inherits the
  byte-budget pin clamp it previously lacked; a modest positive, no regression.
- S3: removes transient `[Vertex]` allocation + `memcpy` on the steady path → strictly less CPU/allocator work
  at equal draw output; the hot L5/dense-frame case benefits most. Dissolve path unchanged.
- No change to draw/bind counts for equivalent scenes, upload/residency budgets, resident memory, visible
  thumbnails, display-link idling, or first-content latency.

**S4 Bindless / argument buffers remains DEFERRED** — unchanged from the architecture decision. Its §5 triggers
(iOS L5 encode > ~2 ms sustained on device, macOS > ~4 ms sustained, or > ~3,000 viewport draws) are **not
measured to be met**; the per-quad path is below budget on macOS and now measurable on iOS through the shared
composer. S2 delivered the precondition for ever measuring iOS honestly; S3 closed the vertex-churn remnant.
Nothing here needs Metal 4, texture arrays, `MTLHeap`, `setPurgeableState`, mipmaps, or a new binding model.

---

## 7. Owner manual regression checklist (macOS)

Run `./scripts/rebuild.sh`, then verify:
- App cold launch; timeline first content appears.
- L3 fast scroll; L5 fast scroll.
- L0↔L5 pinch chain; +/- zoom transitions at each level.
- Sidebar collapse/expand; live window resize mid-scroll.
- Overview dissolve boundary L3/L4/L5 (hold + scrub + commit).
- Photo viewer; video playback; Live Photo playback.
- Albums / filter / sidebar basic paths.
- `[MetalGridPerf]` logs contain `drawMs=` and `gpuMs=`, never `gpuDrawMs=`; counts flat-or-better.

**iOS/iPadOS:** device-side measurement was **not** run (no physical hardware in this environment). After a
`ProtonPhotosMobile` run on an A-series/M-series iPad at 120 Hz, repeat scenarios 1–3 + 7 and record the same
`[MetalGridPerf]` fields (now emitted by shared Core) to close the §5 gate.

---

## 8. Remaining risks & unrelated observations

- **Runtime numbers unconfirmed on-device** (macOS interactive + iOS hardware). Behaviour is byte-identical
  (S2 macOS) / structural (S3), so the risk is low, but the on-device A/B is the owner's to run (§5, §7).
- **iOS corner-radius convergence** (6 → 11) is an intentional, documented visual convergence on the iOS
  scaffold host, not a redesign; flag if the iOS look should keep the old smaller radius (pass `6` to
  `buildGroups`).
- **Signpost seam:** `streamTextures.upload`/`.upgrade` intervals are preserved on macOS via the injected
  `MetalGridComposeSignposts`; iOS omits them (no-op default) — the composer stays diagnostics-free by design.
- No unrelated issues required fixing to complete this task; none were fixed.
