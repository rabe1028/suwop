# VRT CI lanes

Local `make vrt` remains the complete host and UI run. Recording is local and
requires explicit reviewed approval; CI never records baselines.

CI runs `make vrt-ci-host` (all host tests and 50 comparisons) and
`make vrt-ci-ui` (all UI tests). Both first enumerate the entire unfiltered
built scheme. Each selected bundle must execute exactly its registered method
IDs once, pass with zero skips, and retain the pinned device/configuration.
A lane report always says `full_suite_passed: false`.

The aggregate requires both raw lane results and reports from the exact same
HEAD, source, environment, baseline hashes, workflow run and attempt. It also
requires the simulator matrix to succeed, including the unchanged PhotoKit
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
