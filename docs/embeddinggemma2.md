# Local image and text search with EmbeddingGemma 2

The Search tab now offers **写真の内容**. Starting analysis downloads a pinned model
once (387,710,976 bytes), verifies its exact size and SHA-256, then performs local
CPU inference. PhotoKit and configured Immich sources supply previews; photo
contents are not sent to an external embedding service. Registration commits
metadata and durable jobs without waiting for inference or Lance indexing.

The default is **256 dimensions** to reduce storage, with a **1.5 GiB** inference
admission budget. 512 dimensions and 1/2 GiB budgets are available. Both dimensions
can coexist. Model version, preprocessing, rendition and dimensions form separate
model identities and Lance generations. Switching dimensions does not reinterpret
existing vectors. Rebuild retains the previous active generation until publication.

## Runtime and source semantics

- LiteRT-LM Swift package 0.18.0, native C embedding API on a dedicated serial queue.
  Rust owns model identity, query formatting, projection, budgets and durable jobs;
  Swift performs native image I/O, memory observation and UI scheduling.
- Text+vision 440M model, pinned revision
  `e301f74d5551b0c2641bd5cb4652a76239d5c5f8`, SHA-256
  `92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0`.
  Download goes to a temporary file with a byte quota; Rust rechecks before atomic
  installation. The SDK is a build dependency; model weights are not in Git.
- CPU, 2 threads, 70 vision tokens, 128 text tokens, fit-to-448 JPEG at quality 0.9.
  The native output is 768 dimensions. Rust truncates to 256/512 and L2-normalizes
  independently. Queries use `task: search query | text: ...`.
- This provider uses **current previews**, including current edits. It is not an
  original/pre-retouch similarity provider. A future original rendition must have
  its own model identity, source revision and preprocessing.
- Apple metadata/visibility is rechecked before and after thumbnail retrieval.
  SQLite rejects stale catalog revisions on submission/search. Immich thumbnail
  source eligibility and the captured server/credential identity are checked against
  one SQLite snapshot before and after retrieval, including during connection switches.
  Remote content freshness still depends on catalog refresh; no server snapshot transaction exists.
- Hidden/protected/unknown-visibility content is excluded by Rust privacy policy.
  Hiding removes search eligibility, but immutable old vector files are only
  reclaimed by rebuilding/pruning. This is not secure erasure.
- Similarity is a candidate ranking. It never authorizes deletion or establishes
  byte-identical duplicates.

## Interruption and memory

Inference handles one image at a time. Each completed vector is durably enqueued
before continuing. Pause persists inference and index states, stops scheduling,
and drains the current native operation before unloading the model. Restart resumes
only unfinished jobs; manually paused runs remain paused. App inactivity cancels
in-flight scheduling; foreground entry can resume a running journal. Failed input
pauses visibly rather than silently declaring a complete index; the provider API
also supports explicit per-job exclusion with a reason.

Index creation has its own default 128 MiB managed working budget, two 8 MiB caches
and a 512-row batch limit. The worker waits for a batch (or the final remainder),
so one-image inference does not create a Lance table per photo. Index pause/replay
and per-generation budget APIs are independent of inference. See
[the storage contract](local-analysis-store.md).

Inference admission checks process RSS, available memory and OS pressure before
model loading and around each image/query. It reserves 768 MiB for startup and
64 MiB while loaded. A file lock prevents simultaneous engines using the same model
installation. Native inference is blocking on its own queue, outside the main actor
and Swift cooperative executor. Memory pressure or exhausted budget persists a pause.

**These are admission/checkpoint budgets, not hard RSS ceilings.** A native kernel
cannot be cancelled or prevented from allocating above the budget mid-call. The
next checkpoint stops work and unloads the model. macOS RSS includes mapped pages;
iOS memory-pressure and process-available-memory signals are also considered.
Physical-device acceptance remains necessary before claiming a safe iPhone budget.

An actual-model five-cycle load/infer/pause/reopen/unload probe confirmed durable
pause and rejection of a 768 MiB startup budget, and admitted every cycle at
1.5 GiB on this host. Peak observed checkpoint RSS stayed below 954 MiB, but RSS
**after engine deletion grew from about 289 to 647 MiB** and levelled off over the
last cycles. Native allocator/shared caches can retain resident pages after unload;
closing the engine does not promise return to the initial ~30 MiB baseline. This
also makes a 1 GiB budget too tight for repeated loads in this configuration.
[Raw lifecycle observations](evidence/embeddinggemma2-20261015/256-lifecycle.json)
are separate from the 100-photo quality benchmark. A final run also exercised
atomic installation into a fresh model directory and re-verification before five
cycles: peak checkpoint RSS was 943 MiB, with post-close RSS rising from 182 to
342 MiB. The difference between runs reinforces that RSS retention depends on
native/cache residency and is not a fixed amount.
[Final installed-model lifecycle](evidence/embeddinggemma2-20261015/256-lifecycle-installed.json).

## Measured comparison (2026-10-15)

M1 Max, 64 GiB RAM. 100 deterministic public COCO val2017 photos, one corresponding
English caption per image. Same actual adapter/preprocessing as the app; separate
fresh processes for inference and index/search at each dimension. No user photos.
Debug harness/Rust with the distributed native SDK; concurrent builds mean timing
is indicative, not an isolated performance benchmark.

| Measurement | 256 dimensions | 512 dimensions |
|---|---:|---:|
| Correct photo ranked first, exact / Lance | 85% / 85% | 85% / 85% |
| Correct photo in top 5, exact / Lance | 100% / 100% | 100% / 100% |
| Lance top-10 set agreement with exhaustive search | 100% | 100% |
| Raw float32 vectors, 100 photos | 102,400 B | 204,800 B |
| Lance data files | 103,698 B | 206,099 B |
| Lance FLAT/HNSW index files | 114,011 B | 216,860 B |
| Lance manifests | 2,185 B | 2,185 B |
| SQLite catalog/jobs | 172,032 B | 172,032 B |
| SQLite WAL after worker checkpoint | 0 B | 0 B |
| Inference peak RSS | 953.0 MiB | 953.0 MiB |
| Inference peak physical footprint | 597.1 MiB | 596.4 MiB |
| Index/search peak RSS | 111.5 MiB | 118.2 MiB |
| Index/search peak physical footprint | 16.4 MiB | 23.2 MiB |
| 100 image + 100 query inferences | 70.65 s | 70.08 s |
| Index + 100 searches | 1.54 s | 1.46 s |

The shared quantized model is **369.75 MiB** on disk for either dimension. The
native SDK additionally creates **276.63 MiB** of XNNPACK prepared-weight caches:
70,930,728 bytes for text, 1,575,160 bytes for the vision adapter and 217,562,184
bytes for the vision encoder. Total model + native caches is **646.38 MiB**
(677,779,048 bytes), shared across dimension settings. These caches are rebuildable,
not photo previews; they can survive engine unloading. Replacing invalid/older weights takes the same engine lease and removes only this
provider's generated cache files, preventing old copies accumulating after replacement.
Installing an already valid model is idempotent and preserves its current caches.
The downloaded temporary file and installed copy also overlap during installation.
All Lance
files total 219,894 vs 425,144 bytes. FLAT indexes retain another vector copy plus
graph overhead; SQLite staging vector payloads are reclaimed after publication.
SQLite size includes synthetic catalog metadata, not originals or preview files.

The runtime first computes the same 768-dimensional representation for both
settings, so truncation halves vector storage but does not materially reduce model
or activation memory. RSS after loading was about 757 MiB and grew to about 950 MiB
after processing. Model mappings, native weight preparation/caches and image/text
activations explain the broad cost categories; this experiment does not attribute
individual native allocations. A separate live `vmmap` run confirmed the default
malloc zone grew from **424.5 MiB resident after load to 587.8 MiB during work**
(about 163 MiB), while mapped-file residency stayed near 306–309 MiB. The
large-allocation category grew from 189.2 to 317.6 MiB. Thus the observed growth is
primarily native heap working state, not the 100 small stored vectors. These VM
region totals include shared mappings and must not be summed as process RSS.
[Load snapshot](evidence/embeddinggemma2-20261015/256-loaded-vmmap.txt) and
[working snapshot](evidence/embeddinggemma2-20261015/256-working-vmmap.txt) retain
the category evidence; per-allocation attribution was not captured.

RSS differs from the lower physical-footprint
measurement and must not be presented as model weights alone.

A separate Japanese diagnostic translated the first 20 captions and searched the
same 100-photo corpus. Top-1 recall was **75% (15/20) at 256** and **80% (16/20)
at 512**, with top-5 recall **100% for both**; exact and Lance recall matched.
Those same 20 English queries scored 90% top-1 at either dimension. Translations
were prepared by the assistant, not independently judged; an ambiguous source
caption was preserved literally. The one-query difference is too small to infer a
stable accuracy advantage, but it shows that identical English aggregate scores do
not establish Japanese equivalence. [Queries](evidence/embeddinggemma2-20261015/japanese-queries.json)
and [per-query ranks](evidence/embeddinggemma2-20261015/japanese-comparison.json)
are retained. 512 remains available for users preferring more representation detail.

This small corpus does **not** establish equal quality on larger collections,
Japanese queries, near-duplicate/retouch groups or individual libraries. A caption
can fit several images but evaluation labels only one as correct. Large libraries
also need shard-routing/compaction measurements before claiming low search latency.
256 is a storage-oriented provisional default, not a universal accuracy conclusion.

A separate **20,000-row synthetic backlog** test exercised the release Rust worker
at 512 dimensions with the 128 MiB managed budget and 512-row limit. It published
40 shards in 2.86 s with **81.3 MiB peak RSS**; one all-shard query took 0.47 s.
Lance data/index/metadata occupied 41,049,314 / 44,079,782 / 87,650 bytes; SQLite
occupied 20,148,224 bytes with no free-list pages after publication. This probe
bulk-stages synthetic vectors before the measured process, so it measures indexing
and search, **not inference, producer memory, or retrieval quality**. Concurrent
builds and a single warm-filesystem run limit timing conclusions.
[Raw backlog measurement](evidence/embeddinggemma2-20261015/synthetic-20000-index.json).

[Raw JSON, resource output and fixture IDs](evidence/embeddinggemma2-20261015/)
and [reproduction instructions](../experiments/embedding-evaluation/README.md).

## Validation scope

`make check` passed 285 Rust tests and 59 Swift tests, including the real C ABI,
job replay, stale revisions, generation publication and current connection binding.
`make vrt` passed 34 unit tests and 21 UI tests with 37 screenshot comparisons on
the pinned simulator environment. The existing 35 baselines are byte-identical;
only two reviewed semantic-search screens were added, without changing tolerance.
The semantic UI fixture checks navigation, persisted pause and dimension switching;
the actual-model harness separately validates native inference and Lance search.
All five Rust release slices, XCFramework packaging and the iOS simulator/macOS
application builds passed. Packaging was resumed after an in-flight build-script
edit interrupted the original shell process; the compile outputs were retained.
The installed-model lifecycle probe verifies atomic installation, budget rejection,
persisted pause and five engine cycles. This is not physical-device acceptance.

[Machine-readable validation and source hashes](evidence/embeddinggemma2-20261015/validation.json)
record each gate separately. Hosted CI, physical iPhone/PhotoKit inference and
live Immich inference acceptance have not been run for this patch.

## Upstream references

[Official model card](https://huggingface.co/google/embeddinggemma-2),
[quantized text+vision model](https://huggingface.co/litert-community/embeddinggemma-2-text-vision-440m-litert-lm),
[LiteRT embedding API](https://developers.google.com/edge/litert-lm/embedding_models),
[COCO downloads](https://cocodataset.org/#download).
The model card declares Apache-2.0; preserve upstream notices when distributing
model weights/SDK binaries. COCO image rights remain with their original owners;
the repository retains IDs, URLs, captions and measurements, not the source photos.

The selected model identity is persisted separately from index generations. Switching
dimensions does not register a model or resume a paused journal. On startup Rust
returns the selected model and its analysis/inference state in one SQLite snapshot.
Catalog schema v3 preserves existing jobs and indexes; catalogs without a recorded
selection remain unselected until the user chooses or starts a model.

Unreadable photos pause inference with a durable, revision-bound failed-job ID. The search UI can explicitly exclude that photo from the current analysis generation and continue. Exclusion preserves the original and catalog metadata, reports the skipped count, and is retried on a full rebuild. Stale failures and failures from another model cannot exclude a current photo.

Apple CI builds the five Rust release targets in separate matrix jobs. The app job depends on all five, verifies each library's source revision, target and SHA-256 against the current clean checkout, then runs the same universal XCFramework, iOS/macOS app builds and native sharing tests. Intermediate libraries expire after one day; screenshots and acceptance results retain their existing retention. Local `make apple-build` still builds every target from source.

Catalog-only wakes check the pending journal before touching model weights. A required load reuses the verified path, avoiding duplicate 388 MB SHA-256 reads. Native image preparation also checks the live Rust ordinary-content projection before I/O and before returning bytes; persisted Immich lock intents remove pending jobs and published search hits.
