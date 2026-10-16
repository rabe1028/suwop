# Local catalog and model-specific Lance indexes

The application persists metadata to `Application Support/Suwop/catalog.sqlite3`.
`AppleShell` executes this effect through `LocalStore` on a dedicated native queue;
Rust owns transactions, migration, model identity, job state and publication.
A metadata commit does **not** open Lance, wait for an embedding or acquire the
analysis lock. SQLite WAL uses FULL synchronization. The legacy `library-v1.json`
is imported transactionally on first read and retained as a recovery copy. After
migration the SQLite database is canonical; editing the old JSON has no effect.
Back up SQLite using its online backup mechanism (or close the app and copy the
DB together with any WAL); copying just a live database file is not sufficient.

The native adapter excludes only the `models/` and `analysis/` directories from
Apple device/iCloud backups, including existing installations. The catalog and
its WAL remain eligible. Directory attributes are installed before Rust can write
derived data; failures are surfaced rather than silently including large files.
After restoring a backup without derived files, download the model again and use
**Rebuild** to recreate the index from the preserved catalog and original sources.

## Data separation

- `library_state` preserves the existing Rust application journal, including Move
  receipts and uncertain deletion phases. `assets` projects current metadata for
  analysis. This first migration retains the full state JSON, so asset metadata is
  currently duplicated in the projection; it does not duplicate original files.
  The existing 16 MiB bridge and full-catalog serialization still limit metadata
  scale; paged catalog operations are a separate follow-up.
- SQLite `models`, `generations`, `jobs` and `shards` form a durable outbox. A job
  identifies a provider/scope/asset, its revision and its model generation.
  Temporary vector bytes live in `embedding_vectors`, separate from durable job
  history, and are deleted transactionally after Lance publication. Schema 2
  migrates schema 1 payloads without changing job or shard identities. New catalogs
  use incremental vacuum; the worker reclaims at most 256 free pages per idle
  checkpoint. Existing schema 1 catalogs retain their vacuum mode and reuse free
  pages: migration does not force a full, blocking database rewrite.
- Model identity hashes name, immutable version, preprocessing, rendition and
  dimension count. Record preprocessing/token budget/quantization in that identity.
  Original and retouched images must use different rendition identities.
- Lance stores only numeric job IDs and normalized vectors. Each generation owns
  separate `g<generation>_s<shard>` tables. No user-provided identifier enters a
  filesystem table name or SQL expression. Vector analysis never authorizes file
  deletion or proves byte-identical duplicates.

A generation is searchable only after every current job is materialized or explicitly excluded by the provider. Rebuilds
retain the previous active generation until an atomic publication transaction.
During incremental updates, existing published shards remain searchable. Queries
filter against current SQLite revisions before and after Lance search. Removed or
changed photos cannot reappear from old vectors. Old generations can be removed
with `prune`; it preserves both active and latest generations and only drops tables
owned by the manifest. Rebuilding temporarily needs storage for both generations.

## Resource policy and interruption

Default per-generation managed budget: 128 MiB working estimate, 8 MiB for each
of Lance's two caches, at most 512 vectors in a batch. Valid working budgets are
64–512 MiB, cache budgets 1–16 MiB, row limits 1–512. Admission reserves 32 MiB for
the native engine and estimates 16 copies of each vector plus per-row overhead.
Searches and index writes share an advisory file lock, including across processes;
metadata commits do not use it. There is one background worker per open catalog,
which retires after inactivity. Lance operations are serialized within a catalog.

These are **managed buffer/cache/admission bounds, not a strict process RSS cap**.
Lance/Arrow/allocator/runtime overhead and model inference cannot be hard-capped by
this API. Multiple independent catalogs also have separate budgets. iOS cannot
isolate inference in a child process. The native inference provider has its own model,
image decode and activation budget and stops scheduling on memory pressure.
Do not interpret the defaults as proof that a device can run a particular model.

Each shard uses IVF-HNSW-FLAT (one partition); fewer than 32 vectors use bounded
exact search. There is no global PQ training sample. This trades larger disk usage
and searches across many small shards for bounded work and restart granularity.
Raw f32 vectors cost `rows * dimensions * 4`; FLAT indexes also store vectors, so
budget roughly another vector copy plus graph/file overhead. This deliberately
differs from the earlier PQ PoC; its size/RSS measurements are not measurements of
this implementation. Very large collections will need measured shard-routing and
compaction work before claiming low search latency.

`pause` stops scheduling the latest generation. A running shard can finish its
bounded native operation but is not published while paused. `resume` replays that
pending shard. A crash before SQLite publication leaves vectors and shard identity
in the outbox; replay recreates only that unpublished table (including removal of abandoned versions). Completed shards are
retained. After replacement publication, the Rust worker reclaims retired
generations one shard per checkpoint, preserving the active and latest generations.
Interrupted cleanup resumes from the manifest and uses the retired generation's
cache budget. A Lance indexing error pauses the generation and exposes its error in status.
Interrupted deletion/transfer journals remain independent and are never replayed
by this worker. Index buffers are released after publication; obsolete-generation
vectors are released by pruning. There is no automatic original-file deletion.

## Native provider API

C ABI utility action 15 accepts `{ "root": "<private absolute directory>",
"command": { "type": "..." } }`. `SuwopShell.LocalStore.call` schedules this API
outside Swift's cooperative executor. Read and persist have dedicated methods.
Commands use camelCase fields:

| Command | Fields | Result |
|---|---|---|
| register | model, budget | stable model key (idempotent registration) |
| pending | modelKey, limit (1–32) | jobs awaiting embeddings |
| submit | modelKey, embeddings (`jobId`, `vector`) | durable enqueue |
| skip | modelKey, jobId, reason | exclude unsupported/undecodable media from this generation |
| status | — | generation, progress, budget, paused error |
| pause / resume | modelKey | durable state change |
| rebuild | modelKey, budget | new generation; old stays searchable |
| search | modelKey, vector, limit (1–100) | asset/revision/distance |
| prune | — | number of removed retired shard tables |

`submit` validates dimension, finite values and nonzero norm, then L2-normalizes.
Delivery is idempotent; stale source revisions/generations are rejected. Providers
must also L2-normalize the same truncated query dimensions. The original library
works without registering a model or downloading weights. The optional native
provider and search screen are described in [EmbeddingGemma 2](embeddinggemma2.md).

Current content visibility is projected through Rust `ContentAccess`: hidden,
protected, removed and unknown-visibility Apple assets are excluded. This also
invalidates jobs/results when visibility changes. Existing vectors in immutable
retired shards remain on disk until a rebuild and pruning; hiding an asset is not
secure erasure. Similarity results are candidates and never authorize deletion.

## Recovery and evidence

The earlier uncommitted worktree disappeared during disk cleanup. This foundation
was recovered from source-writing tool history onto current main, then tested again.
Earlier measurement links from that worktree were unavailable and are not evidence
for this patch. Current reproducible results and limitations are recorded in
[the 256/512 comparison](embeddinggemma2.md).

The idle worker also reclaims a manifest-owned shard in an active/latest generation
once no jobs reference it. This handles same-revision photos returning after a
startup availability refresh without accumulating another index on every launch.
Cleanup shares the analysis lock with publication and search, drops at most one
shard per checkpoint, and removes its SQLite manifest only after the Lance table
is gone. Interrupted cleanup can safely resume; a shard with any job reference is
retained.

Schema 4 retains a compact `analysis_asset_keys` identity map independently of the
current visible asset projection. It is backfilled from available schema-3 asset
rows during migration. A full, timestamped, unambiguous inventory for the same
provider/scope can detach obsolete jobs for removed or superseded revisions;
limited, unavailable, unstamped or missing sources cannot. Identity survives those
uncertain scans and process restarts, so a later confirmed removal can release the
shard. Keys with neither a current asset nor a referenced shard are removed during
the next catalog commit. This is derived-data retention policy, never original-deletion authority.
Older already-obsolete jobs whose identity was lost before schema 4 remain
conservative and are reclaimed with their generation on an explicit rebuild.
