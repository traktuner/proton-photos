# SigLIP2 Core ML conversion

This tool converts the pinned Apache-2.0
`google/siglip2-base-patch16-256` revision into the Core ML artifact consumed by
Proton Photos Smart Search. Generated weights and test photos must stay outside
the source tree.

```bash
cd Tools/MLModels/SigLIP2
python3 -m venv .venv
.venv/bin/pip install -r requirements.lock
.venv/bin/python convert_siglip2.py /absolute/path/to/output
```

The command writes conversion intermediates under `work/` and the only
installable payload under `distribution/`:

- `SigLIP2.mlmodelc`
- `tokenizer.json`
- `artifact-manifest.json`

Before publishing the distribution, include the Apache-2.0 license and the
upstream model-card attribution with the hosted release. Publish it at an
immutable URL, then add its exact file sizes and SHA-256 values to
`MLModelCatalog.sigLIP2Base256.downloadPlan`.

The recorded environment is Python 3.12.13, macOS 26.5.1 and Xcode 26.6
(17F113). The converter fails when pooling-head, text-encoder, or image-encoder
parity exceeds its fixed tolerance. Run it on Apple silicon with the repository's
Xcode version selected through `xcode-select` or `DEVELOPER_DIR`.
