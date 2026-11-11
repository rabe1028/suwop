# EmbeddingGemma 2 on Core ML (feasibility spike)

The app now bundles models from `scripts/coreml/convert.py` (`make coreml-models`).
This directory is the historical spike; its LiteRT-LM comparisons (`mac-bench`,
`simulator/`) need a checkout from before the switch, when the package still
depended on LiteRT-LM.

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
  is too lossy. These are model-file sizes only: see the specialization cache below.
- Retrieval on 1,000 COCO photos is not significantly different from LiteRT-LM.
- On an M1 Max with the same 20 inputs (`mac-bench/`), int8 on the Neural Engine
  took a median 110 ms per image and 8–9 ms per query, against 498 ms and 87 ms
  for LiteRT-LM. Peak memory footprint was 82 MB against ~305 MB, and maximum RSS
  ~105 MB against ~650 MB. See `docs/evidence/coreml-20261024/mac-benchmark.md`.

On the iOS Simulator (no Neural Engine; the Core ML GPU backend was rejected),
Core ML was slower than LiteRT-LM: ~1.55 s per image on the CPU with corrupted fp16
output, or ~2.5 s and 1.2 GB when forced off the CPU. Loads took 2.8–4.8 s on first
launch and ~0.2 s afterwards (LiteRT-LM: 1.7 s, then 0.17 s). Core ML also wrote an
~840 MB specialization cache per configuration, about the fp16 weight size, so int8
needed ~1.26 GB on disk against LiteRT-LM's 646 MiB including its XNNPACK caches.
The simulator cannot show the Neural Engine case, which is the only one where Core ML
won; see `docs/evidence/coreml-20261024/simulator.txt`.

Blocking issues before integration:

- Measure on a device: Neural Engine load time on first and later launches, and the
  size of the specialization cache. If it also stores expanded weights, Core ML does
  not reduce storage.
- The first Neural Engine load after installing models compiles them (~42 s on
  the Mac); later process starts loaded in 0.2–0.3 s. An earlier 43 s on every start
  came from also placing the 262k-row token table on the Neural Engine. Load models
  in the background, and measure the first compilation on a device.
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

The simulator app in `simulator/` loads the same models and the app's LiteRT-LM
runtime. Generate it with `xcodegen generate`, build for a simulator, then launch with
`SIMCTL_CHILD_BENCH_DIR` (holding `fixture.json`, `litert/model.litertlm`,
`compiled/` and `benchin/`) and `SIMCTL_CHILD_BENCH_MODE` (`litert`, `cpu`, `gpu`,
`ane` or `all`).

`mac-bench/` runs LiteRT-LM (through `SuwopShell`) and every Core ML configuration
in separate processes under `/usr/bin/time -l`. Build it from a checkout directory
named `suwop` with `swift build -c release`, copy `libCLiteRTLM_mac.dylib` next to
the binary, and run `MacBench <bench-dir> litert` or
`MacBench <bench-dir> coreml <int8|pal6|fp16|fp32> <ane|gpu|cpu|all>`.

