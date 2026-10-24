# Core ML vs LiteRT-LM on an M1 Max

Run 2026-10-24 with `experiments/coreml-conversion/mac-bench` (release), macOS on an
M1 Max (64 GiB). Each row is a separate process under `/usr/bin/time -l`; `#2` and
later rows reuse caches written by `#1`. Every run embeds the same 20 COCO photos
and their captions. Core ML receives inputs preprocessed by transformers; LiteRT-LM
decodes and resizes JPEGs itself (median 5 ms, excluded from its image time).
Cosine is the minimum over the 20 inputs against float32 transformers.
`app` runs from an ad-hoc signed `.app` with a bundle identifier, `cli` as a bare
executable. Raw rows: `mac-benchmark.jsonl`.

| Run | Load | First image ms | Image ms median / p90 | Text ms median / p90 | Peak footprint MiB | Max RSS MiB | Cosine image / text |
|---|---|---|---|---|---|---|---|
| Core ML int8-ane (app) #1 | 41.78 s | 138 | 110 / 120 | 8.7 / 9.7 | 141 | 458 | 0.9988 / 0.9998 |
| Core ML int8-ane (app) #2 | 0.26 s | 149 | 120 / 126 | 9.2 / 10.7 | 82 | 107 | 0.9988 / 0.9998 |
| Core ML int8-ane (cli) #1 | 44.11 s | 131 | 112 / 123 | 9.1 / 11.1 | 141 | 455 | 0.9988 / 0.9998 |
| Core ML int8-ane (cli) #2 | 0.22 s | 128 | 110 / 111 | 8.4 / 8.5 | 81 | 103 | 0.9988 / 0.9998 |
| Core ML pal6-ane (app) #1 | 41.11 s | 149 | 125 / 144 | 10.7 / 15.9 | 110 | 280 | 0.9842 / 0.9925 |
| Core ML pal6-ane (app) #2 | 0.22 s | 159 | 122 / 159 | 9.5 / 12.9 | 83 | 108 | 0.9842 / 0.9925 |
| Core ML fp16-ane (app) #1 | 46.08 s | 163 | 127 / 135 | 10.2 / 14.8 | 76 | 582 | 0.9988 / 1.0000 |
| Core ML fp16-ane (app) #2 | 0.30 s | 175 | 127 / 155 | 10.1 / 12.4 | 83 | 108 | 0.9988 / 1.0000 |
| Core ML int8-gpu (app) #1 | 3.35 s | 9415 | 394 / 440 | 57.3 / 64.7 | 661 | 984 | 0.9985 / 0.9998 |
| Core ML int8-gpu (app) #2 | 0.13 s | 2062 | 395 / 425 | 56.2 / 57.9 | 655 | 956 | 0.9985 / 0.9998 |
| Core ML fp32-gpu (app) #1 | 5.26 s | 5016 | 105 / 119 | 17.6 / 20.8 | 296 | 1788 | 1.0000 / 1.0000 |
| Core ML fp32-gpu (app) #2 | 1.86 s | 642 | 103 / 112 | 17.4 / 19.2 | 261 | 1718 | 1.0000 / 1.0000 |
| Core ML fp32-cpu (app) #1 | 4.65 s | 420 | 309 / 339 | 54.2 / 58.8 | 93 | 1334 | 1.0000 / 1.0000 |
| Core ML int8-cpu (app) #1 | 4.46 s | 229 | 175 / 183 | 29.8 / 31.1 | 97 | 700 | 0.6041 / 0.9623 |
| LiteRT-LM (app) #1 | 0.97 s | 526 | 502 / 558 | 91.7 / 118.9 | 343 | 963 | 0.9671 / 0.9851 |
| LiteRT-LM (app) #2 | 0.15 s | 523 | 498 / 524 | 87.6 / 101.4 | 305 | 650 | 0.9671 / 0.9851 |
| LiteRT-LM (app) #3 | 0.13 s | 521 | 487 / 521 | 86.2 / 98.8 | 307 | 652 | 0.9671 / 0.9851 |

## Findings

- int8 on the Neural Engine, after the first load: image 110–120 ms vs 487–502 ms
  for LiteRT-LM (about 4.5x), text 8–9 ms vs 86–92 ms (about 10x), peak footprint
  ~82 MiB vs ~305 MiB, max RSS ~105 MiB vs ~650 MiB, cosine 0.9988 / 0.9998 vs
  0.967 / 0.985.
- Loading: the first Neural Engine load compiled for 41–46 s; later processes,
  `app` or `cli`, loaded in 0.2–0.3 s. LiteRT-LM loaded in 0.97 s without its
  XNNPACK caches and 0.13–0.15 s with them.
- int8 and fp16 performed alike on the Neural Engine; 6-bit was slightly slower
  and less accurate (0.984 image cosine).
- GPU: fp32 matched image latency (103 ms) but used ~1.7 GiB RSS; int8 was slower
  (395 ms) at ~655 MiB footprint. CPU: fp32 was correct but 309 ms per image;
  int8 on the CPU corrupted output (image cosine 0.60), as fp16 did in the earlier
  Python parity check (`measurements.txt`).
- Disk: the app's Core ML cache was 24 KB; the system's Neural Engine compilation
  cache was not measurable without root. The iOS Simulator (CPU) instead wrote
  ~840 MB per configuration (`simulator.txt`).
- These are Mac numbers. iPhone Neural Engine latency, first-compile time and
  memory are unmeasured.
