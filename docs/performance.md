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
