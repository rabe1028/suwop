# VRT CI lanes

Local `make vrt` remains the complete host and UI run. Recording is local and
requires explicit reviewed approval; CI never records baselines.

CI runs `make vrt-ci-host` (all host tests and 50 comparisons) and
`make vrt-ci-ui-1` … `make vrt-ci-ui-3` (UI test shards). Lanes never build.
The `apple-products` job runs `make simulator-products` once: the Rust
simulator library plus `build-for-testing` for the VRT and PhotoKit schemes.
It keeps only runtime bundles and xctestrun files, without static archives,
objects or modules. Its manifest binds the products to the HEAD, source fingerprint and
pinned environment. Each lane's `products` stage rejects products from any
other source and points the xctestrun's scheme environment at this lane's
baselines and artifacts, with recording off. Lanes then run
`test-without-building -xctestrun`, so they need neither Rust, SwiftPM
packages nor XcodeGen. Run locally without `SUWOP_SIMULATOR_PRODUCTS`, a lane
builds its own products first.

Every lane first enumerates the entire unfiltered built scheme. The `select` stage then
derives the lane's method IDs: the whole host bundle, or one shard of the UI
bundle. Shards are assigned longest-first from the measured seconds in
`VRT/ui-test-durations.json`; a test missing from that file counts as the
median, so new tests are always selected exactly once. Each lane must execute
exactly its selected IDs once, pass with zero skips, and retain the pinned
device/configuration. A lane report always says `full_suite_passed: false`.

UI tests dominate VRT time (61 tests took 2,732s serially in run
39049104153), so three shards run on separate macOS runners. The host lane runner
then runs `make apple-native-test` with the same products. PhotoKit service
changes therefore always follow that runner's screenshot comparisons. When tests are added
or change cost, refresh the durations from every UI shard's `compare.log`:
`uv run --no-project python scripts/vrt_lanes.py durations ui-*/compare.log`.
Stale durations only affect balance, never coverage.

The aggregate requires every raw lane result and report from the exact same
HEAD, source, environment, baseline hashes, workflow run and attempt. It also
recomputes each shard from the same registered inventory and durations, and
requires the UI shards to form an exact partition of the registered UI bundle.
It also requires the simulator matrix to succeed, including the unchanged PhotoKit
script and its existing phase/outcome gate. Missing, cancelled, duplicate,
failed or stale lanes cannot become a complete pass. Failed-only reruns can
therefore require rerunning all jobs; older successful attempts are not selected.

## Validation boundary

The xcresult parser uses real completed Xcode 26.4.1 JSON fixtures. Unfiltered
flat enumeration was captured after a matching Rust simulator build and normal
build-for-testing: 168 host and 61 UI method IDs. The adapter rejects disabled,
unknown, duplicate and malformed registrations. The fixture records schema and
IDs, not a permanent count; every lane enumerates its current built scheme.

Complete native lane runs and aggregate CI acceptance remain separate gates.
Pure Python checks and enumeration alone do not establish native success.
