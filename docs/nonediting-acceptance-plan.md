# Remaining non-editing acceptance

PP-15 and PP-16 remain open. Core/local tests, injected native-adapter tests,
Simulator PhotoKit, Mac native UI, physical devices, iCloud and hosted CI are
separate evidence categories. None substitutes for another. Editing is deferred.

## Permission and recovery

Foreground activation checks current read/write Photos authorization without
requesting permission. A changed status invalidates cached images and native
presentation contexts immediately. Native admission stays suspended until Rust
consumes `AppleChanged`; Rust then owns revocation and fresh scan authority.
Contexts captured during that handoff cannot revive when admission reopens.
The same handoff applies to asset membership notifications even when the Photos
authorization enum is unchanged. A failed invalidation stays closed and is
retried on the next foreground check, including an unchanged authorization.
A fresh Limited scan may enable permitted reading; it never establishes Full
transfer authority.

`ForegroundAuthorizationTests` uses a generated catalog, real Rust runtime and
held synthetic scan callbacks and an injected invalidation delivery failure. It
covers same-status retry, membership removal, unchanged authorization, denied scan
failure, pending Limited regrant, overlapping native handoffs, and non-revival
of old contexts. These are injected acceptance scenarios, not actual OS Photos
permission transitions. See the source-bound verification receipt for execution
status; test source alone is not a pass.

Remaining native cases need an isolated fixture host/library: initial denial,
limited membership selection/removal, Full to Limited to Denied while previewing,
permission changes while suspended, regrant without process restart, interrupted
scan, process restart and account/configuration change. Record the current
permission and exact generated fixture members before and after. Do not use a
personal library or change the user's host permissions for these tests.

Selection is ephemeral Rust state over physical `AssetKey`s. A current group
survives only when every member was already selected and remains authorized;
partial merges retire their keys before a later split can resurrect them. A
user's explicit group click may select all its current members. Search and sort
do not discard still-authorized selection. The Swift command queue preserves
rapid toggles and blocks selected actions until the queue settles.
`GallerySelectionUITests` exercises the actual view and generated favorite effect
keys across search, sort, merge/split and revocation. Execution status belongs to
its source-bound receipt; visible badges alone are not operation-key evidence.

## Performance and accessibility

Use the existing signposts, bounded local trace exporter and
`scripts/performance_report.py` described in [performance.md](performance.md).
The existing 50,000-key lookup benchmark does not represent a 50,000-photo
catalog. Use generated 10,000-photo and separate 100,000-photo stress cases.
Record machine/OS, optimization settings, fixture
size, cold/warm cache, elapsed time, first usable result, search/sort/publication
latency, preview completion, main-actor delay p95/max/over-100ms count and process
peak memory. Retain screenshots separately to establish actual rendered content.
Use independent processes for peak memory comparisons; overlapping spans are
not additive elapsed time. No benchmark threshold is a claim about iCloud or
remote cold-cache performance.

The opt-in Rust test `generated_catalog_publication_benchmark` constructs those
actual catalogs and measures full view generation plus JSON encoding, search,
sort, 100 selected keys and organization. Build the test once and run its
executable directly under `/usr/bin/time -l` in a fresh process; use
`SUWOP_BENCH_PHOTOS=10000` or `100000`. These debug measurements include no Swift
decode/render, native I/O, real photo data or iCloud. The first publication uses
a fresh process; later scenarios reuse that model. No OS cold-cache claim is made.

The recorded debug comparison on this Mac found quadratic ordinary-key lookup
in `public_descriptions`; one borrowed membership set removes that repeated
linear scan without changing authorization membership.

| Generated 10k scenario | Before index | After index |
| --- | ---: | ---: |
| First publication | 1.948 s | 1.206 s |
| Search update and publication | 2.990 s | 1.170 s |
| Sort update and publication | 2.007 s | 1.196 s |
| Selection update and publication | 3.326 s | 1.450 s |
| Organization update and publication | 3.507 s | 1.330 s |
| Whole process wall time | 14.50 s | 6.69 s |
| Process maximum RSS | 169.8 MiB | 170.7 MiB |

The 100k baseline was cancelled at 321.32 s without a completed scenario summary;
it is not a pass or a precise speedup baseline. The indexed 100k run completed in
68.62 s process wall time, with 12.740 s first publication and 1,128.2 MiB maximum
RSS. The host was not isolated: builds/integration or SwiftUI acceptance also ran.
Retain the raw timings rather than claiming a universal improvement percentage.
Release builds, main-actor/frame measurements and actual device memory remain
separate acceptance.

Ignored evidence under `.tools/nonediting-performance/` preserves distinct
`generated-10000-debug.json`, `generated-100000-debug-censored.json`, and
`generated-{10000,100000}-debug-indexed.json` reports with source/binary hashes,
machine/OS, process metrics and verification receipts. A one-second baseline
sample and AX3 layout diagnostics are retained separately in that directory.

Exercise Gallery, selection, organization and operation status with large text,
iPad/landscape and Mac keyboard navigation. Check control reachability, clipping,
focus order and selected announcements. Automated accessibility attributes and
screenshots do not establish actual VoiceOver usability; record a manual
VoiceOver pass separately on the selected devices.

## PP-16 read-only bundle preflight

Inspect one explicit built app without selecting an account or changing signing:

```sh
uv run --no-project python scripts/release_preflight.py /explicit/path/Suwop.app \
  --resource Contents/Resources --codesign
```

Omit the Mac resource example for iOS, or name required resources relative to that
bundle. The script checks plist identity/version/build/platform/Photos usage
strings, executable presence and mode, explicit required resources, and bundle
path containment. Executable path traversal and symlinks escaping the app fail.
Its deterministic SHA-256 includes relative entry names, content and mode. The
report contains hashes and counts rather than a resource-content manifest.

Optional `--codesign` invokes read-only verification/display and labels a
signature signed, ad-hoc or unsigned/invalid; a requested failed verification
fails the check. It never enumerates accounts, exports credentials, changes
signing settings, creates certificates/profiles, uploads builds or submits
notarization. Every report explicitly sets `distribution_ready` to false.
A local signature or unsigned Simulator build cannot establish distribution.
Eight temporary generated-bundle tests cover layout, hashes, usage/resource
requirements, traversal/symlink rejection and mocked read-only signature calls.
Execution status belongs to the source-bound verification receipt.

Entitlements, provisioning/notarization and distribution-specific eligibility
still need the chosen route's acceptance. Existing usage strings, bundle IDs,
Mac entitlements and unsigned Apple build checks remain preparation evidence.

External prerequisites are the chosen distribution route, authorized team and
provisioning/notarization capability, owned iPhone/iPad, an explicitly approved
small disposable Photos/iCloud library, and another device for synchronization.
Actual acceptance includes install/update with persisted-state migration,
bidirectional Copy, RAW/Live/burst and iCloud-only retrieval, offline/reconnect,
normal Move deleting only its verified source, and observation on the other
device. Each result needs exact app/build identity, OS/device, fixture manifest,
operation receipt, outcome and retained local artifacts. Until those resources
and results exist, PP-16 remains incomplete.
