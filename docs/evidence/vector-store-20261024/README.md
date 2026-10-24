# Vector store and query evaluation, 2026-10-24

1,000 deterministic COCO val2017 photos (seed 20261015), first caption per image as
the English query, and 200 Japanese translations of the first 200 captions
(prepared by the assistant, not independently reviewed). Vectors came from the
pinned LiteRT-LM model through the `raw` probe phase: 768 dimensions, unprojected,
for two query prefixes. `quantization.py` truncated, renormalized and quantized
them offline; every query searches all 1,000 images.

- `quantization.json`: top-1/5/10 accuracy and top-10 agreement with exact float32
  for each prefix (`app` = `task: search query | text:`, `card` = the model card's
  `task: search result | query:`), dimension (768/512/256/128) and stored precision
  (f32, f16, int8, sign bits, sign-bit prefilter of 100 then int8 rescoring).
- `fixtures.json`: image IDs, source URLs, SHA-256 and English queries.
- `japanese-queries.json`: the Japanese queries by image ID.
- `raw-embedding.time`: `/usr/bin/time -l` for the 1,000-image probe run (M1 Max,
  debug Swift harness, concurrent builds; timing is indicative only).
- `search-latency.txt`, `search-bench.rs`: release `Store::search` over synthetic
  int8 vectors written directly into a schema-5 catalog (M1 Max).

Findings at 256 dimensions (the app default):

| Query set | f32 top-1 / top-5 / top-10 | int8 top-1 / top-5 / top-10 | int8 top-10 agreement |
|---|---|---|---|
| English, 1,000 | 64.6% / 88.9% / 94.9% | 64.3% / 88.6% / 95.0% | 97.7% |
| Japanese, 200 | 51.5% / 83.0% / 94.0% | 52.5% / 83.5% / 94.0% | 98.0% |

- int8 storage (260 bytes per vector) matched float32 within one point; f16 was
  indistinguishable from f32. Sign bits alone lost 20+ points of top-1.
- 768 and 512 dimensions scored about 1–2 points higher top-1 than 256 in English;
  128 dimensions lost about 10 points, as the model card warns.
- The card prefix was not significantly better: at 256 dimensions it alone found
  the correct top-1 for 24 English and 7 Japanese queries, versus 18 and 5 for the
  app prefix. The app prefix is unchanged.
- On the same 200 images, Japanese top-1 was about 13 points below English.
