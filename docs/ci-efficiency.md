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
and release tests, five Apple target builds, bridge/sharing tests, full VRT
coverage and PhotoKit acceptance remain enabled. This change does not claim
device/iCloud acceptance or a measured token-reduction percentage.

The active PIN-write PR also edits `ci.yml` to add Immich 3.3.3 coverage.
When integrating the branches, retain both release checks and their evidence
upload along with the cache/pull changes; do not resolve by replacing the
whole workflow with either branch's version.
