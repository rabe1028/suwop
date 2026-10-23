# EmbeddingGemma 2 on Core ML (feasibility spike)

Goal: replace the LiteRT-LM binary dependency with Core ML, a system framework.
The spike converts the pinned upstream checkpoint (`google/embeddinggemma-2`,
Apache-2.0, revision in `convert.py`) and measures parity, retrieval, size and
memory. The app does not use these models yet.

## Result

Feasible. Measurements are in `docs/evidence/coreml-20261024/`.

- Image vectors go through the text encoder: vision tower → 70 soft tokens →
  the same 24-layer encoder as text → mean pooling → 768 dimensions. Four models
  cover both paths: `vision-encoder`, `vision-head`, `tokens` and `encoder`.
- fp32 matches transformers exactly. The model card warns against fp16: the vision
  pooling and standardization reach ~2·10⁴, and the following RMSNorm squares them
  past the fp16 range. Splitting that head into a tiny fp32 model fixes it; the
  vision encoder's residual stream stays below ~1,100 and runs in fp16.
- On the Neural Engine, int8 weights reach cosine ≥ 0.999 (images) and ≥ 0.9999
  (text) against float32 transformers. The current LiteRT-LM output is 0.97 / 0.99.
  6-bit palettes (iOS 17 allows per-tensor only) give ≥ 0.992 at 317 MB; 4-bit
  is too lossy.
- Retrieval on 1,000 COCO photos is not significantly different from LiteRT-LM.
- With tokens on the CPU, peak memory footprint was 142 MB, against ~950 MiB RSS
  for LiteRT-LM. Latency was ~110 ms per image and ~8 ms per query, against ~0.7 s
  per image for LiteRT-LM on CPU (M1 Max).

Blocking issues before integration:

- Neural Engine model loading took ~43 s on every process start of the CLI
  benchmark. Device behaviour, and whether iOS caches the compiled plan per app,
  is unmeasured.
- fp16 models computed on the CPU are corrupted (image cosine 0.63–0.70). Request
  `.cpuAndNeuralEngine`, and fall back to fp32 models or decline when it is
  unavailable; never `.all` with silent CPU execution.
- The app needs a Gemma tokenizer and the image preprocessing (aspect-preserving
  resize to ≤ 630 16-pixel patches, 3×3-poolable, patch order and positions)
  without Python. Both must match transformers token-for-token and patch-for-patch.
- The converted models would need hosting at a pinned, checksummed URL, as the
  LiteRT model has today. Switching models changes model identity, so every photo
  is embedded again.

## Reproduce

```bash
uv venv .venv --python 3.12
uv pip install --python .venv/bin/python -r requirements.txt
.venv/bin/python convert.py out /path/to/coco.jpg int8 pal6
.venv/bin/python evaluate.py parity out int8 ../embedding-evaluation/results/manifest-smoke.json
.venv/bin/python evaluate.py embed out int8 ../embedding-evaluation/results/manifest-1000.json raw.json
uv run --no-project --with numpy python ../embedding-evaluation/quantization.py raw.json
```

Set `EMBEDDINGGEMMA2_ROOT` to an existing local copy of the pinned revision to skip
the 1.5 GB download. `convert.py` patches one coremltools 9.0 cast conversion for
torch 2.14 at import. For `Bench.swift`, compile models with
`xcrun coremlcompiler compile`, dump preprocessed fixtures as raw little-endian
arrays (`pixels<i>.bin` float32 [1,630,768], `positions<i>.bin` int32 [1,630,2],
`image_ids<i>.bin` and `text_ids<i>.bin` int32), then run
`swiftc -O Bench.swift -o bench && ./bench <compiled> int8 <inputs> ane`.
