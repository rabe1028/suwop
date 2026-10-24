"""Convert EmbeddingGemma 2 (text + vision) into the four Core ML models the app bundles.

VisionEncoder: 630 patches and positions -> encoder hidden states (fp16, Neural Engine).
VisionHead:    pooling, standardization and projection (fp32; values exceed fp16).
Tokens:        token IDs -> scaled token embeddings (CPU; a 262,144-row gather).
Encoder:       embeddings and mask -> mean-pooled 768-dimensional vector (fp16).
Weights are int8. Output is deterministic; `--verify` compares it to the identity the
Rust core pins. Usage: convert.py <output-dir> [--verify <sha256>]
"""

import argparse
import hashlib
import os
import tempfile
from pathlib import Path

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch
from coremltools.converters.mil import Builder
from coremltools.converters.mil.frontend.torch import ops
from coremltools.proto import Model_pb2
from huggingface_hub import snapshot_download
from PIL import Image
from sentence_transformers import SentenceTransformer
from transformers import AutoModel

REPOSITORY = "google/embeddinggemma-2"
REVISION = "914f7f89142e33e77833254d9c9b90c3cef7303b"
LENGTH = 128  # Text tokens; also covers 70 image soft tokens plus four markers.
SOFT_TOKENS = 70
MASKED = -3.0e4  # Additive attention mask that stays finite in fp16.
MODELS = ("VisionEncoder", "VisionHead", "Tokens", "Encoder")


def _cast(context, node, dtype, dtype_name):
    """coremltools 9.0 expects scalars where torch 2.14 traces one-element arrays."""
    x = ops._get_inputs(context, node, expected=1)[0]
    if not (len(x.shape) == 0 or np.all([d == 1 for d in x.shape])):
        raise ValueError("input to cast must be either a scalar or a length 1 tensor")
    if x.can_be_folded_to_const():
        value = x.val.item() if isinstance(x.val, np.ndarray) else x.val
        result = Builder.const(val=dtype(value), name=node.name)
    elif len(x.shape) > 0:
        squeezed = Builder.squeeze(x=x, name=node.name + "_item")
        result = Builder.cast(x=squeezed, dtype=dtype_name, name=node.name)
    else:
        result = Builder.cast(x=x, dtype=dtype_name, name=node.name)
    context.add(result, node.name)


ops._cast = _cast


class VisionEncoder(torch.nn.Module):
    def __init__(self, tower):
        super().__init__()
        self.tower = tower

    def forward(self, pixel_values, position_ids):
        padding = (position_ids == -1).all(dim=-1)
        hidden = self.tower.patch_embedder(pixel_values, position_ids, padding)
        # Built here because transformers' mask helpers do not convert.
        mask = torch.where(padding, MASKED, 0.0)[:, None, None, :].to(hidden.dtype)
        rotary = self.tower.encoder.rotary_emb(hidden, position_ids)
        for layer in self.tower.encoder.layers:
            hidden = layer(
                hidden, attention_mask=mask, position_embeddings=rotary, position_ids=position_ids
            )
        return hidden


class VisionHead(torch.nn.Module):
    def __init__(self, tower, embedder):
        super().__init__()
        self.tower, self.embedder = tower, embedder

    def forward(self, hidden, position_ids):
        padding = (position_ids == -1).all(dim=-1)
        pooled, _ = self.tower.pooler(
            hidden_states=hidden,
            pixel_position_ids=position_ids,
            padding_positions=padding,
            output_length=SOFT_TOKENS,
        )
        if self.tower.config.standardize:
            pooled = (pooled - self.tower.std_bias) * self.tower.std_scale
        return self.embedder(pooled)


class Encoder(torch.nn.Module):
    def __init__(self, language_model):
        super().__init__()
        self.lm = language_model

    def forward(self, inputs_embeds, mask):
        lm = self.lm
        per_layer = lm.ple(inputs_embeds)
        positions = torch.arange(LENGTH).unsqueeze(0)
        # Sliding windows exceed LENGTH, so every layer uses the same bidirectional mask.
        additive = torch.where(mask > 0, 0.0, MASKED)[:, None, None, :]
        rotary = {
            kind: lm.rotary_emb(inputs_embeds, positions, kind) for kind in lm.unique_layer_types
        }
        hidden = inputs_embeds
        for i, layer in enumerate(lm.layers):
            kind = lm.config.layer_types[i]
            hidden = layer(
                hidden,
                per_layer[:, :, i, :],
                attention_mask=additive,
                position_embeddings=rotary[kind],
            )
        hidden = lm.embedding_projection(lm.norm(hidden))
        weights = mask.unsqueeze(-1)
        return (hidden * weights).sum(1) / weights.sum(1)


class Tokens(torch.nn.Module):
    def __init__(self, table):
        super().__init__()
        self.table = table

    def forward(self, input_ids):
        return self.table(input_ids)


def sample_features(root):
    """Trace inputs from a fixed synthetic image; traced graphs depend only on shapes."""
    st = SentenceTransformer(root, model_kwargs={"torch_dtype": torch.float32}, device="cpu")
    st[0].processor.image_processor.max_soft_tokens = SOFT_TOKENS
    st[0].processor.image_seq_length = SOFT_TOKENS
    gradient = np.add.outer(np.arange(336), np.arange(448)) % 256
    pixels = np.stack([gradient, gradient[::-1], (gradient * 3) % 256], axis=-1)
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "sample.png"
        Image.fromarray(pixels.astype(np.uint8)).save(path)
        features = st.preprocess([{"image": str(path)}])
    return features["pixel_values"].float(), features["image_position_ids"].int()


def convert(module, examples, inputs, output, precision, path, quantize):
    traced = torch.jit.trace(module.eval(), examples, check_trace=False)
    model = ct.convert(
        traced,
        inputs=inputs,
        outputs=[ct.TensorType(name=output, dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=precision,
        convert_to="mlprogram",
    )
    if quantize:
        op = cto.OpLinearQuantizerConfig(mode="linear_symmetric", weight_threshold=2048)
        model = cto.linear_quantize_weights(model, config=cto.OptimizationConfig(global_config=op))
    # Conversion dates would make otherwise identical output differ.
    metadata = model.user_defined_metadata
    for key in list(metadata.keys()):
        if key.endswith("conversion_date"):
            del metadata[key]
    model.save(str(path))
    # Protobuf map order varies between runs; rewrite the spec deterministically.
    spec_path = path / "Data" / "com.apple.CoreML" / "model.mlmodel"
    spec = Model_pb2.Model()
    spec.ParseFromString(spec_path.read_bytes())
    spec_path.write_bytes(spec.SerializeToString(deterministic=True))


def identity(directory):
    """SHA-256 over each package's model spec and weights; Manifest.json holds random IDs."""
    digest = hashlib.sha256()
    for name in MODELS:
        package = directory / f"{name}.mlpackage"
        for file in sorted(package.rglob("*")):
            if file.is_file() and file.name != "Manifest.json":
                digest.update(str(file.relative_to(directory)).encode())
                digest.update(hashlib.sha256(file.read_bytes()).digest())
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--verify", help="expected identity from the Rust inference spec")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    local = os.environ.get("EMBEDDINGGEMMA2_ROOT")
    root = local or snapshot_download(REPOSITORY, revision=REVISION)
    model = AutoModel.from_pretrained(root, dtype=torch.float32, attn_implementation="eager").eval()
    pixels, positions = sample_features(root)
    tower, lm = model.vision_tower, model.language_model
    fp16, fp32 = ct.precision.FLOAT16, ct.precision.FLOAT32
    vision_inputs = [
        ct.TensorType(name="pixel_values", shape=pixels.shape, dtype=np.float32),
        ct.TensorType(name="position_ids", shape=positions.shape, dtype=np.int32),
    ]
    out = args.output
    convert(
        VisionEncoder(tower),
        (pixels, positions),
        vision_inputs,
        "hidden",
        fp16,
        out / "VisionEncoder.mlpackage",
        quantize=True,
    )
    with torch.no_grad():
        hidden = VisionEncoder(tower)(pixels, positions.long())
    head_inputs = [
        ct.TensorType(name="hidden", shape=hidden.shape, dtype=np.float32),
        ct.TensorType(name="position_ids", shape=positions.shape, dtype=np.int32),
    ]
    head = VisionHead(tower, model.embed_vision)
    convert(
        head,
        (hidden, positions),
        head_inputs,
        "soft_tokens",
        fp32,
        out / "VisionHead.mlpackage",
        quantize=False,
    )
    embeds, mask = torch.zeros(1, LENGTH, lm.config.hidden_size), torch.ones(1, LENGTH)
    encoder_inputs = [
        ct.TensorType(name="inputs_embeds", shape=embeds.shape, dtype=np.float32),
        ct.TensorType(name="mask", shape=mask.shape, dtype=np.float32),
    ]
    convert(
        Encoder(lm),
        (embeds, mask),
        encoder_inputs,
        "embedding",
        fp16,
        out / "Encoder.mlpackage",
        quantize=True,
    )
    ids = torch.zeros(1, LENGTH, dtype=torch.int32)
    token_inputs = [ct.TensorType(name="input_ids", shape=ids.shape, dtype=np.int32)]
    convert(
        Tokens(lm.embed_tokens),
        (ids,),
        token_inputs,
        "inputs_embeds",
        fp16,
        out / "Tokens.mlpackage",
        quantize=True,
    )
    actual = identity(out)
    print(actual)
    if args.verify and args.verify != actual:
        raise SystemExit(f"Converted models do not match the pinned identity {args.verify}")


if __name__ == "__main__":
    main()
