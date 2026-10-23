# CI and validation efficiency

Baseline: [successful run 38781173202](https://github.com/rabe1028/suwop/actions/runs/38781173202),
main `3417b0b`, 2026-10-16 JST. GitHub job timestamps show core 5m29s,
Apple 12m40s, integration 1m54s and VRT/PhotoKit 39m23s. Within the last
job, VRT took 34m08s and PhotoKit 4m44s. These are baseline observations,
not measurements of this change.

## Changes

- SHA-pinned Rust caching in each job retains dependency builds. Cache identity
  includes the job, OS/architecture, toolchain, Cargo inputs and Apple SDK
  environment. Workspace source is rebuilt; generated DTO checks still run.
- Full VRT and PhotoKit suites run on separate pinned macOS runners. Their
  device profiles and local locking remain unchanged. The existing `vrt`
  check succeeds only if both matrix legs succeed, including when another leg
  fails or is cancelled. Distinct artifact names retain both evidence sets.
  Parallelism removes the serial PhotoKit stage from the critical path when
  runner capacity is available, but uses an additional runner and cold setup.
- Explicit image acquisition retries only registry throttling, at most three
  attempts with 10s/20s waits. Other failures return immediately. Compose starts
  with `--pull never` after acquisition; test/fixture mutations are not retried.
  PR #33 job 116668677559 reported GHCR `immich-server` throttling; this was
  not evidence of a Docker Hub account quota.
- `make test-infra` exercises the validation runner and acquisition retries
  without Xcode, Rust compilation or a live server. It is also in `make test`.
- `scripts/verify.py run --label check -- make check` stores full logs plus
  command, source fingerprint, selected environment, duration and exit status.
  `ci RUN_ID --expected-head SHA` provides compact exact-head CI snapshots.
  The helper does not cache test success, change hooks, or bypass gates.

The project skill in `.agents/skills/suwop-validation/SKILL.md` explains
focused iteration, final gates, bounded output, checkpoints and CI follow-up.
No global/plugin-owned instructions need modification.

## Measuring the result

Compare cold and warm successful runs on the same suite revision. Record
cache restore/save time, job execution time and queue time separately. New
tests in dependent PRs can increase runtime independently. All Rust debug
and release tests, the supported Apple target builds, bridge/sharing tests, full VRT
coverage and PhotoKit acceptance remain enabled. This change does not claim
device/iCloud acceptance or a measured token-reduction percentage.

The active PIN-write PR also edits `ci.yml` to add Immich 3.3.3 coverage.
When integrating the branches, retain both release checks and their evidence
upload along with the cache/pull changes; do not resolve by replacing the
whole workflow with either branch's version.

## Apple Silicon and cache follow-up

[Successful run 38864174445](https://github.com/rabe1028/suwop/actions/runs/38864174445)
on main `14e1bcc` provides a newer baseline after the Lance integration:

| Job | Observed cache | Observed build time |
| --- | --- | --- |
| ARM64 macOS release slice | Exact hit, 649 MB restored | Rust release: 1m30s |
| Apple host tests and apps | Exact hit, 101 MB restored | Rust test compilation: 12m37s; host FFI: 4m45s; whole job: 29m15s |
| Simulator VRT | Exact hit, 678 MB restored | Whole job: 45m32s, including simulator tests |

The Apple job ran `cargo clean` after testing (5.2 GiB removed), before the
cache action saved its result. A hit therefore restored downloads but did not
retain the compiled dependencies needed by the next run. It also fetched
LiteRT-LM sources and binary artifacts without a persistent Swift package cache.

Host tests now run in `apple-tests`, preserving their Rust dependency objects
under a fresh cache key. App packaging runs on a separate runner after the
host tests and release slices pass, avoiding concurrent storage of large debug
objects and app outputs on that runner. SwiftPM's shared repository and binary
download caches are keyed by OS, architecture and package inputs, and reused
across Apple jobs. These raw downloads are independent of the selected Xcode;
manifests, build state and app outputs are not cached. Per-workspace clones
are deliberately excluded: LiteRT-LM alone used 2.7 GiB in `.build/repositories`,
duplicating the shared cache. Xcode builds and native macOS tests also share
the same SourcePackages directory within each job.

Supported targets are ARM64 macOS, iOS devices and iOS simulators. The two
Intel release jobs and universal-library assembly have been removed. All
remaining slice revision/digest checks and existing test suites are retained.
New cache keys start cold; the runtime benefit still needs a successful warm
CI run. A cache hit does not remove simulator execution time.

## Critical-path split (2026-10)

Successful main runs 39049104153 and 39005354809 took 50–60 minutes. Two jobs
formed the critical path:

| Job | Time | Cause |
| --- | --- | --- |
| `simulator (vrt-ci-ui)` | 50–57m | 61 UI tests ran serially for 2,732s on one simulator |
| `core` | 33–39m | `cargo clean` then an uncached release build (24m21s); test execution took seconds |

Within the release build, `suwop-core` took about 17 minutes: Cargo built each
of its 35 `tests/*.rs` files as a separate optimized binary, each linking the
library and re-instantiating its generics.

Changes:

- UI tests run as three duration-balanced shards on separate macOS runners
  (see [VRT CI lanes](vrt-ci-lanes.md)). The aggregate still requires the
  shards to cover the registered UI bundle exactly once.
- `lint`, `core (debug)` and `core (release)` run in parallel with separate
  caches. The release job keeps its own dependency cache instead of cleaning
  the debug build, and Linux jobs use four Cargo jobs.
- Offline `suwop-core` integration tests are modules of one `tests/suite`
  binary. `immich_live` stays separate for `make integration`.
  `scripts/check-architecture.py` rejects a suite file not declared in
  `suite/main.rs`, so a new test file cannot silently stop running.
- Only `main` saves Rust caches. On 2026-10-22 the repository held 11.0 GB
  of caches against the 10 GB limit: every PR merge ref saved its own
  650–750 MB caches, main's Rust caches had been evicted, and PR jobs such as
  the Apple release slices rebuilt dependencies cold (42 minutes instead of
  about 3). PRs now restore main's caches without writing their own.
- `make test-rust` runs tests with cargo-nextest (pinned in
  `mise.toml`, no retries) and doctests with `cargo test --doc`.
  `RUST_TEST_ARGS=--release` runs the release suite.

A local warm rebuild after touching `suwop-core` (Apple M-series,
`CARGO_BUILD_JOBS=4`, `cargo test --no-run`) took 159s → 110s for release and
24s → 21s for debug. Test binaries dropped from 37 to 7. These are local
measurements; hosted CI time still needs a successful warm run on main.

## macOS only where Apple tooling is required

macOS runners are limited to five concurrent jobs per account. PR #45 run
39756208393 (attempt 1) shows the effect: other branches' runs held the slots,
so its macOS jobs queued for 90–130 minutes and the run took 160 minutes.
Ten macOS jobs per run each set up Rust, SwiftPM and Xcode, and the same Rust
simulator library and VRT test bundle were built in every simulator lane.

The workflow now has these macOS jobs:

| Job | Runner | Work |
| --- | --- | --- |
| `apple-rust` ×3 | macos-15 | One release slice each (about 3 minutes warm) |
| `apple` | macos-15 | Rust-to-Swift bridge tests, iOS/macOS apps from the slices, macOS sharing/private media tests |
| `apple-products` | macos-26 | Rust simulator library and VRT/PhotoKit `build-for-testing`, once |
| `simulator` ×4 | macos-26 | `vrt-ci-ui-1`…`vrt-ci-ui-3`, and `vrt-ci-host` followed by PhotoKit acceptance; prebuilt products only |

With warm caches, the slice jobs finish before the simulator lanes start, so
at most five macOS jobs run at once for one workflow run. The slices stay in
separate jobs because a cold slice takes about 40 minutes on macos-15. PR #45
run 39823100151 built all three in one job; it hit the 90-minute timeout, and
a timed-out job saves no cache, so later runs would stay cold.

Work moved off macOS or removed from it:

- macOS no longer repeats the Rust test suite or the repository tool/hook
  tests; Linux runs them. The Swift tests still exercise the real Rust library.
- Simulator lanes no longer install Rust, restore Rust or SwiftPM caches
  (2.8 GB), or run XcodeGen or Xcode builds. They download about 160 MB of
  products and run `test-without-building -xctestrun`.
- The host-test and app-packaging jobs are one `apple` job.
- Swift lint runs on Linux (`swift-lint`) in the pinned `swift:6.2-noble`
  image, whose `libsourcekitdInProc` the dynamic SwiftLint build loads. Do not
  use `swiftlint-static` or a runner without SourceKit: it skips
  `custom_rules` and `statement_position` and still exits 0. With SourceKit,
  an injected `@unchecked Sendable` and a misplaced `else` failed on Linux
  exactly as on macOS, and the repository passed on both.

Kept on macOS deliberately:

- `swift test`: the package imports CoreGraphics, ImageIO,
  UniformTypeIdentifiers and LiteRT-LM's Apple binary, and its tests use
  AVFoundation, CoreMedia and CryptoKit. None of these exist on Linux.
- Rust Apple libraries. When this was measured, six dependencies compiled C
  (`blake3`, `lance-linalg`, `libsqlite3-sys`, `lz4-sys`, `ring`, `zstd-sys`)
  and `lance-arrow` needed Apple-only link stubs, so a Linux cross-build
  stopped. Schema 5 removed Lance; only `libsqlite3-sys` still compiles C. Zig
  can build it for iOS only by forcing its macOS libc headers onto iOS targets,
  which Zig does not support, and it would test a library built by a different
  C compiler than developers and releases use. Re-measure before revisiting.

## Resource metrics (2026-10)

Every job except the `vrt` aggregate runs `.github/actions/ci-metrics`. It
samples CPU, memory, swap, disk, network and the busiest processes in the
background (Linux `/proc` every 2s, macOS `top` frames) and uploads them as
`ci-metrics-<job>-<attempt>`. To see each step's use:

```sh
uv run --no-project python scripts/ci_metrics.py RUN_ID [--attempt N]
```

The first warm run, [39895970992](https://github.com/rabe1028/suwop/actions/runs/39895970992),
took 35.4 minutes. The critical path was `apple-products` (7.9m), then
`simulator (vrt-ci-ui-1)` (27.1m).

| Finding | Evidence | Change |
| --- | --- | --- |
| UI lanes are latency-bound, not CPU-bound | 52–58% of 3 CPUs; `compare` took 1,454s and 1,276s of each lane | Three UI shards; the expected loads are 889, 887 and 889s for 68 tests |
| Spotlight competes with builds on 3-CPU macOS runners | `mds_stores`/`mdworker` took 50–80% of a core during `apple` builds (93–99% CPU) and cache restores | `sudo mdutil -a -i off` first in every macOS job |
| UI test time is mostly app idle waits | Of 2,662s of XCUITest activity, 31% was "Wait for app to idle" (471 waits over 1s, mean 1.5s). Explicit waits took about 1s each; none timed out | The VRT host disables UIKit animations when XCUITest launches it (not as a unit-test host). Locally, the 68 UI tests took 2,347s → 1,891s (−19.4%) and idle waits 759s → 329s. One test swiped down before its raster loaded and dismissed the sheet; it now waits for the loading spinner to disappear |
| Each lane enumerates the same products (32–50s) | Lane `enumerate` stages | Tried and reverted. Enumerating in `apple-products` beside the PhotoKit build first swapped with a stock simulator (13.4m, run 39919532380). With a slim simulator it still competed for the 3 CPUs (10.5m vs 7.3m, run 39925771974). That cost more than the ~40s each lane saved |
| Linux Rust jobs are CPU-bound | `core (release)` used 92% of 4 CPUs (`rustc`) | Already parallel and cached |
| macOS memory | About 6.9 of 7 GiB is in use, with no swapouts | None; file cache counts as used |
