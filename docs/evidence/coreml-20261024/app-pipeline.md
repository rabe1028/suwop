# App pipeline acceptance (Core ML, M1 Max)

`experiments/embedding-evaluation` `raw` phase after the switch: the same 1,000 COCO
photos and 200 Japanese queries as `docs/evidence/vector-store-20261024/`, run through
the app's path. Images are decoded at edge 448, re-encoded as JPEG 0.9 (the Apple
Photos path), prepared by `EmbeddingPatches` and tokenized by Rust. Queries are
tokenized by Rust with the app prefix. Models come from `make coreml-models`
(identity `333a3a90…`). Scores are in `app-pipeline-quantization.json`.

| 256 dimensions, int8 stored | Core ML app path top-1 / 5 / 10 | LiteRT-LM top-1 / 5 / 10 |
|---|---|---|
| English, 1,000 | 63.9 / 88.7 / 95.0 | 64.3 / 88.6 / 95.0 |
| Japanese, 200 | 53.0 / 84.5 / 91.5 | 52.5 / 83.5 / 94.0 |

Paired top-1 sign tests against LiteRT-LM: English 256 42 vs 50 (p=0.47), English 768
41 vs 45 (p=0.75), Japanese 256 17 vs 12 (p=0.46), Japanese 768 15 vs 14 (p=1.0). No
significant difference.

Whole run (1,000 images, 1,200 queries, release probe): 144.6 s, peak memory
footprint 169 MB, maximum RSS 475 MB. The LiteRT-LM run of the same set (debug probe,
two text queries per image) took 811 s with 822 MB maximum RSS.

Image vectors differ from transformers-preprocessed Core ML vectors by cosine
0.985–0.990 on spot checks, from the preview downscale and JPEG re-encode; text
vectors match within 0.999.
