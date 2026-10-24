# Reproduce the 256/512 comparison

The probe runs the app's Core ML pipeline: an edge-448 preview re-encoded as JPEG
(the Apple Photos path), Swift patch preparation, Rust tokens and the bundled models.
Results in `docs/evidence/embeddinggemma2-20261015/` and the `raw` LiteRT rows in
`docs/evidence/vector-store-20261024/` came from the former LiteRT-LM runtime; reproduce
those from a checkout before the switch, whose `profile` and `lifecycle` phases this
version no longer has.

Requirements: Apple Silicon macOS with a Neural Engine, pinned repository Rust/Xcode
tools, Python 3.10+, `curl`. This downloads public COCO fixtures; it never reads the
user's photo library. Results and photos are ignored by Git.

1. From the repository root, build the host bridge:
   `bash scripts/build-rust-apple.sh --host`.
2. Create `experiments/embedding-evaluation/results/`. Download
   `http://images.cocodataset.org/annotations/annotations_trainval2017.zip` to
   `results/annotations.zip`, then run `uv run --no-project python prepare.py` from this directory.
   The deterministic sample uses seed 20261015 and the first caption by annotation
   ID. HTTP is the public dataset's endpoint, not a credential-bearing service.
3. Run `make coreml-models` from the repository root; it produces
   `Generated/CoreMLModels/EmbeddingGemma2`.
4. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` here.
5. Run each phase in a separate process, with `MODELS` the absolute path of
   `Generated/CoreMLModels/EmbeddingGemma2`:

```bash
for dims in 256 512; do
  mkdir -p "results/d$dims"
  /usr/bin/time -l .build/debug/EmbeddingProbe embed "$dims" \
    "$MODELS" "$PWD/results/manifest.json" "$PWD/results/d$dims" \
    > "results/d$dims/embedding.log" 2> "results/d$dims/embedding.time"
  /usr/bin/time -l .build/debug/EmbeddingProbe index "$dims" \
    "$MODELS" "$PWD/results/manifest.json" "$PWD/results/d$dims" \
    > "results/d$dims/index.log" 2> "results/d$dims/index.time"
done
uv run --no-project python summarize.py
```

Use fresh output catalogs for a new measurement: this harness measures initial
index creation, and a previously populated catalog changes timing/storage costs.
`comparison.json` separates exact model quality from ANN agreement, SQLite/data/
index/manifest storage, RSS and physical footprint. Reports include elapsed time;
other workloads and debug Rust code affect performance.

This harness uses the actual native adapter, image preprocessing, Rust projection
and vector store. It retains all 100 projected vectors only for quality evaluation;
the app persists one at a time. It does not exercise the app's UI or prove its
memory admission budget. Durable pause, restart and stale-source behavior have
separate Rust/Swift tests. See `docs/embeddinggemma2.md` for limitations and results.

Japanese diagnostic: use `docs/evidence/embeddinggemma2-20261015/japanese-queries.json`
for the first 20 query translations and join file paths by ID from `manifest.json`.
Run `embed` on those 20 entries into `results/japanese256` / `japanese512` and retain
the resulting file as `translated-vectors.json`. Copy the original 100 image vectors
into each directory's `vectors.json`, replacing only the corresponding 20 query
vectors with the Japanese versions; keep all 100 images. Run `index` there, then
`uv run --no-project python summarize_japanese.py`. Only the 20 translated queries contribute to the
Japanese metrics. Source captions/translation ambiguities and the small sample
limit interpretation.

Prefix, dimension and stored-precision comparison (2026-10-24): run
`uv run --no-project python prepare.py --count 1000 --manifest manifest-1000.json
--japanese <id-to-query.json>`, then the `raw` phase, which stores unprojected
768-dimensional image vectors and app-prefix query vectors (the 2026-10-24 LiteRT run also
stored model-card-prefix queries):

```bash
.build/debug/EmbeddingProbe raw 256 "$MODELS" \
  "$PWD/results/manifest-1000.json" "$PWD/results/raw1000"
uv run --no-project --with numpy python quantization.py results/raw1000/raw.json
```

`quantization.py` needs numpy only for this offline analysis; the app and checks do
not. Results are in `docs/evidence/vector-store-20261024/`.

