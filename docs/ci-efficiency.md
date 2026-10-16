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
objects and app outputs on that runner. SwiftPM repositories, checkouts and
binary downloads are cached by job, runner architecture, selected Xcode and
package inputs; app build outputs are not cached. Xcode builds and native
macOS tests share the same SourcePackages directory.

Supported targets are ARM64 macOS, iOS devices and iOS simulators. The two
Intel release jobs and universal-library assembly have been removed. All
remaining slice revision/digest checks and existing test suites are retained.
New cache keys start cold; the runtime benefit still needs a successful warm
CI run. A cache hit does not remove simulator execution time.
