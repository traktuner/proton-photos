# ML Search Architecture Audit — 2026-07-07

On-device semantic photo/video search for Proton Photos (macOS, iOS, iPadOS), E2EE-preserving,
Core-shared, adapter-thin. Read-only audit + architecture; no code was changed.

Research provenance: repo exploration, Apple SDK verification (local macOS 26.5 SDK swiftinterfaces
+ developer.apple.com), live Ente license/architecture research, and local inspection of
`Vendor/sdk-swift`. Every externally sourced claim is cited inline; estimates are marked.

---

## 1. Executive verdict

**Build it, and build it now — the repo is unusually well-prepared for exactly this feature.**

1. **Apple ships no text→image embedding API anywhere** (Vision, NaturalLanguage, Foundation
   Models all confirmed negative against the macOS 26.5 SDK). Semantic search therefore means
   shipping a **two-tower CLIP-class model via Core ML** (image tower for indexing, text tower for
   queries). There is no Apple shortcut and none is coming in the 26 SDKs.
2. **Brute-force search is sufficient forever at our scale.** 250k × 512-d dot products cost
   ~5–15 ms on-device (§12). No ANN library, no vector database, no new dependency.
3. **Index from what we already have.** The mandatory encrypted thumbnail crawl
   (`ThumbnailFeedCore` + `MediaByteCache`, 320 px thumbs) already delivers decrypted pixels ≥ the
   CLIP input size (256 px) for every asset, with coverage checkpoints and resume. The indexer
   rides that pipeline — **no original downloads, no PhotoKit dependency, no network for indexing**.
4. **First thing to build (Stage 1, §15):** `MLSearchCore` (pure) + `MLSearchAppleAdapter`
   (Core ML/Accelerate, shared verbatim across platforms like `PhotoLibraryBackupAdapter`) with a
   **permissively-licensed MobileCLIP-class model**, a local encrypted index keyed by
   `(PhotoUID, modelEpoch)`, and semantic results merged into the existing `TimelineSearch` path.
   macOS first (fastest indexing hardware, easiest validation), iOS in the same PR wave because the
   Core is identical and only scheduling glue differs.
5. **Cross-device sync is possible today, with one honest compromise:** Proton has no app-private
   store (§5). Encrypted index shards can sync as ordinary E2EE files in a clearly named,
   user-visible app-data folder — node crypto gives end-to-end encryption for free. XAttr
   (`AdditionalMetadata`) works only at upload time, so it cannot carry backfill. A true
   app-private volume is a Proton feature request (§17).
6. **License red line:** Ente is AGPL-3.0 — clean-room learning only, zero code copying (§4).
   Apple's official MobileCLIP *weights* are research-only (AMLR) — a Stage-0 license spike must
   pick shippable weights before any model is committed (§6, §18).

The design below survives app kills, background expiration, thermal/memory pressure, partial
indexes, model upgrades, and multi-device merges, with no duplicate index rows and no
"index complete" lie — by construction (idempotent keyed upserts + honest coverage accounting,
the same patterns the backup engine already uses).

---

## 2. Current repo architecture fit

Verified directly in the tree (spot-checked after delegated exploration):

- **Module discipline is already exactly what this feature needs.**
  `Packages/ProtonPhotosKit/Package.swift:23` pins `.macOS("26.0"), .iOS("26.0")` — every API this
  design uses (BGContinuedProcessingTask, persistent PhotoKit history, Swift Vision API) is
  available unconditionally. **Zero `#available` checks will be needed.** Core targets build for
  both platforms under `scripts/verify-universal-core.sh` (CORE_TARGETS list); platform adapters
  are enumerated per-OS in the same script. A new `MLSearchCore` slots into CORE_TARGETS; the
  adapter follows the `PhotoLibraryBackupAdapter` precedent (one target, shared verbatim, built for
  both destinations).
- **Canonical identity exists:** `PhotoUID { volumeID, nodeID }`
  (`PhotosCore/PhotosDomain.swift`) is the identity used by the feed, caches, GPS index, and grid.
  The PhotoKit↔Proton mapping lives exclusively in `PhotoLibraryBackupAdapter`
  (`PhotoLibraryCatalog`: `localIdentifier`, `contentFingerprint`, `metadataRevision`).
- **Encrypted-derived-data storage is a solved pattern here:** `MediaByteCache`
  (AES-GCM per blob via `SecureBlobCipher`, per-account 256-bit key in Keychain with
  `WhenUnlockedThisDeviceOnly`, key deleted on sign-out) and `MediaLocationCore`
  (whole-library GPS index as an AES-GCM blob). The embedding store reuses this exact stack.
- **Crawl + checkpoint + resume exist:** `ThumbnailFeedCore` (actor) runs a sequential
  background crawl with `priority`/`sequential` queues, a `lastDemand` nonisolated box so visible
  demand preempts crawl, and `ThumbnailCoverageCheckpointStore`
  (`MediaFeedCore/ThumbnailFeedCore.swift:52`) — an append-only `P/M` log with merge-on-restart.
  The embedding indexer is a second consumer of this pattern, not a new invention.
- **Background execution is already wired** (correcting an earlier internal assumption):
  iOS `BGProcessingTask` id `me.protonphotos.ios.photo-backup.processing`
  (`iOSApp/ProtonPhotosMobileApp.swift:47-89`, `iOSApp/Info.plist:27`), with
  `PhotoLibraryBackupController` documenting the contract at lines 219-241: *"Returns when the pass
  drains or is stopped by the expiration handler via `stopSync()` — every state transition is
  already checkpointed, so expiration simply resumes."* The ML indexer registers a sibling task id
  and reuses the same catch-up-pass shape. macOS: background activity per the same controller
  comment; `NSBackgroundActivityScheduler` is the OS-side hook (§10).
- **Policy injection is the established capability pattern:** `LibraryDatabasePolicy`
  (per-platform mmap/cache/WAL settings, injected from `DriveSDKBridge`), Grid policies,
  `UIKitMemoryConditionsPolicy`, memory-pressure coordinator (`MediaCacheUIKitAdapter`). The
  indexing gates (thermal/power/memory) become one more injected policy — no platform forks in Core.
- **Search UI seam exists:** `TimelineCore/TimelineSearch.swift` already does text + smart-term
  filtering (favorites/video/screenshot/selfie/raw, bilingual) feeding the existing grid.
  Semantic results merge into this path — per the repo invariant, **no new interaction path**:
  results render through the existing GridCore/timeline surfaces on both platforms.
- **SQLite convention:** raw `sqlite3`, WAL, per-account directory
  (`Application Support/ProtonPhotos/<uid>/`), idempotent schema creation, purge on sign-out
  (`ProtonDriveBackendFactory.purgeLocalAccountData`). The index store follows this convention.
- **Concurrency convention:** actors for engines (`ThumbnailFeedCore`, `DriveSDKBridge`),
  `@MainActor` only for observable facades; decode/DB/network never on main. The
  `-disable-dynamic-actor-isolation` flag applies package-wide (Live Photo AVPlayer workaround) —
  no new constraint for us.

**Fit verdict:** every load-bearing subsystem the feature needs — identity, encrypted derived-data
storage, checkpointed crawl, background pass contract, policy injection, search seam — already
exists and is reused, not duplicated. The only genuinely new machinery is the Core ML encoder pair,
the vector store/scorer, and the shard-sync merge logic.

---

## 3. Apple-native API research (with citations)

Verified against the local macOS 26.5 SDK where noted; all availability is met by our
iOS 26/macOS 26 floors.

### 3.1 Vision feature prints — image-only, not the answer
`VNGenerateImageFeaturePrintRequest` (iOS 13+/macOS 10.15+; Swift `GenerateImageFeaturePrintRequest`
iOS 18+): Revision 2 emits a normalized **768-float image embedding**, Euclidean distance via
`computeDistance` (docs: developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest;
revision constants confirmed in the local SDK header). ~1.5 ms/MP measured third-party
(MWM engineering blog). **No text queries — confirmed**: enumerating every
`ImageProcessingRequest` in the macOS 26.5 Vision swiftinterface shows the only new-in-26 requests
are `RecognizeDocumentsRequest` and `DetectLensSmudgeRequest`; nothing text↔image.
**Use:** possible later for similar-image/duplicate facets; not usable for semantic text search.

### 3.2 Text–image joint embeddings — must ship our own CLIP
- **Foundation Models framework** (iOS 26/macOS 26): `LanguageModelSession`/`@Generable` text
  generation only. **Zero occurrences of "embed" in the FoundationModels swiftinterface**
  (local SDK grep; developer.apple.com/documentation/FoundationModels).
- **NaturalLanguage:** `NLEmbedding` (word ~300-d / sentence 512-d) and `NLContextualEmbedding`
  (iOS 17+, 512-d, multilingual BERT-style) are **text-only spaces, not aligned with any image
  space** — unusable as a CLIP text tower (developer.apple.com/documentation/naturallanguage).
- **MobileCLIP / MobileCLIP2** (github.com/apple/ml-mobileclip; machinelearning.apple.com/research/mobileclip2):
  - **Code: MIT** (verified from raw LICENSE). **Weights: Apple ML Research license (AMLR) —
    research-only, explicitly excludes commercial products** (LICENSE_MODELS; HF repos tagged
    `apple-amlr`). **However** huggingface.co/apple/coreml-mobileclip (official Core ML exports +
    an iOS photo-search demo app) is tagged **`apple-ascl`** (Apple Sample Code License,
    permissive). This inconsistency is real; Stage 0 resolves it (§15, §18).
  - Variants (Core ML, iPhone 12 Pro Max, per README): S0 11.4M+42.4M params,
    **1.5 ms image + 1.6 ms text**; S1 2.5+3.3 ms; S2 35.7M+63.4M, 3.6+3.3 ms; B 10.4+3.3 ms.
    **Embedding dim 512** (verified in repo configs), L2-normalized usage, image input 256 px,
    text context length 77. fp16 Core ML sizes ≈ 2 B/param → S0 ≈ 110 MB both towers,
    S2 ≈ 200 MB (estimates).
  - MobileCLIP2 (TMLR Aug 2025): same latency, ~+2.2% zero-shot; S3/S4/L variants are larger-dim.
- **OpenCLIP** (github.com/mlfoundations/open_clip): MIT code, many permissively licensed weights
  (LAION ViT-B/32, 512-d; DFN; SigLIP). Core ML conversion via coremltools is routine.
  Fallback if MobileCLIP weights are not shippable: ViT-B/32-class, ~10–20 ms/image on ANE
  (estimate), ~300 MB fp16 (halvable via palettization).

### 3.3 Core ML deployment
`MLModelConfiguration.computeUnits = .cpuAndNeuralEngine` for indexing (avoids GPU contention with
the Metal grid; developer.apple.com/documentation/coreml/mlcomputeunits). First load compiles/
specializes for ANE and is OS-cached; keep models resident during a batch (WWDC22 10027).
`mlprogram`/`.mlpackage` format; fp16 default; **palettization (≤8-bit) is the ANE-friendly
compression** (coremltools opt guides) — roughly halves the on-disk/in-memory model cost.
`MLModelCollection` is deprecated — ship models in-app or via Background Assets.

### 3.4 Vector search — bring your own (trivially)
**Apple ships no ANN/vector index API** (nothing at WWDC 25/26). Core Spotlight's semantic
`CSUserQuery` (iOS 18+, confirmed in local SDK headers) semantically searches **donated text
attributes** of your items — you cannot insert embedding vectors; it needs Apple Intelligence
devices. Useful later as a *text-facet* complement (captions/OCR), never as the vector engine.
SearchKit is legacy macOS text retrieval. Brute force is the design (§12): 250k × 512-d fp32 is
256 MFLOP — measured SIMD cosine at ~18–27 ns/vector single-core (arXiv 2601.15311) →
**~4.5 ms/query**; `cblas_sgemm`/BNNS matrix-vector is memory-bandwidth-bound:
512 MB fp32 @ 100–200 GB/s (M-series) ≈ 2.5–5 ms; A-series with fp16 storage ≈ 5–13 ms (estimates).

### 3.5 MLX — rejected for this workload
MLX Swift runs on iOS but is **GPU/CPU only (no ANE)**, allocates Metal wired memory against the
jetsam limit, and its strengths (dynamic LLM shapes) are irrelevant to a small static-shape CLIP.
Core ML on ANE is strictly better for battery and for overnight batch work (github.com/ml-explore/mlx).

### 3.6 Background execution
- **`BGProcessingTask`** (iOS): a few minutes of runtime, then the expiration handler fires;
  scheduler favors overnight + charging (+ Wi-Fi if requested). Design contract: checkpointed
  bursts, resume-on-next-window — identical to the existing photo-backup task
  (developer.apple.com/documentation/backgroundtasks/bgprocessingtask).
- **`BGContinuedProcessingTask`** — **new in iOS/iPadOS 26, not macOS** (confirmed 26.0+ via docs):
  user-initiated foreground task that continues after backgrounding with system progress UI and
  user cancel; killed if progress stalls; optional GPU entitlement
  (WWDC25 session 227). **Perfect fit for "Index my library now"** initial indexing UX.
- **macOS:** `NSBackgroundActivityScheduler` (`qualityOfService = .background`, repeats), plus
  plain while-running indexing — macOS has no jetsam-style budget.

### 3.7 Thermal / memory / power guardrails
`ProcessInfo.thermalState` (pause discretionary work at `.serious`, stop at `.critical` — Apple
guidance), `isLowPowerModeEnabled` (defer bulk), `os_proc_available_memory()` (iOS, poll between
batches), `DispatchSource.makeMemoryPressureSource` (drop caches + pause on warning). Foreground
jetsam limits: ~2 GB on 4 GB iPhones (measured community datapoint), ~3–3.5 GB on 6 GB,
~4–5 GB on 8 GB (estimates). A CLIP pipeline (≤200 MB model + one ≤336 px image at a time + int8
score matrix ≤128 MB) fits comfortably with the existing memory-pressure governor in the loop.

### 3.8 PhotoKit (for completeness — indexing does NOT depend on it)
`PHPhotoLibrary.fetchPersistentChanges(since:)` (iOS 16+/macOS 13+) with persistable
`PHPersistentChangeToken` and `persistentChangeTokenExpired` fallback — **already implemented** in
`PhotoLibraryChangeMonitor.swift:81-115`. `PHCloudIdentifier` exists for cross-device PhotoKit
identity, but is **not needed**: our search space is the Proton timeline keyed by `PhotoUID`, not
the local PhotoKit library (§6.2). OCR (`VNRecognizeTextRequest`, ~18 languages;
`RecognizeDocumentsRequest` new in 26 — confirmed in local SDK) and face detection exist for future
facets; **there is no public face-recognition/embedding API** — face identity search would need a
third-party model (future stage, not v1).

---

## 4. Ente findings and the license boundary

**License (verified live 2026-07-07):** `github.com/ente-io/ente` is **AGPL-3.0** — the root
LICENSE is verbatim GNU AGPL v3, no per-directory divergence found. For this proprietary app,
copying any Ente code would obligate AGPL-licensing the combined work; the network clause removes
the SaaS loophole. **Verdict: do not copy a single line. Clean-room learning only.**

### What Ente actually does (clean-room facts, all cited)
- **Model/runtime:** Apple MobileCLIP via ONNX Runtime on all platforms (after TFLite → PyTorch
  Mobile → ggml/clip.cpp history); text encoder quantized ~70% smaller (ente.com/ml).
- **Query math:** **512-d, L2-normalized, dot product, match threshold 0.175**
  (`clipIndexingVersion = 1`) — from `web/packages/new/photos/services/ml/clip.ts`.
- **The crown jewel — encrypted embedding sync:** "Index on one device, use on all devices.
  Indexes are encrypted before syncing" (ente.com/help). Derived ML data is
  **JSON `{face:{…}, clip:{…}}` → gzip → encrypted with the file's own key** (not a separate key
  hierarchy), stored server-side in a generic **"file data" entity** (`type: "mldata"`) keyed by
  fileID, with **optimistic locking via `lastUpdatedAt` (409 on conflict)**, `IsDeleted` tombstones
  reaped by background workers, and **unknown top-level JSON keys preserved on rewrite** (forward
  compatibility) (server `pkg/controller/filedata/`, web `ml-data.ts`).
- **Scheduler:** state machine idle→tick→indexing/fetching, **idle backoff 5 s doubling to 16 min
  cap**, `wakeUp()` coalescing; **liveQ (fresh uploads) + backfill in 200-item batches, 4
  concurrent**; **fetch-before-compute** (ask the server for existing mldata before running the
  model); **permanent vs transient failure split** (>100 MB, >150 MP, 4xx-except-409 = permanent,
  never retried; network = backoff+retry); mobile gates on unmetered network, battery, thermals
  (worker.ts; ente.com/ml).
- **Model upgrades:** remote index `version` < client's pipeline version → discard remote, re-index
  locally. Low-end devices run a **"lite" mode**: consume synced indexes, never compute.
- **Faces:** YOLO5Face-small → alignment → MobileFaceNet embeddings, riding the same encrypted
  mldata blob; user-named clusters are a separate E2EE "person entity".

### The three buckets (acceptance requirement)
- **Can copy:** nothing (AGPL-3.0 vs. closed app). This would change only if the project itself
  went AGPL — not assumed here.
- **Can learn clean-room** (re-implemented from behavior/facts, no code): encrypt derived data
  under the asset's existing key hierarchy; per-file type-tagged derived-data blob with sub-index
  `version` + `client` and unknown-key preservation; fetch-before-compute so one device pays;
  lite-consumer mode; live/backfill dual queue with capped exponential idle backoff; permanent vs
  transient failure classification; version-gated re-index; unmetered+battery+thermal gates.
  Numeric facts (512-d, dot product, 0.175 threshold, batch/backoff constants) are not
  copyrightable and are recorded above.
- **Do not use / not applicable:** Ente's server (we have no derived-data endpoint — §5), their
  libsodium per-file-key crypto (Proton is OpenPGP node-key based), Flutter/web-worker specifics,
  and their exact source in any form.

---

## 5. Proton Drive / SDK storage feasibility

From direct inspection of `Vendor/sdk-swift` (protobuf surface in
`Sources/Generated/proton.drive.sdk.pb.swift` defines the complete operation set):

1. **No app-private store exists. Confirmed by exhaustive enumeration** of every
   `Proton_Drive_Sdk_*Request`: client lifecycle, keys, uploads/downloads (+controllers),
   nodes/trash, thumbnails, devices, photos timeline/duplicates — nothing else. No KV store, no
   derived-data/entity API, no share-creation API. `entityCachePath`/`secretCachePath` in
   `ProtonDriveClientConfiguration.swift` are local caches only.
2. **Reachable roots:** My Files (`GetMyFilesFolderRequest`), the photos volume
   (`ProtonPhotosClient`), and **Devices** (`ProtonDriveClient.swift:502-594`:
   `createDevice(name:type:)`, `enumerateDevices`, each with a `rootFolderUid`). `DeviceType` is
   only `windows|macOS|linux` — Devices render as the user-visible "Computers" section in all
   Proton clients (proton.me/support docs). **Conclusion: any app storage we create is
   user-visible** — either a My Files subfolder or a Computers entry. "Hidden" is not on offer.
3. **XAttr:** `AdditionalMetadata { name, utf8JsonValue }`
   (`Vendor/sdk-swift/Sources/Plumbing/PublicTypes.swift:113`) is accepted on file/photo/revision
   uploads and read back via `FileRevision.additionalClaimedMetadata`. The
   `Proton_Drive_Sdk_EncryptedField` enum lists `nodeExtendedAttributes` — **XAttr is E2EE under
   the node key**. **Hard limitation: write-at-upload-only.** There is no standalone
   update-XAttr request; mutating metadata means uploading a new revision. Therefore XAttr can
   carry embeddings **for new uploads going forward** but is **unusable for backfilling** an
   existing library (250k new revisions is a non-starter) and awkward for model upgrades.
4. **Transport:** upload is file-URL-only in the Swift wrapper (`UploadsManager.swift:190`;
   the interop-level stream request is not exposed); all HTTP flows through the app-implemented
   `HttpClientProtocol` with in-process streaming — **structurally incompatible with background
   `NSURLSession`**. Shard sync is therefore **foreground-only**, like everything else in this app.
   Revisions exist (`uploadNewRevision`), which is exactly what per-device shard files need.
5. **Fallback design (required by the constraints):** a clearly named, user-visible folder —
   recommendation: **My Files → `Proton Photos – Search Index (do not delete)`** containing a
   `README.txt` (localized, plain language per the copy rule) explaining what it is, that deleting
   it only forces devices to re-index, and that its contents are E2EE and useless to anyone else.
   In-app: Settings shows the folder's role; deletion is detected (enumeration returns no manifest)
   and handled as a clean re-bootstrap, never an error spiral. A Devices/"Computers" entry was
   considered and rejected: `DeviceType` has no honest value for iPhone/iPad, and Computers implies
   a sync-folder mental model we'd be abusing.
6. **Is encrypted shard sync safe through today's APIs? Yes.** Shard files uploaded as ordinary
   files get Proton's node-key E2EE for free — the server sees ciphertext blobs with encrypted
   names. Same-account devices can decrypt them via the normal key hierarchy. We additionally
   gzip the payload and keep the format self-describing (§9). No plaintext embedding, metadata,
   or query ever leaves the device (§11) — constraint satisfied.
7. **True app-private storage remains a feature request** (§17).

---

## 6. Recommended architecture

### 6.1 Module shape — yes to the proposed split, with one precision

```
Packages/ProtonPhotosKit/Sources/
  MLSearchCore/            ← pure; deps: PhotosCore (+ MediaFeedCore protocol types if needed)
    SemanticIndexStore     (SQLite metadata + encrypted vector shards)
    SemanticQueryEngine    (query orchestration, ranking, thresholding, result mapping)
    VectorScorer           (protocol + PureSwiftSIMDScorer default; Accelerate impl injected)
    IndexingPlanner        (work selection: live vs backfill queues, failure classes, epochs)
    IndexGovernor          (gate state machine over injected signals: thermal/power/memory/demand)
    IndexCoverage          (honest progress accounting; checkpoint store reuse)
    ShardCodec + ShardMerge(sync format encode/decode, LWW merge, tombstones, validation)
    Protocols: ImageEmbeddingEncoder, TextQueryEncoder, IndexPixelSource,
               ShardTransport, IndexSchedulingHooks, MLSearchPolicy
  MLSearchAppleAdapter/    ← imports CoreML, Vision, Accelerate; NO UIKit/AppKit/SwiftUI/SDK.
                             Shared VERBATIM on both platforms (PhotoLibraryBackupAdapter precedent)
    CLIPImageEncoder, CLIPTextEncoder (Core ML, .cpuAndNeuralEngine, resident-per-batch)
    AccelerateVectorScorer (cblas_sgemm / BNNS fp16)
    MLModelProvisioner     (model file location, compile cache, epoch→model mapping)
  SearchFeature (or extend TimelineFeature/TimelineUIKitFeature)
                           ← thin UI only: query field, result routing into the EXISTING grid
```

Platform glue (not new targets): iOS registers `me.protonphotos.ios.ml-index.processing`
(BGProcessingTask) + BGContinuedProcessingTask for user-initiated initial indexing, in
`iOSApp/ProtonPhotosMobileApp.swift` beside the existing backup task; macOS adds an
`NSBackgroundActivityScheduler` in `App/` glue. Both call the same Core entry point
(`runIndexCatchUpPass()`), mirroring `PhotoLibraryBackupController`'s documented
checkpoint-and-resume contract (lines 219-241).

Precision vs. the question as posed: the platform-specific pieces are **not** UIKit/AppKit
adapters for ML — Core ML and Accelerate are identical on both platforms, so the encoder/scorer
adapter is **one shared target**. The genuinely per-platform code is (a) scheduler registration
glue in the app targets and (b) the search UI entry points, which reuse the existing
timeline/grid feature adapters. This is *less* platform code than the question anticipated, and
it satisfies "no duplicated feature logic per platform" maximally.

`verify-universal-core.sh` gains `MLSearchCore` in CORE_TARGETS and `MLSearchAppleAdapter` in both
platform adapter lists. New architecture gate tests: MLSearchCore imports no CoreML/Vision/
UIKit/AppKit/SDK; adapter imports no UI frameworks.

### 6.2 Canonical asset identity — decision

**Canonical key: `PhotoUID` (volumeID + nodeID). Provenance fields: active revision UID + model
epoch + pixel-source tier.** Rationale:

- The searchable surface *is* the Proton timeline; every existing subsystem (feed, caches, GPS
  index, grid) is keyed by `PhotoUID`. Introducing a second identity would violate the
  shared-once rule.
- PhotoKit `localIdentifier`/`PHCloudIdentifier` are rejected as canonical: they exist only on the
  backup source device, don't cover macOS folder-synced or web-uploaded assets, and the
  PhotoKit↔Proton mapping already lives (only) in `PhotoLibraryBackupAdapter`.
- Content hash is rejected as canonical (it's dedupe evidence, not identity — the backup engine
  already treats it that way) but the **revision UID** is recorded per embedding row so an edited
  photo (new revision) is detected and re-embedded, and so shard validation (§9) can prove an
  embedding belongs to the same bytes lineage.
- Live Photos: one index row for the still asset (`relatedVideoID` stays a viewer concern).
  Bursts: one row per asset. Videos: poster-frame embedding v1 (§13).

### 6.3 Model family — decision

**First: MobileCLIP-class S2 (512-d, image input 256 px), Core ML, ANE.** Order of preference
pending the Stage-0 license spike:
1. Apple's official Core ML exports (huggingface.co/apple/coreml-mobileclip) **iff** the
   `apple-ascl` tagging is confirmed to cover the weights for shipping use;
2. else a permissively licensed MobileCLIP-architecture reproduction or **OpenCLIP ViT-B/32/DFN**
   checkpoint converted with coremltools (MIT code, permissive weights).

Why not Vision feature prints first: no text queries, period (§3.1). Why not S0: S2 is
3.6 ms vs 1.5 ms per image — both negligible against decode I/O — and measurably better retrieval;
model size (~200 MB fp16 → ~100 MB palettized, estimate) is acceptable on our 26-era floors. The
text tower ships in-app either way (~60–130 MB fp16 depending on variant; palettize).
Ente's production experience independently validates the MobileCLIP + 512-d + dot-product choice (§4).

### 6.4 Query path

text → `CLIPTextEncoder` (~3 ms ANE) → normalized 512-d → `VectorScorer` over the resident epoch
matrix (~5–15 ms @250k) → threshold (~0.2 start, tune; Ente ships 0.175) → ranked `[PhotoUID]` →
merged into `TimelineSearch` results (semantic section ∪ existing smart-term/text matches) →
existing grid rendering. Queries never leave the device; nothing is logged.

---

## 7. Core module / API sketch (signatures, not code)

```swift
// MLSearchCore — all Sendable, no platform imports

public struct EmbeddingRecord {
  let uid: PhotoUID; let epoch: ModelEpoch; let revisionUID: String
  let vector: EmbeddingVector          // fp16-packed storage, normalized
  let pixelTier: PixelTier             // .thumb320 | .preview | .frame(video)
  let indexedAt: Int64; let deviceID: DeviceInstallID
}
public struct ModelEpoch: Hashable { let id: String; let dim: Int; let family: String }

public protocol ImageEmbeddingEncoder: Sendable {
  var epoch: ModelEpoch { get }
  func embed(_ pixels: DecodedImageBuffer) async throws -> EmbeddingVector   // off-main
}
public protocol TextQueryEncoder: Sendable {
  var epoch: ModelEpoch { get }
  func embed(_ query: String) async throws -> EmbeddingVector
}
public protocol IndexPixelSource: Sendable {   // implemented over ThumbnailFeedCore/MediaByteCache
  func decodedPixels(for uid: PhotoUID, minEdge: Int) async throws -> DecodedImageBuffer?
}
public protocol VectorScorer: Sendable {
  func topK(_ query: EmbeddingVector, in matrix: ScoreMatrix, k: Int, threshold: Float) -> [ScoredUID]
}
public protocol ShardTransport: Sendable {     // implemented over ProtonDriveBackend upload/download
  func listShards() async throws -> [ShardDescriptor]
  func fetch(_ d: ShardDescriptor) async throws -> Data          // ciphertext handled by node crypto
  func publish(_ shard: EncodedShard, replacing: ShardDescriptor?) async throws
}

public actor SemanticSearchEngine {            // the one orchestrator
  init(store: SemanticIndexStore, encoder: ImageEmbeddingEncoder, text: TextQueryEncoder,
       pixels: IndexPixelSource, scorer: VectorScorer, governor: IndexGovernor,
       transport: ShardTransport?, policy: MLSearchPolicy, clock: any Clock<Duration>)
  public func runIndexCatchUpPass() async -> IndexPassOutcome    // BG-window entry; checkpointed
  public func noteTimelineDiff(_ diff: TimelineDiff)             // inserts/deletes/revision changes
  public func search(_ text: String, limit: Int) async throws -> SemanticSearchResult
  public func coverage() async -> IndexCoverageSnapshot          // honest N-of-M per epoch
  public func syncShards() async -> ShardSyncOutcome             // foreground-only, coalesced
}

public struct MLSearchPolicy: Sendable {       // injected per platform, like LibraryDatabasePolicy
  var bulkRequiresExternalPower: Bool          // iOS true (bulk phase), macOS false
  var pauseAtThermal: ThermalLevel             // .serious
  var maxResidentScoreBytes: Int               // e.g. 160 MiB mac / 96 MiB iPhone
  var batchSize: Int; var idleBackoff: BackoffCurve   // 5s → capped, Ente-style
  var allowsCellularShardSync: Bool            // false by default (low-data respect)
}
```

Main-actor surface: a tiny `@MainActor` observable view-model in the feature layer subscribing to
`coverage()` snapshots and publishing results. **Everything else — encode, decode, DB, scoring,
shard codec — is off-main by construction** (actor + nonisolated workers, same as ThumbnailFeedCore).

---

## 8. Storage schema / index design

Per-account directory (convention: `Application Support/ProtonPhotos/<uid>/`):

```
semantic-index-v1.sqlite            ← metadata only (WAL, LibraryDatabasePolicy-injected PRAGMAs)
semantic-vectors/<epochID>/shard-NNN.enc   ← AES-GCM blobs (SecureBlobCipher + Keychain key reuse)
semantic-coverage/<epochID>.log     ← append-only P/M checkpoint log (existing store pattern)
```

SQLite (metadata; no vectors in SQLite — keeps rows tiny and vacuum-free):

```sql
CREATE TABLE embedding_meta(
  volume_id TEXT NOT NULL, node_id TEXT NOT NULL, epoch_id TEXT NOT NULL,
  revision_uid TEXT NOT NULL, pixel_tier INTEGER NOT NULL,
  shard_ordinal INTEGER NOT NULL, shard_slot INTEGER NOT NULL,
  indexed_at INTEGER NOT NULL, device_id TEXT NOT NULL,
  PRIMARY KEY (volume_id, node_id, epoch_id)          -- idempotent upsert = no duplicates, ever
);
CREATE TABLE index_failures(
  volume_id TEXT, node_id TEXT, epoch_id TEXT, class INTEGER,  -- permanent | transient
  attempts INTEGER, last_error TEXT, next_retry_at INTEGER,
  PRIMARY KEY (volume_id, node_id, epoch_id));
CREATE TABLE epoch_state(epoch_id TEXT PRIMARY KEY, dim INTEGER, family TEXT,
  status INTEGER,            -- building | active | draining | retired
  total_target INTEGER, embedded_count INTEGER, updated_at INTEGER);
CREATE TABLE tombstones(volume_id TEXT, node_id TEXT, deleted_at INTEGER,
  PRIMARY KEY(volume_id, node_id));                    -- survives until shard sync propagates
```

Vector shards (local): fixed-slot binary matrices, **4,096 vectors × dim × 2 B (fp16)** ≈ 4 MiB
plaintext per shard at 512-d; header = magic, version, epoch, dim, slot count, slot→(uid,revision)
table. Encrypted per-shard with AES-GCM (same Keychain key + cipher as `MediaByteCache`; key dies
at sign-out, satisfying purge). Slots are append-allocated; a deleted asset's slot is tombstoned
and skipped at load, compacted opportunistically when a shard falls below 50% occupancy.

**Why this hybrid (decision):** SQLite-only BLOB rows measured poorly for bulk matrix loads and
bloat the WAL; flat mmap is incompatible with app-layer encryption; a vector DB/ANN dependency is
unjustified at ≤250k (§3.4). Encrypted fixed-slot shards give O(1) row addressing, sequential
decrypt-and-load into one contiguous score matrix, and clean epoch separation (dimension changes =
new directory, zero migration of old shards).

**Query-time residency:** on first search of a session, decrypt shards → one contiguous fp16 (or
int8-quantized, §12) matrix, registered with the memory-pressure governor; dropped on
warning/critical/background, lazily rebuilt. Decrypt cost ≈ 50–250 ms for the full 250k fp16 set
(hardware AES, estimate) — paid once per search session, not per keystroke; partial results can
stream shard-by-shard on first query.

---

## 9. Sync design — same-account multi-device index sharing

**Carrier:** ordinary E2EE files in the app-data folder (§5.5), one **manifest** plus
**per-device, per-epoch shard files**. Node crypto = transport+at-rest E2EE for free; payloads are
additionally gzipped. Foreground-only (SDK constraint), coalesced (publish at most every N hours
or M new embeddings, on Wi-Fi/unmetered unless user opts in).

```
Proton Photos – Search Index (do not delete)/
  README.txt
  manifest-v1.json                       ← tiny; re-uploaded as new revisions
  <epochID>/dev-<deviceInstallID>.shardpack   ← each device writes ONLY its own file (new revisions)
```

- **No write conflicts by construction:** a device only ever creates/revises its own
  `dev-<id>.shardpack`. The manifest is the only shared-write file; it is advisory (device list,
  epoch list, counts) — losing a manifest race is harmless because readers enumerate the folder
  anyway. This deliberately avoids needing Ente's 409 optimistic-locking (we have no such API).
- **Shardpack format:** header {formatVersion, epoch{id,dim,family}, deviceID, createdAt,
  count} + rows {uid, revisionUID, pixelTier, indexedAt, fp16 vector} + tombstone section
  {uid, deletedAt} — gzipped. Unknown header keys are preserved on rewrite (Ente-learned forward
  compatibility).
- **Merge (in `ShardMerge`, pure + property-tested):** for each `(uid, epoch)` take the row with
  (a) matching current revisionUID if any, else (b) newest `indexedAt`, tiebreak by deviceID;
  tombstone wins over any row older than `deletedAt`. Merge is commutative/associative/idempotent —
  required for out-of-order foreground syncs.
- **Fetch-before-compute (Ente-learned):** the backfill planner consults merged remote coverage
  first; a slower device (iPhone) imports a faster device's (Mac) embeddings instead of computing.
  **Lite-consumer mode** falls out free: a device may run with `indexingEnabled = false` and still
  search. This is the answer to "can a faster device index for slower devices": **yes, safely** —
  same account, same key hierarchy, E2EE end to end.
- **Validation before accepting a foreign row (acceptance requirement):** epoch.id **and** dim
  must match a locally known model epoch (else the rows are parked, not dropped — a newer app
  version may understand them); `uid` must exist in the local timeline (else parked pending
  timeline sync); `revisionUID` must equal the asset's current active revision (else the row is
  stale → re-embed locally). Vector norm sanity-checked (‖v‖≈1) to catch corruption; shard fails
  closed to "ignore file, log, re-enumerate" — never crashes, never poisons the local index.
- **Deletion propagation:** local delete/trash → local slot tombstone + `tombstones` row → included
  in next shardpack revision. Remote tombstone → drop local row. Permanently-deleted-on-server
  assets disappear from the timeline diff anyway, which independently triggers row removal —
  tombstones only accelerate cross-device consistency.
- **Why not XAttr as the sync carrier (decision):** write-at-upload-only (§5.3) cannot backfill an
  existing library and cannot carry re-embeds after model upgrades without new revisions per photo.
  **Kept as a Stage-4 optimization:** devices that upload new photos may attach the embedding in
  `AdditionalMetadata` at upload time, letting other devices skip even the shard round-trip for
  fresh assets.

---

## 10. Background / indexing scheduler design

One state machine in `IndexingPlanner` + `IndexGovernor` (Core), driven by injected signals; the
platforms only *invoke* passes, mirroring the backup engine's contract
(`PhotoLibraryBackupController.swift:219-241`).

**Work sources, priority order:**
1. `liveQ` — assets whose thumbnails just landed in cache (subscribe where the feed marks coverage)
   and fresh uploads; bounded, newest-first.
2. Remote import — merged shard rows not yet local (cheap, I/O-only).
3. Backfill — coverage-log gaps, newest→oldest (matches the thumbnail crawl direction, so pixels
   are usually already cached), batches of `policy.batchSize` (~64).
4. Epoch migration — re-embeds for a new model epoch (lowest priority, §14).

**Gates (all injected, no platform ifs in Core):** pause when thermal ≥ `.serious`; skip bulk when
Low Power Mode; pause + drop score matrix on memory-pressure warning; **yield to user work** via
the same `lastDemand` recency check the feed uses (never compete with visible-thumbnail decode —
anti-jank, §12); bulk phase optionally requires external power on iOS; shard *sync* additionally
requires unmetered network unless opted in (indexing itself needs no network).

**Execution windows:**
- Foreground opportunistic (all platforms): idle ticks with capped exponential backoff
  (5 s → ~16 min, Ente-validated shape), coalesced `wakeUp()` on timeline diff/cache fill.
- iOS/iPadOS: `BGProcessingTask` sibling id for overnight catch-up (charging;
  no network requirement — indexing is local); **BGContinuedProcessingTask for the user-initiated
  initial index** with system progress UI ("Index photos for search" button in Settings).
- macOS: `NSBackgroundActivityScheduler` repeating activity + unrestricted while-running indexing.
- Expiration/kill contract: every batch commits (SQLite upsert + coverage-log append) before the
  next begins; the expiration handler just stops the loop. Resume is positionless — the planner
  re-derives work from durable coverage state, so a killed pass loses at most one batch of compute.

**Failure classes (Ente-learned):** permanent (undecodable pixels, unsupported type) — recorded,
never retried, **counted honestly in coverage as "unindexable"**; transient (cache miss, cipher
locked while device locked, memory pause) — retried with backoff. No infinite retry loops (the
thumbnail-prefetch quarantine lesson from this repo's own history).

---

## 11. Privacy and E2EE risk model

**Threat framing: embeddings are as sensitive as thumbnails.** CLIP embeddings support inversion
and attribute inference well enough to reconstruct scene content, detect people/locations/objects,
and match against known images. Treat every derived artifact (vector, coverage row, tombstone,
query string, OCR text later, face data later) as **content, not metadata**.

| Artifact | At rest | In sync | Notes |
|---|---|---|---|
| Embedding vectors | AES-GCM shards, Keychain key (`WhenUnlockedThisDeviceOnly`), gone at sign-out | Node-key E2EE file content (+gzip) | Never plaintext off-device — constraint satisfied |
| SQLite metadata (uids, revisions, counts) | OS file protection + per-account dir purge | Only inside shardpacks (E2EE) | UIDs are server-known identifiers already |
| Query text | Never persisted, never logged | Never transmitted | Text tower runs locally |
| Model files | Public artifacts, no user data | n/a | Integrity-check on load (size/hash) |
| Coverage/failure logs | Local only | Counts only inside E2EE manifest | No filenames/content in logs |

Residual risks, stated honestly: (a) the app-data folder's **existence, file sizes, and revision
cadence** are visible to the server — sizes correlate with library size; mitigate by fixed-size
shard padding buckets if this is deemed material. (b) A decrypted score matrix lives in RAM during
search sessions — same exposure class as decoded thumbnails; dropped on background/pressure.
(c) Face identity search (future) raises the bar further (biometric-class data) — explicitly out of
v1 scope. (d) No telemetry of any search behavior, ever.

---

## 12. Performance and memory budgets

**Embedding store size** (512-d; vectors only, metadata adds ≤ ~40 MB at 250k):

| Assets | fp32 (2048 B) | fp16 (1024 B) | int8 (512 B + scale) |
|---|---|---|---|
| 20k  | 41 MB  | 20.5 MB | 10.3 MB |
| 100k | 205 MB | 102 MB  | 51 MB   |
| 250k | 512 MB | 256 MB  | 128 MB  |

**Decision:** store fp16 on disk (quality headroom, canonical for sync); optionally quantize to
int8 at load time for the resident score matrix on constrained devices
(`maxResidentScoreBytes` policy): 250k resident = 256 MB fp16 (fine on Macs/8 GB iPads) or
128 MB int8 (fine on iPhones; recall loss negligible for retrieval — Ente ships quantized).

**Query latency budget (250k, estimates from cited measurements §3.4):** text encode ~3 ms ANE +
matrix scoring 2.5–5 ms (M-series sgemm) / 5–13 ms (A-series fp16) / ~1–4 ms int8 SDOT +
top-k partial sort ~1 ms → **≈ 10–20 ms end-to-end**, comfortably type-ahead capable with light
debouncing. 20k libraries: sub-millisecond scoring.

**Indexing throughput:** ANE encode 1.5–3.6 ms/image (S0/S2, cited) is dominated by pixel I/O:
cached-thumb decrypt+decode ≈ 5–15 ms/asset (estimate; 320 px JPEG-class). Realistic sustained
rate **~40–100 assets/s on Mac, ~25–60/s on iPhone** in gated bursts →

| Library | Pure compute | Realistic wall-clock (opportunistic + overnight) |
|---|---|---|
| 20k  | ~5–13 min  | same session on Mac; ≤1–2 nights on iPhone |
| 100k | ~25–65 min | 1 evening on Mac; 2–4 nights on iPhone |
| 250k | ~1–3 h     | ~1 day on Mac; ~1 week on iPhone — **or minutes of import if a Mac indexed first (§9)** |

**Memory ceiling during indexing:** image tower resident ~70–140 MB fp16 (palettized ~half) + one
256 px buffer + batch bookkeeping ≪ 400 MB total — safe against the ~2 GB worst-case iPhone
foreground limit and trivially safe in BG windows. Text tower loads lazily on first search only.

**Anti-jank rules (hard):** inference on `.cpuAndNeuralEngine` only (never contend with the Metal
grid's GPU); indexing yields to `lastDemand` recency exactly like the crawl; DB writes batched off
main; score-matrix build off main; **nothing in MLSearchCore or the adapter ever touches the main
actor** except the feature layer's published snapshots.

---

## 13. Failure / idempotency model

- **No duplicate index entries — structural:** `PRIMARY KEY (volume_id, node_id, epoch_id)` with
  upsert; shard slots are keyed by the same tuple; shardpack merge is idempotent (§9). Re-running
  any pass, replaying any shard, or double-firing any BG window is a no-op by construction.
- **No "index complete" lie — accounting:** coverage is computed, never asserted:
  `embedded + imported + unindexable(permanent)` vs. the live timeline count **per epoch**. UI
  states (localized plainly, per the copy rule): "Preparing search", "Search ready for N of M
  photos", "Search ready" (only at 100% of indexable), "Search paused (battery/heat)". A timeline
  that grows mid-pass simply moves the target — the state machine has no terminal "done" latch.
- **App kill / BG expiration:** batch-commit-then-continue; recovery = re-derive from
  SQLite + coverage log (the backup engine's proven recovery-first shape). Worst loss: one batch.
- **Partial index UX:** search always runs over what exists, labeled with the coverage line —
  honest partial results beat blocking.
- **Corruption:** shard header/auth-tag failure → drop that shard's rows to "missing", re-embed;
  SQLite corruption → rebuild store from coverage log + shards, else full local re-index (local
  re-index is always a safe, bounded fallback — the library of record is the server).
- **Cipher locked (device locked during BG window):** Keychain key unavailable → pass ends as
  "transient, retry next window" — matches the existing cache's locked behavior (drop/miss,
  no crash).
- **Edits/revisions:** timeline diff shows a new active revision → row's `revisionUID` mismatch →
  re-embed, replacing in place (same PK). Trash → tombstone (search excluded immediately); restore
  → tombstone cleared, row still present if epoch unchanged (no recompute needed — validated by
  revisionUID). Album membership changes: no effect (index is asset-scoped, not album-scoped).
- **Type matrix:** images (incl. RAW/DNG — via their already-decoded thumbnails, no RAW decode) ✓;
  Live Photos — still only ✓; bursts — each member ✓; videos — poster-frame v1, multi-frame
  mean-pool later; sidecars/motion resources — never independently indexed (not visual identity).

---

## 14. Migration / model-upgrade strategy

**Epochs, never in-place.** `ModelEpoch{id, dim, family}` namespaces everything: SQLite rows,
shard directories, shardpacks, coverage logs. Dimension changes (512 → 768) are therefore free.

1. New app version declares epoch `E2` alongside `E1`. `epoch_state`: E2 = `building`,
   E1 = `active`.
2. Epoch migration runs as the lowest-priority work source (§10) — plus fetch-before-compute: any
   same-account device already on E2 supplies rows via shards.
3. **Query routing:** searches use E1 until E2 coverage ≥ E1 coverage (or ≥ 95% of indexable),
   then flip atomically; never mix epochs in one score pass (different spaces — meaningless math).
4. E1 → `draining`: kept until every same-account device's manifest reports E2 ≥ threshold
   (protects lite consumers), then `retired`: shards deleted locally and the device's E1 shardpack
   trashed. Old-epoch shardpacks from stale devices are ignored-but-parked (§9 validation).
5. A device on an older app version simply keeps querying its known epoch — unknown-epoch
   shardpacks are preserved untouched (forward compatibility, Ente-learned).

Model files ship in-app (v1). If size pressure demands on-demand model download later: Background
Assets, with hash pinning (MLModelCollection is deprecated, §3.3).

---

## 15. Staged implementation plan

**Stage 0 — license + feasibility spike (small, decisive).**
Resolve the MobileCLIP weights question (AMLR vs `apple-ascl` Core ML exports) with the actual
license texts; if unshippable, select the OpenCLIP checkpoint. Convert/validate the chosen pair
with coremltools; measure on this Mac + one iPhone: encode ms, model RAM, retrieval sanity on ~500
local images (golden query set). Output: pinned model artifacts + measured numbers replacing the
estimates in §12. **Gate: no model committed to the repo before this.**

**Stage 1 — local semantic search, both platforms (the first shippable slice).**
`MLSearchCore` + `MLSearchAppleAdapter` + store (§8) + planner/governor (foreground opportunistic
only) + `IndexPixelSource` over the cached-thumbnail path + query merged into `TimelineSearch` +
coverage line in Settings. macOS validated first, iOS in the same wave (Core identical; only glue).
verify-universal-core.sh gains the new targets + architecture gates. *Why first:* it is the entire
user-visible feature; sync and BG windows only improve freshness and cost.

**Stage 2 — scheduling depth (iOS windows + governor hardening).**
BGProcessingTask sibling registration; BGContinuedProcessingTask "index now" flow;
`NSBackgroundActivityScheduler` on macOS; thermal/power/memory gates wired to the existing
coordinator; honest pause states in UI.

**Stage 3 — encrypted cross-device sync.**
App-data folder + README + shardpack codec/merge + fetch-before-compute + lite-consumer mode +
tombstone propagation + Settings surface ("This device indexes / uses indexes from your Mac").

**Stage 4 — enrichments (each independently shippable).**
Embedding-at-upload via XAttr for new assets; video multi-frame embeddings; OCR text facet
(`RecognizeTextRequest`) feeding the existing text search; aesthetics re-ranking; Core Spotlight
donation of *text* facets for system-wide search. Face identity search: separate future design
(biometric-class privacy review required).

---

## 16. Test plan

- **Pure-Core unit tests (swift test, `--filter MLSearch`):** store upsert idempotency (replay =
  identical state); coverage accounting honesty (grows/shrinks with timeline, unindexable counted,
  never reports complete early — mirror the repo's existing "honesty" test style); planner state
  machine (gates, backoff, priority order, expiration mid-batch); failure classification
  (permanent never retried, transient capped).
- **Property tests:** `ShardMerge` commutativity/associativity/idempotence over randomized row
  sets + tombstones + epochs; shard codec round-trip incl. unknown-header-key preservation and
  truncated/corrupt input (must park, not crash).
- **Deterministic-encoder integration:** a fake `ImageEmbeddingEncoder` (seeded vectors) drives
  end-to-end index→query→rank assertions without models; fake `ShardTransport` (in-memory) drives
  two-simulated-device sync scenarios: fetch-before-compute, LWW, revision-mismatch re-embed,
  epoch migration flip, folder-deleted re-bootstrap.
- **Scorer correctness:** `AccelerateVectorScorer` vs `PureSwiftSIMDScorer` vs a scalar reference
  ≤ 1e-3 divergence; int8-quantized recall@50 ≥ 0.95 of fp16 on the golden set.
- **Architecture gates (CoreArchitectureGateTests + verify scripts):** MLSearchCore bans
  CoreML/Vision/UIKit/AppKit/SDK imports; adapter bans UI frameworks; no `#available` outside
  adapters; both targets build for both destinations.
- **Retrieval quality harness (Stage 0/1, not CI):** golden query set (~30 queries en+de) over a
  fixed local corpus; precision@10 tracked across model/epoch changes.
- **Performance assertions (local, not CI):** 250k synthetic vectors: query < 50 ms, session
  matrix load < 500 ms, indexing batch never blocks main (main-thread watchdog in debug).
- **Chaos tests:** kill mid-batch (relaunch resumes, no duplicates); Keychain locked (transient);
  memory-pressure signal mid-pass (matrix dropped, search degrades to shard-streaming, no crash).

---

## 17. Proton SDK / API feature requests

1. **App-private storage** — a hidden, per-app E2EE volume/share (or share-creation API with a
   `hidden`/`appData` share type) so derived-data files don't appear in My Files. Removes the §5.5
   compromise entirely.
2. **Derived-data entity API** (Ente-filedata-shaped): per-node type-tagged encrypted blob with
   optimistic locking — would replace shardpacks with per-asset granularity and delete-with-file
   semantics.
3. **Standalone XAttr update** — set `AdditionalMetadata` on an existing revision without
   uploading a new revision; would make XAttr viable for backfill and epoch migration.
4. **Background-transfer-capable SDK transport** — background `NSURLSession` support (out-of-process
   transfers) for shard/thumbnail traffic; today's in-process stream model forces foreground-only
   sync (known SDK ceiling, consistent with the prior sync audit).
5. **Device API: generic/mobile device types** — `DeviceType` today is windows|macOS|linux only;
   an `appData`/generic type would make the Computers section usable honestly by apps.

---

## 18. No-go list (explicit)

1. **No Ente code copying** — AGPL-3.0 vs. closed app; clean-room patterns only (§4).
2. **No Apple MobileCLIP AMLR weights in a shipping build** without the Stage-0 license
   determination landing on a permissive artifact (`apple-ascl` Core ML exports or OpenCLIP).
3. **No plaintext embeddings/metadata/queries off-device, ever** — including "temporary" debug
   uploads and telemetry. Queries are never logged.
4. **No NLEmbedding/NLContextualEmbedding or Foundation Models as the text tower** — wrong/absent
   embedding spaces (§3.2, §3.3).
5. **No Core Spotlight as the vector engine** — text-facet complement only (§3.4).
6. **No MLX for this workload** — no ANE, wired-memory risk (§3.5).
7. **No ANN library / vector-DB dependency** — unjustified below ~1M vectors (§3.4); also keeps
   the dependency-guardrail clean.
8. **No per-photo revision rewrites for backfill** (XAttr misuse) — new-uploads-only (§5.3, §9).
9. **No indexing from full originals** — cached ≥256 px thumbnails/previews are the pixel source;
   no original downloads for indexing, no RAW decoding.
10. **No scattered `#available`** — platform floors are 26.0; variation goes through injected
    policies/adapters only, enforced by gate tests.
11. **No ML work on the main actor; no GPU compute units during indexing** (Metal grid owns the GPU).
12. **No "index complete" claims from state flags** — coverage is always computed (§13).
13. **No duplicated per-platform feature logic** — one Core, one shared Apple adapter, thin glue;
    the verify scripts enforce it.
14. **No new interaction paths for results** — semantic search feeds the existing
    TimelineSearch/grid/selection/share/trash paths (repo invariant #2).

---

*Report authored by the T5 orchestrator (Fable) from three delegated research passes (repo
exploration, Apple SDK/API verification, Ente + Proton SDK research), with load-bearing repo claims
re-verified directly (`Package.swift:23`, `ThumbnailFeedCore.swift:52`,
`PhotoLibraryChangeMonitor.swift:81-115`, `PublicTypes.swift:113`,
`ProtonPhotosMobileApp.swift:47-89`, `Info.plist:27`). Read-only: no source files were modified.*
