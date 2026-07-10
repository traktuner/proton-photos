# Smart Search — Runtime & Model Status (2026-07-10)

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
