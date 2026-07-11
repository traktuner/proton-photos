"""Convert the pinned SigLIP2 model into one reproducible Core ML distribution."""

import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import shutil
import subprocess

import coremltools as ct
import numpy as np
from PIL import Image
import torch
from transformers import AutoModel, AutoTokenizer


MODEL_NAME = "google/siglip2-base-patch16-256"
REVISION = "3f9f96cb90da5dbc758b01813f2f6f1aee24c1ab"
CONTEXT_LENGTH = 64
TEXT_PARITY_MIN_COSINE = 0.999
IMAGE_PARITY_MIN_COSINE = 0.999
POOLING_HEAD_MAX_DELTA = 1e-4

FIXTURE_TEXTS = [
    "a photo of trees",
    "Bäume",
    "a photo of a beach",
    "Strand",
    "a photo of a dog",
    "Hund",
    "a photo of a car",
    "Auto",
    "a photo of people",
    "Menschen",
    "a photo of food",
    "Essen",
    "a photo of a mountain",
    "Berg",
    "a photo of a sunset",
    "Sonnenuntergang",
    "Ein Foto von Bäumen im Wald",
    "the quick brown fox jumps over the lazy dog 1234!?",
    "école Zürich straße",
    "",
]


def patch_pooling_head(model):
    """Replace MultiheadAttention with equivalent traceable tensor operations."""
    import types

    head = model.vision_model.head
    num_heads = model.config.vision_config.num_attention_heads
    embed_dim = model.config.vision_config.hidden_size
    head_dim = embed_dim // num_heads
    scale = float(head_dim) ** 0.5

    def manual_forward(self, hidden_state):
        weights = self.attention.in_proj_weight
        bias = self.attention.in_proj_bias
        query = self.probe @ weights[:embed_dim].T + bias[:embed_dim]
        key = hidden_state @ weights[embed_dim : 2 * embed_dim].T + bias[embed_dim : 2 * embed_dim]
        value = hidden_state @ weights[2 * embed_dim :].T + bias[2 * embed_dim :]

        def split(tensor):
            return tensor.reshape(1, -1, num_heads, head_dim).transpose(1, 2)

        query, key, value = split(query), split(key), split(value)
        attention = torch.softmax((query @ key.transpose(-1, -2)) / scale, dim=-1)
        pooled = (attention @ value).transpose(1, 2).reshape(1, -1, embed_dim)
        pooled = pooled @ self.attention.out_proj.weight.T + self.attention.out_proj.bias
        residual = pooled
        pooled = self.layernorm(pooled)
        return (residual + self.mlp(pooled))[:, 0]

    head.forward = types.MethodType(manual_forward, head)


class ImageTower(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, pixel_values):
        return self.model.get_image_features(pixel_values=pixel_values)


class TextTower(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_ids):
        return self.model.get_text_features(input_ids=input_ids)


def cosine(lhs, rhs):
    lhs = np.asarray(lhs, dtype=np.float32).reshape(-1)
    rhs = np.asarray(rhs, dtype=np.float32).reshape(-1)
    return float(np.dot(lhs, rhs) / (np.linalg.norm(lhs) * np.linalg.norm(rhs)))


def export_tokenizer(tokenizer, destination: Path):
    sentence_piece = tokenizer.sp_model
    pieces = [
        {"piece": sentence_piece.id_to_piece(index), "score": sentence_piece.get_score(index)}
        for index in range(sentence_piece.get_piece_size())
    ]
    document = {
        "type": "sentencepiece-bpe",
        "model": MODEL_NAME,
        "revision": REVISION,
        "context_length": CONTEXT_LENGTH,
        "pad_id": tokenizer.pad_token_id,
        "bos_id": tokenizer.bos_token_id,
        "eos_id": tokenizer.eos_token_id,
        "unk_id": sentence_piece.unk_id(),
        "add_bos": bool(getattr(tokenizer, "add_bos_token", False)),
        "add_eos": bool(getattr(tokenizer, "add_eos_token", False)),
        "lowercase": True,
        "pieces": pieces,
    }
    (destination / "tokenizer.json").write_text(
        json.dumps(document, ensure_ascii=False, separators=(",", ":")), encoding="utf-8"
    )

    fixtures = []
    for text in FIXTURE_TEXTS:
        encoded = tokenizer(
            text.lower(), padding="max_length", max_length=CONTEXT_LENGTH, truncation=True
        )
        fixtures.append({"text": text, "input_ids": encoded["input_ids"]})
    (destination / "tokenizer-fixtures.json").write_text(
        json.dumps(
            {"context_length": CONTEXT_LENGTH, "fixtures": fixtures},
            ensure_ascii=False,
            separators=(",", ":"),
        ),
        encoding="utf-8",
    )


def sha256_file(path: Path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def distribution_files(root: Path):
    return sorted(path for path in root.rglob("*") if path.is_file() and path.name != "artifact-manifest.json")


def write_manifest(distribution: Path, measurements):
    packages = ["coremltools", "numpy", "Pillow", "torch", "transformers", "sentencepiece"]
    manifest = {
        "schema_version": 1,
        "model": MODEL_NAME,
        "revision": REVISION,
        "minimum_deployment_target": "iOS18",
        "tools": {package: importlib.metadata.version(package) for package in packages},
        "measurements": measurements,
        "files": [
            {
                "path": str(path.relative_to(distribution)),
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
            }
            for path in distribution_files(distribution)
        ],
    }
    manifest_path = distribution / "artifact-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")


def convert(output: Path):
    work = output / "work"
    distribution = output / "distribution"
    shutil.rmtree(work, ignore_errors=True)
    shutil.rmtree(distribution, ignore_errors=True)
    work.mkdir(parents=True)
    distribution.mkdir(parents=True)

    model = AutoModel.from_pretrained(
        MODEL_NAME,
        revision=REVISION,
        attn_implementation="eager",
        low_cpu_mem_usage=True,
    ).eval()
    tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME, revision=REVISION, use_fast=False)
    export_tokenizer(tokenizer, work)

    image_size = model.config.vision_config.image_size
    generator = torch.Generator().manual_seed(0x50524F54)
    image_example = torch.rand(1, 3, image_size, image_size, generator=generator)
    text_example = torch.zeros(1, CONTEXT_LENGTH, dtype=torch.int32)
    text_example[0, 0] = tokenizer.bos_token_id or 2

    with torch.no_grad():
        original = model.get_image_features(pixel_values=image_example)[0]
    patch_pooling_head(model)
    with torch.no_grad():
        patched = model.get_image_features(pixel_values=image_example)[0]
        pooling_delta = float((original - patched).abs().max())
    if pooling_delta >= POOLING_HEAD_MAX_DELTA:
        raise RuntimeError(f"pooling head parity failed: {pooling_delta}")

    with torch.no_grad():
        image_tower = torch.jit.trace(ImageTower(model).eval(), image_example, strict=False)
        text_tower = torch.jit.trace(TextTower(model).eval(), text_example, strict=False)

    image_model = ct.convert(
        image_tower,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
        inputs=[
            ct.ImageType(
                name="image",
                shape=image_example.shape,
                scale=1.0 / 127.5,
                bias=[-1.0, -1.0, -1.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[ct.TensorType(name="embedding")],
    )
    text_model = ct.convert(
        text_tower,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
        inputs=[ct.TensorType(name="input_ids", shape=text_example.shape, dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding")],
    )

    image_path = work / "image.mlpackage"
    text_path = work / "text.mlpackage"
    combined_path = work / "SigLIP2.mlpackage"
    image_model.save(str(image_path))
    text_model.save(str(text_path))
    descriptor = ct.utils.MultiFunctionDescriptor()
    descriptor.add_function(str(image_path), src_function_name="main", target_function_name="image")
    descriptor.add_function(str(text_path), src_function_name="main", target_function_name="text")
    descriptor.default_function_name = "image"
    ct.utils.save_multifunction(descriptor, str(combined_path))

    sample = tokenizer(
        "a photo of a dog", padding="max_length", max_length=CONTEXT_LENGTH, truncation=True
    )
    input_ids = np.asarray(sample["input_ids"], dtype=np.int32).reshape(1, CONTEXT_LENGTH)
    with torch.no_grad():
        text_reference = TextTower(model)(torch.from_numpy(input_ids)).numpy()[0]
    text_prediction = ct.models.MLModel(str(text_path)).predict({"input_ids": input_ids})["embedding"][0]
    text_cosine = cosine(text_reference, text_prediction)
    if text_cosine < TEXT_PARITY_MIN_COSINE:
        raise RuntimeError(f"text parity failed: {text_cosine}")

    rng = np.random.default_rng(0x50524F54)
    image_bytes = rng.integers(0, 256, size=(image_size, image_size, 3), dtype=np.uint8)
    pil_image = Image.fromarray(image_bytes, mode="RGB")
    normalized = image_bytes.astype(np.float32).transpose(2, 0, 1) / 127.5 - 1.0
    with torch.no_grad():
        image_reference = ImageTower(model)(torch.from_numpy(normalized[None, ...]))[0].numpy()
    image_prediction = ct.models.MLModel(str(image_path)).predict({"image": pil_image})["embedding"][0]
    image_cosine = cosine(image_reference, image_prediction)
    if image_cosine < IMAGE_PARITY_MIN_COSINE:
        raise RuntimeError(f"image parity failed: {image_cosine}")

    subprocess.run(
        ["xcrun", "coremlcompiler", "compile", str(combined_path), str(distribution)],
        check=True,
    )
    shutil.copy2(work / "tokenizer.json", distribution / "tokenizer.json")
    measurements = {
        "pooling_head_max_abs_delta": pooling_delta,
        "text_coreml_torch_cosine": text_cosine,
        "image_coreml_torch_cosine": image_cosine,
    }
    write_manifest(distribution, measurements)
    print(json.dumps({"distribution": str(distribution), **measurements}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    convert(parser.parse_args().output.resolve())
