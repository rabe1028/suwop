---
name: suwop-validation
description: Run Suwop checks, investigate CI failures, and resume long implementation tasks with compact evidence and complete logs. Use for Suwop validation and CI follow-up.
---

Use the current checkout's tools. Read AGENTS.md for required gates; this skill
does not waive them or replace native/device acceptance.

## Local iteration

Run all Python through `uv run --no-project python`; use `uv venv` and `uv pip`
for environment/package operations.

- Find the affected test once with `rg`; run that Rust test target/filter or
  Swift test filter while editing. Run the complete required gates after the
  final relevant edit. Avoid rerunning a whole suite just to read its outcome.
- Wrap long commands: `uv run --no-project python scripts/verify.py run --label check -- make check`.
  The first line names a result JSON. Keep the tool's process/session ID, wait on
  that process, and read the completed JSON once. Full output stays in its log.
  A failed command returns its exit code and at most 30 lines / 6 KB of output.
- `source_changed` (exit 3) is not a valid pass. Check the recorded command,
  checkout, HEAD, source hash and environment before citing any result. The
  hash includes tracked files, deletions and nonignored untracked files; it
  excludes ignored generated/build files. It cannot detect transient changes
  reverted during execution or changes to external tools. Freeze relevant
  inputs throughout a final check. No automatic pass reuse is implemented.
- Use `make test-infra` for validation-tool/registry-retry changes. Keep normal
  commit/push hooks enabled. Budget for their checks; do not repeat the same
  manual lint/test solely because the hook is about to run.
- Do not share mutable `target`, DerivedData, generated DTOs or XCFramework
  output between active worktrees. Preserve logs and source when disk is low.
- Commands and raw logs may contain sensitive data. Keep credentials out of
  command arguments; inspect/redact relevant excerpts before sharing artifacts.

## CI follow-up

- Resolve the exact run and head once. Use
  `uv run --no-project python scripts/verify.py ci RUN_ID --expected-head FULL_SHA` for one compact
  snapshot. Exit 0 = completed success, 1 = completed failure, 2 = pending,
  3 = wrong head. It never retries jobs, mutates PRs, or treats pending as green.
- Preserve run ID, expected SHA, failed job ID and log path in the task's small
  checkpoint. Do useful independent work between checks. Avoid repeated full
  job/step JSON, `tail` loops, or narration when nothing changed. On failure,
  download the specific failed job log once and search locally.
- Registry acquisition retries are bounded inside `pull-test-images.sh`.
  If exhausted, distinguish environment failure from test failure. Do not
  repeatedly rerun the workflow or replay mutation tests to obtain a pass.
- `vrt` aggregates both simulator suites. Neither a single green matrix leg
  nor unchanged baseline images alone proves complete acceptance.

## Resuming work

Keep one short checkpoint in the task or its existing project document:
checkout/branch, current objective, next action, changed files, completed
checks with result paths, active session/run IDs and unresolved decisions.
Update it at a meaningful milestone. Read that checkpoint and current Git
status before loading old conversation bodies. For referenced chats, call
`read_thread` with a small turn limit and `includeOutputs:false`, then select
only relevant messages/commands from the result. Load older turns or raw
outputs only for a specific unanswered question.

Report local checks, hosted CI, simulator acceptance and actual device/iCloud
evidence separately. Token and elapsed-time savings need measurements; fewer
tool calls alone are not proof of a particular percentage.
