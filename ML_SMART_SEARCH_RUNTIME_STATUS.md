# Smart Search — Runtime & Model Status (2026-07-10, updated for Stage 2)

## Stage 2 update: multilingual production model + FP16 index

### Model bake-off outcome (Phase 1)

Evaluated from primary sources: sentence-transformers multilingual-v1 (fails: OpenAI image
tower has no weights license, deployed use declared out of scope), M-CLIP (fails: no weights
license at all, XLM-R-Large too big), LAION XLM-R-B/32 (MIT, viable fallback, 512-d),
mSigLIP (Apache-2.0), jina-clip-v2 + NLLB-CLIP/SigLIP (fail: CC-BY-NC), Apple MobileCLIP/2
(fail: AMLR research-only), mexma-siglip2 (MIT but ~1B params).

**Winner: `google/siglip2-base-patch16-256`** — weights Apache-2.0 (redistribution + product
use), pinned revision `3f9f96cb90da5dbc758b01813f2f6f1aee24c1ab`, 375M params (image tower
93M ≈ 186 MB fp16 for bulk indexing on ANE; text tower ≈ 530 MB fp16, loaded per-query only),
768-d, 64-token Gemma SentencePiece(BPE) tokenizer, 256px squash-resize, fully static shapes.

Converted locally (`Tools/MLModels/SigLIP2/convert_siglip2.py`): multi-function CoreML
package (image+text), fp16, 715 MB; the `nn.MultiheadAttention` MAP pooling head is replaced
by numerically identical tensor math before tracing (max |Δ| 1.4e-6); CoreML↔torch text
parity cosine 0.99999. Tokenizer data (`tokenizer.json`) and upstream reference tokenizations
(`tokenizer-fixtures.json`) are exported into the artifact and hash-verified on install.
**Lowercasing is part of the SigLIP text contract** — measured effect on German top-1: 3/8 →
7/8. Text→text similarity is NOT a valid quality metric for sigmoid-trained SigLIP models
(embeddings hub); all quality claims below are text→image.

### Measured quality (real photos, identical Swift CoreML pipeline for both models)

Reference corpus: 22 real Wikimedia photos, 8 concepts (trees, beach, dog, car, people,
food, mountain, sunset), local only, never committed. Swift opt-in tests
(`SigLIP2QualityReferenceTests`, `TinyCLIPQualityReferenceTests`), 2026-07-10:

| Model | EN top-1 | DE top-1 | Notes |
|---|---|---|---|
| TinyCLIP-39M (baseline) | 7/8 | 5/8 | "Bäume", "Menschen", "Berg" miss |
| **SigLIP2-base-256** | **7/8** | **7/8** | "Bäume"→trees HIT; German at English parity |

The Swift SentencePiece **BPE** tokenizer (Gemma vocabularies are `model_type: BPE`, scores
are negative merge ranks — a unigram/Viterbi reading of the same data is wrong and was
caught by the fixtures) reproduces all 20 upstream Python tokenizations exactly, including
umlauts, ß, truncation and the empty string.

`siglip2-base-patch16-256` is a production candidate (Apache-2.0 gates pass); its
`downloadPlan` stays `nil` until release engineering hosts the canonical converted artifact at
an immutable URL. Release selection additionally requires on-device qualification for that exact
artifact revision. Runtime contract
extensions that made this data-driven (no per-model code): optional `endTokenMaskInputName`
(SigLIP pools internally) and preprocessing-derived crop mode (CLIP center-crop vs SigLIP
squash-resize).

### FP16 persistent index (Phase 2)

`SQLiteMLIndexStore` rows are now IEEE-754 binary16 (`MLFloat16Codec`, architecture-
independent bit conversion, round-to-nearest-even verified against hardware `Float16` over
an exhaustive half sweep + 200k random floats). The public API, ranking semantics and the
Float32 in-memory scoring block are unchanged; widening happens once, streamed, on block
load. Schema `user_version` 2→3 resets the ML-only store (derived data — no migration).
Wrong-sized rows are rejected by a byte-count check BEFORE decryption
(`MLVectorCipher.sealedByteCount`).

Measured (20k × 512-d, debug build, structural test `SQLiteMLIndexStoreFP16Tests`):
- Database: **28.1 MB** total (incl. keys/index/WAL overhead) vs 41.9 MB raw Float32 payload
  alone (old format total ≈ 48.6 MB) → **~42% smaller file, exactly 2× smaller payload/I/O**.
- 20k encrypted inserts 4.7 s; full packed-block load (decrypt + fp16→f32 widen) 2.7 s.
- Warm search: one block load per store generation (structurally asserted), zero reloads on
  repeated queries; RAM of the scoring block unchanged by design (Float32).
- Ranking parity vs Float32 reference: every score within 2e-3, well-separated pairs keep
  order, exact ties keep deterministic key order (tested).

---

# Stage 1 status below (2026-07-10, superseded where Stage 2 says otherwise)

Status of the on-device semantic search (Smart Search) after the runtime-finish pass on
`work/ml-smart-search-runtime-finish`. This document records what is REAL, what is legally
blocked, and the measured search quality. Nothing here claims production readiness beyond
what was actually executed.

## What works end-to-end today

- The full pipeline (verified install → CoreML dual-encoder session → chunk-durable indexing
  → encrypted SQLite vector store → ranked semantic query → timeline filtering) runs with a
  locally converted TinyCLIP-39M artifact on macOS, iOS and iPadOS through the ONE shared
  `MLSearchCore` implementation. Platform targets contain only UI and thin Apple adapters.
- Validated against the real artifact via the opt-in tests (see "Reproducing the quality
  measurement"): `optionalRealTinyCLIPRuntimeSmoke` and `optionalCrossLingualTextAlignment`
  pass with `~/Developer/xcode/ProtonPhotos/ml-model-spike.noindex/tinyclip-39m/TinyCLIP.mlmodelc`.
- iOS/iPadOS now have the native `.searchable` timeline search using the exact macOS pipeline:
  `MLSmartSearchQueryCoordinator` (debounced, epoch-guarded) widening the shared
  `TimelineSearch` lexical filter. No second search implementation exists.

## Production model download: BLOCKED (documented blocker)

**Blocker: no legally hosted, immutable CoreML artifact for a product-usable CLIP model exists.**

Verified from primary sources (2026-07-10):

| Model | Weights license | Redistribution | Product use | Hosted CoreML artifact |
|---|---|---|---|---|
| TinyCLIP-ViT-40M-32-Text-19M (LAION-400M) | MIT (Microsoft) | yes | yes | **none** (PyTorch/safetensors only) |
| Apple MobileCLIP-S2 | Apple AMLR (research-only, revocable) | no | no | yes (`apple/coreml-mobileclip`), but AMLR |

Sources:
- TinyCLIP code+weights MIT: <https://github.com/microsoft/Cream/blob/main/TinyCLIP/LICENSE>,
  HF checkpoint `wkcn/TinyCLIP-ViT-40M-32-Text-19M-LAION400M` (`license: mit`, model card links
  the Cream MIT license). HF revision `95ec8197b3f2fe7f747865c61ca556cf0768b2f7` contains only
  `pytorch_model.bin` / `model.safetensors` — no `.mlpackage`/`.mlmodelc` anywhere official.
- MobileCLIP weights AMLR: <https://github.com/apple/ml-mobileclip/blob/main/LICENSE_MODELS>
  ("exclusively for Research Purposes … does not include any commercial exploitation, product
  development or use"). The HF `apple/coreml-mobileclip` metadata still says `apple-ascl` with a
  DEAD `LICENSE_weights_data` link — a stale label from before the 2025 license switch to AMLR;
  the in-repo AMLR LICENSE text (e.g. in `apple/MobileCLIP-S2`) is authoritative.

Consequences enforced IN CODE (not just documented):
- `MLModelCatalogEntry.isDownloadable` requires `allowsRedistribution && allowsProductUse`.
- `MLModelInstaller.install` throws `licenseProhibitsDistribution` for research-only weights —
  a misconfigured download plan cannot fetch a single byte.
- Release builds cannot list/select entries whose license forbids product use
  (`MLModelCatalog.selectableEntries`, lifecycle `isSelectable`). MobileCLIP-S2 stays
  developer-only, local-artifact-install only. No Apple weights are bundled, mirrored or
  auto-downloaded.

**Path to unblock production:** convert TinyCLIP (MIT permits this) with
`ml-model-spike.noindex/convert_tinyclip.py`, host the resulting multi-function `.mlpackage`
at an immutable HTTPS URL, and fill `tinyCLIPVit40M.downloadPlan` with the pinned revision,
SHA-256 and byte sizes. No lifecycle code changes are needed — the plan slots into the catalog.

## Measured search quality (real model, honest numbers)

Cross-lingual text alignment (German query vs English photo-prompt embeddings, TinyCLIP-39M,
2026-07-10, `optionalCrossLingualTextAlignment`): **3/4 concepts aligned.**

```
Bäume  → car=0.780 dog=0.751 beach=0.723 trees=0.722   MISS (trees ranks LAST)
Strand → beach=0.852 …                                  HIT
Hund   → dog=0.901 …                                    HIT
Auto   → car=0.822 …                                    HIT
```

Verdict: TinyCLIP (LAION-400M, English-dominant training) understands frequent German nouns
with English-adjacent distributions ("Strand", "Hund", "Auto") but fails on "Bäume". German
support is PARTIAL. Options, in order of preference, all cross-platform (no per-platform fork):
1. Ship English-first; German queries work lexically (shared `TimelineSearch` date/tag/smart
   tokens are already bilingual) and semantically opportunistically.
2. Evaluate a multilingual CLIP with a product-usable license (e.g. SigLIP2/mSigLIP variants —
   license per checkpoint must be verified from primary sources before any plan is added).
3. Apple-native fallback (Vision `VNClassifyImageRequest` label index) — different quality
   profile, would still flow through the same `MLIndexStore`/ranking as a distinct descriptor.

No decision is baked in; the catalog+contract design makes each a data change plus one adapter.

## Reproducing the quality measurement

```sh
export PROTON_PHOTOS_TINYCLIP_MODEL="$HOME/Developer/xcode/ProtonPhotos/ml-model-spike.noindex/tinyclip-39m/TinyCLIP.mlmodelc"
# optional: real photos named <concept>-*.jpg (concepts: trees, beach, dog, car)
export PROTON_PHOTOS_ML_REFERENCE_CORPUS="$HOME/Pictures/ml-reference-corpus"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path Packages/ProtonPhotosKit \
  --scratch-path ~/Developer/xcode/ProtonPhotos/SPM.noindex \
  --filter "TinyCLIPQualityReference|optionalRealTinyCLIPRuntimeSmoke"
```

`optionalRealPhotoCorpusRanking` additionally verifies end-to-end IMAGE ranking (embeds the
corpus through the real encoder, ranks EN+DE queries, requires every English query to hit its
concept, and prints the German hit rate for documentation). It skips silently without the two
environment variables.

## Manual test steps (developer build)

1. Build & run (macOS or iOS, DEBUG). Settings → enable Smart Search.
2. TinyCLIP has no hosted plan → status shows "not downloadable" and the developer install
   button. Pick `…/ml-model-spike.noindex/tinyclip-39m/` (the folder containing
   `TinyCLIP.mlmodelc`). The security scope is held by the shared controller until copy,
   hash and install complete.
3. Indexing starts in the background (ANE-first, yields to visible thumbnails/thermal/low
   power); progress is shown in Settings.
4. Timeline search field: type "dog", "beach", "Hund", "Strand" — semantic matches widen the
   lexical results, date-ordered. On iOS the search field is in the Photos tab.
5. Sign out → verify no `SmartSearch/` directory remains in the account container and no
   crash/race (the purge awaits the ordered ML shutdown).

## Performance constraints (state after this pass)

- CoreML compute: `.cpuAndNeuralEngine` only (gate-tested; GPU/`cpuOnly` unreachable in release).
- No inference/DB/model copy on MainActor (actors + static install pipeline); the host asset
  provider only snapshots UID arrays on MainActor.
- Indexing yields to visible thumbnail demand, thermal state and Low Power via
  `AppleSmartSearchWorkGate`; chunked (64/commit), crash-durable, idempotent.
- One encoder instance per session; only ONE function (image/text) of the multi-function model
  is resident at a time; memory pressure drops vector blocks + model residency on both platforms.
- Vector store: encrypted (AES-GCM, per-account key), Float32 rows. NOTE: rows are Float32,
  not FP16 — the model OUTPUT is FP16 and is converted on read; switching row storage to FP16
  would halve the store and is a contained follow-up in `SQLiteMLIndexStore`/`MLVectorBlock`.
- Model switch/purge leave nothing behind: store retirement + artifact uninstall are awaited
  and journaled; purge deletes the single Smart Search root after closing SQLite/WAL.
