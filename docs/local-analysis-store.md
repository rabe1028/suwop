# Local catalog and model-specific vector indexes

The application persists metadata to `Application Support/Suwop/catalog.sqlite3`.
`AppleShell` executes this effect through `LocalStore` on a dedicated native queue;
Rust owns transactions, migration, model identity, job state and publication.
A metadata commit does **not** wait for an embedding or acquire the analysis lock. SQLite WAL uses FULL synchronization. The legacy `library-v1.json`
is imported transactionally on first read and retained as a recovery copy. After
migration the SQLite database is canonical; editing the old JSON has no effect.
Back up SQLite using its online backup mechanism (or close the app and copy the
DB together with any WAL); copying just a live database file is not sufficient.

The native adapter excludes only the `models/` and `analysis/` directories from
Apple device/iCloud backups, including existing installations. The catalog and
its WAL remain eligible, so index vectors (about `dimensions + 4` bytes per photo)
are part of catalog backups. `analysis/` held the former Lance files; schema 5
empties it during migration and keeps the directory and its backup attribute.
After restoring a backup without the model, download it again; **Rebuild**
recreates the index from the preserved catalog and original sources.

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
  history, and are deleted in the transaction that publishes their shard. Schema 2
  migrates schema 1 payloads without changing job or shard identities. New catalogs
  use incremental vacuum; the worker reclaims at most 256 free pages per idle
  checkpoint. Existing schema 1 catalogs retain their vacuum mode and reuse free
  pages: migration does not force a full, blocking database rewrite.
- Model identity hashes name, immutable version, preprocessing, rendition and
  dimension count. Record preprocessing/token budget/quantization in that identity.
  Original and retouched images must use different rendition identities.
- `index_vectors` stores one int8 code vector and its float scale per published
  job, tagged with its shard. Vector rows, shard state and job state commit in one
  SQLite transaction; there is no second store to reconcile. No user-provided
  identifier enters SQL. Vector analysis never authorizes file deletion or proves
  byte-identical duplicates.

A generation is searchable only after every current job is materialized or explicitly excluded by the provider. Rebuilds
retain the previous active generation until an atomic publication transaction.
During incremental updates, existing published shards remain searchable. Queries
scan only done jobs of the active generation; catalog commits mark jobs for changed
or removed revisions obsolete in the same transaction, and each returned hit is
rechecked against its current revision. Removed or changed photos cannot reappear
from old vectors. Old generations can be removed with `prune`; it preserves both
active and latest generations and only drops shards owned by the manifest.
Rebuilding temporarily needs storage for both generations.

## Resource policy and interruption

Default per-generation managed budget: 128 MiB working estimate and at most 512
vectors in a batch. Valid working budgets are 64–512 MiB, row limits 1–512. The
budget's cache fields are still validated for API compatibility but no longer size
an engine cache. Admission estimates 16 copies of each vector plus per-row overhead.
Index writes and pruning share an advisory file lock, including across processes;
searches and metadata commits do not take it. There is one background worker per
open catalog, which retires after inactivity.

These are **managed buffer/admission bounds, not a strict process RSS cap**.
Allocator overhead and model inference cannot be hard-capped by this API. Multiple
independent catalogs also have separate budgets. iOS cannot isolate inference in a
child process. The native inference provider has its own model, image decode and
activation budget and stops scheduling on memory pressure. Do not interpret the
defaults as proof that a device can run a particular model.

Search is exact: a single SQLite scan computes each stored vector's distance to the
query and keeps the best `limit` rows. Vectors are stored as symmetric per-vector
int8 codes; queries stay float32. The reported distance is the squared L2 distance
between unit vectors (`2 - 2 * cosine`), the ordering the former index returned.
Storage is `dimensions + 4` bytes per vector plus SQLite row overhead, a quarter of
raw float32 and about an eighth of the former FLAT index, which kept a second copy.
On a 1,000-photo COCO sample, int8 codes kept 98% of exact float32 top-10 results
and changed top-1 accuracy by at most one percentage point
([evidence](evidence/vector-store-20261024/)). A synthetic M1 Max measurement of
the release Rust search took about 13 ms for 20,000 and 60 ms for 100,000
256-dimensional vectors. Phones are slower; measure on a device before claiming
latency. Much larger collections would need a different index.

`pause` stops scheduling the latest generation. A claimed shard is not published
while paused; its staged vectors stay in the outbox and `resume` replays it.
Publication writes index rows with `INSERT OR REPLACE`, so a replay never duplicates
them. Completed shards are retained. After replacement publication, the Rust worker
reclaims retired generations one shard per checkpoint, preserving the active and
latest generations; each shard's vectors and manifest entry leave in one
transaction. An index write error pauses the generation and exposes its error in status.
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
| prune | — | number of removed retired shards |

`submit` validates dimension, finite values and nonzero norm, then L2-normalizes.
Delivery is idempotent; stale source revisions/generations are rejected. Providers
must also L2-normalize the same truncated query dimensions. The original library
works without registering a model or downloading weights. The optional native
provider and search screen are described in [EmbeddingGemma 2](embeddinggemma2.md).

Current content visibility is projected through Rust `ContentAccess`: hidden,
protected, removed and unknown-visibility Apple assets are excluded. This also
invalidates jobs/results when visibility changes. Vectors of obsolete jobs remain
in the catalog until their shard or generation is pruned, and deleted SQLite pages
are not overwritten immediately; hiding an asset is not secure erasure. Similarity results are candidates and never authorize deletion.

## Recovery and evidence

The earlier uncommitted worktree disappeared during disk cleanup. This foundation
was recovered from source-writing tool history onto current main, then tested again.
Earlier measurement links from that worktree were unavailable and are not evidence
for this patch. Current reproducible results and limitations are recorded in
[the 256/512 comparison](embeddinggemma2.md).

The idle worker also reclaims a manifest-owned shard in an active/latest generation
once no jobs reference it. This handles same-revision photos returning after a
startup availability refresh without accumulating another index on every launch.
Cleanup shares the analysis lock with publication, drops at most one shard per
checkpoint, and removes its vectors and manifest entry together. A shard with any
job reference is retained.

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

## Schema 5: vectors in the catalog

Schema 5 replaces the Lance index with `index_vectors` and removes the `lancedb`,
Arrow and Tokio dependency tree (about 355 of the 480 Rust crates in the iOS build;
it also no longer needs `protoc`). Published vectors existed only in Lance files,
which this version cannot read, so migration returns those jobs to `awaiting`,
drops their shards, clears each model's active generation and retires non-latest
generations. Photos must be embedded again before search is available; staged
vectors of unpublished shards are kept. Migration empties `analysis/` but keeps the
directory. Schema 5 catalogs are not readable by earlier versions.

