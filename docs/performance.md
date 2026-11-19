# Library performance

Keep HTTP concurrency at most 32. Fetch completion must not be required for
search, thumbnails or previews. A partial snapshot remains Limited and cannot
authorize transfer or deletion.

## Capture real behavior

The native app emits Instruments signposts in subsystem `jp.rabe1028.suwop`,
category `Performance`. Capture **Time Profiler** and **Points of Interest**:
HTTP/native effects, Rust response resolution, full snapshot generation, UI
publication, thumbnail and preview loading have intervals. A 250 ms main-actor
probe records scheduling delay and emits a warning above 100 ms. This measures
UI scheduling responsiveness, not display-frame rate.

Set `SUWOP_PERFORMANCE_TRACE` to an absolute local JSON path when launching a
diagnostic app. The app exports a bounded Perfetto/Chrome trace every ten seconds
and after effect processing. Open it in a local trace viewer. No collector,
network exporter, endpoint, API key, photo identifier, filename or image content
is included. Instruments recordings can contain process/environment details;
keep real-library recordings local and inspect before sharing.

```sh
uv run --no-project python scripts/performance_report.py after.json \
  --before before.json --max-ui-delay-p95-ms 100 --max-preview-p95-ms 1000
```

Missing requested metrics and truncated traces fail the report. The preview
threshold is an initial diagnostic target, not a promise for remote cold-cache
images. Retain p95, maximum and over-100ms counts, not only average throughput.
Overlapping spans must not be added together as elapsed time.

`previewRequest` and `thumbnailRequest` include authority checks, cache lookup,
loading and final validation. `imageAuthority` isolates authority checks;
`previewImage` and `thumbnail` measure the loading portion only. Use
`--max-preview-request-p95-ms` to gate the complete request. These still end
before SwiftUI paints the image, so retain screenshot evidence.

`snapshotRuntime` measures view generation and decoding inside the RustRuntime
actor. The outer `snapshot` also includes waiting for that actor and publishing
the view; `publish` measures the latter. Compare these nested intervals to locate
waiting versus processing. `snapshotBridge` covers the synchronous Rust call and
FFI output copy (including the Rust registry lock wait); `snapshotDecode` covers typed Swift JSON decoding. Both use the
same monotonic clock as `snapshotRuntime`, without exporting catalog contents.
Trace exports are written in capture order. Use
`--max-snapshot-runtime-p95-ms` for a scenario-specific full snapshot latency gate;
a fast component alone cannot satisfy it.

## Compare

Use the same machine, Swift/Rust optimization settings, server, fixture size,
network and warm/cold-cache state. Record first usable results, completed
records per second, time until a selected preview is visible, UI scheduling
delay, and memory. Exercise search, scroll, preview and return during retrieval.
Trace thumbnail/preview completion establishes load latency; retain screenshots
to separately establish that the image actually rendered.

`LibraryPerformanceTests` compares old linear lookup and indexed lookup on the
same 50,000-key dataset and checks that progress does not invalidate the gallery.
`EffectBatchTests` holds one request open while testing slot refill, the 32-slot
limit and native-effect barriers. Local benchmark gains are not whole-sync gains.
Run the normal correctness and VRT gates as well.

The pre-fix live baseline and profiles are in ignored
`.tools/verification/large-library-native/`. Full catalog snapshots still exist
at publication boundaries; use the `snapshot` and `publish` spans to assess their
remaining cost before changing the Rust/native projection contract.

## Generated native Gallery benchmark

From a Suwop checkout with the pinned tools, Xcode and Simulator runtime in
`VRT/environment.json`, run the opt-in benchmark on Apple Silicon.

```sh
uv run --no-project python scripts/verify.py run --label gallery-performance -- make gallery-performance
```

The driver builds the Release Swift host and Release Rust simulator slice.
The Rust target and locked Cargo dependencies must already be available
locally. For one independent run, replace `make gallery-performance` with
`bash scripts/gallery-performance.sh 10000` or
`bash scripts/gallery-performance.sh 100000`. It archives its Rust simulator slice and
restores the checkout’s prior XCFramework after the run. It waits for a fresh
Simulator of the pinned device type to finish booting before XCTest runs.
The driver shuts down that Simulator at the end. Each size launches the app
in a fresh process on the same Simulator. Run it without competing
builds or Simulator tests for results intended for comparison.

The app generates distinct Apple-provider records with fixed capture dates
and prepares 32-record Limited and full native scan replies. The fixture
generates two in-memory rasters. It feeds those replies through the existing
native effect seams into the real `RustRuntime`, `LibraryModel`, and
`GalleryView`. PhotoKit, Immich, credentials, network, and on-disk catalog
persistence are outside this scenario. Catalog persistence is acknowledged in
memory. Swift image preparation and app-owned cache limits are active.
The shared synthetic raster per image size makes pixel verification
reproducible and limits the workload represented by the image pipeline.

XCTest waits for the first thumbnail raster, checks the exact full catalog
count and initial order, opens and closes the first preview, types a name
query with three matching records, then returns to the library and changes
the full catalog to oldest-first. It checks visible order using real grid
positions. Four PNG screenshots back the thumbnail, preview, search and sort
observations. A two-pixel color check on each screenshot identifies the
generated raster. The XCTest timings include input delivery, accessibility
queries, polling and screenshot capture. The first raster is an observed
upper bound. The partial preview can complete before XCTest reaches the
screen, so the report records the size of the first published view separately.
For search and sort, the trace also measures from XCTest input to the end
of the corresponding app publication.

Look under `DerivedData/GalleryPerformance/run.*` for each size's app and test
timelines, raw trace, summarized trace, screenshots, and `Test.xcresult`.
`report.json` ties successful cases to the checkout fingerprint, host
executable and Rust archive hashes, simulator, Xcode, OS, machine and
compiler settings. The app-process peak RSS uses
`getrusage(RUSAGE_SELF).ru_maxrss` in bytes as documented by Darwin
`getrusage(2)`. RSS covers the whole app process through the final sample,
including fixture creation. The isolated fixture-generation interval ends
before the timed Rust initialization and refresh. Scan reply handoff, input
encoding and Rust integration remain part of the refresh. The trace splits
the later snapshot bridge, typed Swift decoding, presentation preparation
and publication. The trace includes main-actor probe p95, maximum and
over-100 ms count. `CADisplayLink` records main-thread callback intervals
from the timed scenario start, capped at 100,000 intervals with the cap
reported explicitly. These intervals measure callback scheduling. They do not
establish composited frames per second or physical-device performance.

The driver has completion watchdogs and checks that the required evidence
exists. The benchmark defines no performance thresholds. Regular VRT,
hosted CI, physical-device memory and real-library acceptance run separately.
