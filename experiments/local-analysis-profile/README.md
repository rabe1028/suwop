# Native local-index resource probe

This host-only fixture calls the application's C ABI and real background Lance
worker. It never reads original photos, runs a model or downloads weights.
`prepare` persists synthetic metadata and pauses one model; `profile.py seed`
bulk-stages deterministic normalized SHAKE256 vectors in the SQLite outbox.
This bypasses the normal bounded producer API solely to measure indexing in a
fresh process without producer allocations. It also exercises a fully queued
backlog, rather than assuming vectors are produced just in time.

After `make apple-build`, compile the probe from the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -swift-version 6 -O -I Sources/CSuwop \
  experiments/local-analysis-profile/main.swift \
  Generated/RustSlices/aarch64-apple-darwin/libsuwop_ffi.a \
  -framework Security -framework SystemConfiguration -lc++ -liconv \
  -o experiments/local-analysis-profile/results/profile-release
bash experiments/local-analysis-profile/run.sh \
  experiments/local-analysis-profile/results/new-fixture 20000
```

Create the ignored `results` directory before compiling. Each run requires a new
fixture directory and 10–20,000 rows. `time.txt` is macOS `/usr/bin/time -l` output;
its maximum resident set size is bytes. `measurements.json` includes a binary hash,
Lance component sizes, SQLite allocation and timing. SQLite inspection opens only
the synthetic fixture with `mode=rw` because this host's Python SQLite cannot read
some WAL PRAGMAs from a read-only connection after checkpointing. It does not modify
the catalog. The measured process includes index creation, one query and a 2.5 s
idle interval to let the native worker close. Timings are single warm-filesystem
runs, not a distribution or real-device acceptance.

Current analysis fixtures use SQLite schema 4 with temporary payloads in
`embedding_vectors`, durable asset identities and incremental vacuum; catalog JSON uses schema 5.
The earlier worktree's measurement artifacts were not recovered and are not
evidence for the current implementation. Large fixture databases and binaries
are ignored. The actual-model comparison is in `docs/evidence/embeddinggemma2-20261015`.
