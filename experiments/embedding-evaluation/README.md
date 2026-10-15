# Reproduce the 256/512 comparison

Requirements: Apple Silicon macOS, pinned repository Rust/Xcode/LiteRT dependencies,
Python 3.10+, `curl`. This downloads public COCO fixtures and the pinned model; it
never reads the user's photo library. Results and photos are ignored by Git.

1. From the repository root, build the host bridge:
   `PROTOC=/path/to/protoc bash scripts/build-rust-apple.sh --host`.
2. Create `experiments/embedding-evaluation/results/`. Download
   `http://images.cocodataset.org/annotations/annotations_trainval2017.zip` to
   `results/annotations.zip`, then run `python3.12 prepare.py` from this directory.
   The deterministic sample uses seed 20261015 and the first caption by annotation
   ID. HTTP is the public dataset's endpoint, not a credential-bearing service.
3. Download the immutable model URL in `crates/suwop-core/src/inference.rs` to a
   local file. Verify the exact SHA-256 there before running native inference.
4. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build` here.
5. Run each phase in a separate process, replacing `/absolute/model.litertlm`:

```bash
for dims in 256 512; do
  mkdir -p "results/d$dims"
  /usr/bin/time -l .build/debug/EmbeddingProbe embed "$dims" \
    /absolute/model.litertlm "$PWD/results/manifest.json" "$PWD/results/d$dims" \
    > "results/d$dims/embedding.log" 2> "results/d$dims/embedding.time"
  /usr/bin/time -l .build/debug/EmbeddingProbe index "$dims" \
    /absolute/model.litertlm "$PWD/results/manifest.json" "$PWD/results/d$dims" \
    > "results/d$dims/index.log" 2> "results/d$dims/index.time"
done
python3.12 summarize.py
```

Use fresh output catalogs for a new measurement: this harness measures initial
index creation, and a previously populated catalog changes timing/storage costs.
`comparison.json` separates exact model quality from ANN agreement, SQLite/data/
index/manifest storage, RSS and physical footprint. Reports include elapsed time;
other workloads and debug Rust code affect performance.

This harness uses the actual native adapter, image preprocessing, Rust projection
and Lance store. It retains all 100 projected vectors only for quality evaluation;
the app persists one at a time. It does not exercise the app's UI or prove its
memory admission budget. Durable pause, restart and stale-source behavior have
separate Rust/Swift tests. See `docs/embeddinggemma2.md` for limitations and results.

For VM category inspection, replace `embed` with `profile`: it pauses for 20 seconds
after model loading and 30 seconds after processing. During those windows run
`vmmap -summary <EmbeddingProbe PID>`. Do not compare that run's elapsed time
with the regular benchmark, and do not add shared VM regions to process RSS.

The `lifecycle` phase runs five real model load/image/pause/reopen/unload cycles. It
asserts that a 768 MiB startup budget is refused, a 1.5 GiB budget admits the host
before and after inference, and a paused journal stays paused in a new store
instance. `lifecycle.json` records RSS before load, after load/work and after close.
The native allocator can retain pages after engine deletion; this is not a hard
process-memory limit or physical-device acceptance.

Japanese diagnostic: use `docs/evidence/embeddinggemma2-20261015/japanese-queries.json`
for the first 20 query translations and join file paths by ID from `manifest.json`.
Run `embed` on those 20 entries into `results/japanese256` / `japanese512` and retain
the resulting file as `translated-vectors.json`. Copy the original 100 image vectors
into each directory's `vectors.json`, replacing only the corresponding 20 query
vectors with the Japanese versions; keep all 100 images. Run `index` there, then
`python3.12 summarize_japanese.py`. Only the 20 translated queries contribute to the
Japanese metrics. Source captions/translation ambiguities and the small sample
limit interpretation.
