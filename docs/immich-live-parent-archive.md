# Selected Live Photo parent placement

This increment permits ordinary Timeline/Archive changes to the selected Immich
IMAGE parent P. It does not expand a change to its linked motion M or another
parent, request PIN elevation, read M through the product operation, or claim
pair-wide privacy. PIN Live Photo operations remain unsupported.

Rust validates the exact parent key, own checksum, explicit forward child ID,
unstacked shape and fresh revision. The relation is identity evidence for this
placement operation only: it proves neither child ownership nor readable content.
Aggregate inventory completeness and transfer/deletion restrictions are unchanged.
The linked-parent digest has its own domain; existing IMAGE/VIDEO digests remain
unchanged. Shared durable fences compare witnesses by operation kind and preserve
unresolved outcomes without retrying a write.

The shared confirmation says that only the selected item's Immich placement
changes, and that related photos and videos retain their placement. Native tests
exercise the actual Rust boundary; fixture assertions distinguish product reads
from independent acceptance-control reads.

## Local verification in progress, 2026-10-15

The working source is based on VIDEO `84c28d7`. Subsequent history-only rebasing of
VIDEO to `6b8a3f6` preserved its entire tree. This increment is not committed or
merged yet.

It was subsequently rebased to VIDEO `55c5cff`, including the initial-scan
revision-race fixture correction. All 408 source files were backed up before
rebasing; the only overlap was the integration fixture. The resolution preserves
selected-target diagnostics, initial read-only recovery, counters and the native
pair case, with exact resource-shape checks per fixture. All 46 baseline hashes
remain unchanged. Full check then passed Rust/FFI342 and Swift65 in
`/tmp/suwop-live-parent-check-20261015-3.log`.

The first nine-case integration run passed the existing eight cases but failed
the native-pair case during pre-operation album-membership controls, before a
product mutation. `/tmp/suwop-live-parent-integration-20261015-2.log` and
`/tmp/suwop-native-live-downloads-20261015-1/before/` retain that evidence. Native
metadata processing and setup ordering are under investigation; this run is not
a nine-case pass and does not establish a completed native-byte roundtrip.

- Targeted Rust tests: 46 passed in
  `/tmp/suwop-live-parent-targeted-20261015-2.log`.
- Full `make check`: Rust/FFI 341 and Swift 65 passed, including lint and generated
  type consistency, in `/tmp/suwop-live-parent-check-20261015-2.log`.
  The first check stopped on formatting in two fixture tools; that failed log is
  retained separately and is not counted as a pass.
- Isolated Immich integration: 8/8 passed in
  `/tmp/suwop-live-parent-integration-20261015-1.log`. A PIN-unset API-linked fixture
  verifies P-only Timeline/Archive writes, M remaining hidden, the other parent
  remaining in Timeline, exact original bytes and known album memberships. Product
  authentication and child reads are zero; exactly two writes target P alone.
  Dedicated containers, volumes and network were removed; the unrelated service
  was retained. This fixture establishes an API relation, not native Live playback.
- `Tests/fixtures/native_live_pair/` contains synthetic JPEG/MOV originals with a
  shared embedded identifier and timed still-image metadata. Standalone generator
  and independent verifier compiled and ran successfully. Fixed files match the
  manifest; regeneration preserves the metadata contract but is not promised to
  reproduce identical container bytes. Evidence is in
  `/tmp/suwop-live-parent-native-validation-c3NvYu/`.
- Apple builds passed for all five Rust targets, XCFramework, iOS and macOS in
  `/tmp/suwop-live-parent-apple1-20261015.log`.
- Targeted native/UI acceptance passed: host 8 and UI 6, including the two new
  parent host cases and normal/AX3 parent interactions, in
  `/tmp/suwop-live-parent-target3-20261015.log` and its result bundle. Two prior
  compile failures in test-only JSON comparisons remain in target1/target2 logs;
  no product behavior was changed to resolve them. The reviewer inspected the
  exported normal Timeline and AX3 Archive confirmations: scope text and actions
  remain readable and reachable. This is not visual-baseline approval.
- Metadata-bearing originals through Immich,
  reviewed visual candidates, strict VRT and hosted CI are still pending.

No PhotoKit import, PHLivePhoto rendering, physical-device playback, camera
authenticity or iCloud acceptance is claimed by these fixtures. Existing 46 visual
baselines remain unchanged; candidate capture is paused pending the native API contract correction.

## Retained predecessor evidence

PR #27 was merged as `8767d77` with the same tree as its verified HEAD `4cd7577`.
Its idle worktree was archived through the managed worktree tool after preserving
all DerivedData and the generated Xcode project under
`/Users/rabe1028/disk-cleanup-20261015/preserved/immich-archive-actions-merged-20261015/`.
The retention manifest records branch, HEAD, main and matching tree; 21,910 files
were SHA-256 compared before removal. The source also has a retained Git ref and
a recoverable managed snapshot. Historical absolute paths in predecessor records
should be resolved through this retained directory or a restored worktree.


## Native metadata failure and implementation hold

The API-linked eight-case success above does not establish the contract for
embedded Live metadata. Full nine-case runs failed the native case:
`/tmp/suwop-live-parent-integration-20261015-2.log` failed before the product
operation; after an exact initial metadata checkpoint was added,
`/tmp/suwop-live-parent-integration-20261015-3.log` passed initial memberships but
failed motion membership preservation after the selected parent's archive.
Neither failure was waived. An intervening narrow probe passed its immediate
observations, but does not outweigh the later asynchronous failure.

The separate probe `/tmp/suwop-native-effects-evidence-20261015-1` and pinned
v3.2.4 service source establish the distinction: bulk visibility writes enqueue
sidecar/metadata processing, which can relink the native pair, force motion
hidden and remove its albums. The observed motion lock reversal followed its
own queued job; a later parent write against a stable locked motion was skipped
because that prerequisite could not be established. Original bytes were retained.

PR29 is being corrected first: ordinary actions use a visibility-only single
asset PUT, whose pinned service path does not enqueue this processing. Its new
native-motion product case and existing seven integrations passed, separately
from this parent implementation. This worktree now inherits the reviewed single route at `d2746a5`; parent
acceptance is being rerun against that corrected boundary.
Native parent feature merge, visual candidates and new baselines remain held.
Earlier host/UI success is a mock-boundary result, not evidence that the native
metadata side effect is resolved. The separate IMAGE/PIN null-forward CID risk
is source-supported but not yet reproduced through the product; do not describe
it as observed loss of the selected IMAGE's own protection.


## Single-route base integration

The worktree was rebased onto PR29 `d2746a5` after backing up 409 source files,
tracked diff, HEAD and a retained stash. The backup is
`/var/folders/s9/54l8z3cn6h32j1wqrr6lx9_h0000gn/T/suwop-live-parent-before-single-route-20261016-b4pp8u9k`.
Before conflict resolution, comparison found no missing files; the canonical
native media/provenance package and all 46 baselines were byte-identical. Four
Rust/harness conflicts were resolved preserving both native-motion acceptance
from the base and API/native parent acceptance. Native parent tests now assert
the exact selected URL, visibility-only body and two HTTP200 responses.
Native motion and native parent evidence use separate subdirectories so their
create-new checkpoint records do not collide. Full checks and ten real-server
cases are being rerun; previous bulk-route results are not counted as corrected
parent acceptance.

The predecessor PR28 merge `700ce6b` has also passed all four post-merge CI jobs:
https://github.com/rabe1028/suwop/actions/runs/38751403708.


Corrected-source verification passed targeted Rust47 and full check Rust/FFI343
plus Swift65 (ten real cases ignored in that unit invocation). Final log:
`/tmp/suwop-live-parent-single-check-20261016-5.log`. Earlier attempts are retained:
check1 caught a missing NativeMotion match arm during integration, check2 a
helper-length lint, check3 passed before control strengthening, and check4 caught
a test JSON syntax error. No failed attempt is counted as final acceptance.

The corrected complete real suite passed 10/10 in 29.21 seconds:
`/tmp/suwop-live-parent-single-integration-20261016-1.log`. These are the inherited
eight cases plus API-linked and native-metadata parent cases; exploratory C2
probes are excluded. Native parent P moves Timeline -> Archive -> Timeline while
M remains hidden and P2 remains Timeline. The native-motion case separately moves
M Timeline -> Archive -> Timeline while P remains Timeline and P2 Archive. At
all six observation stages, each asset retains exactly the two fixture albums,
links, identity and original bytes. Parent independently parsed the six stage
records and matched all six downloaded JPEG/MOV pairs to canonical SHA256.
Evidence is `/tmp/suwop-live-parent-single-evidence-20261016-1/{parent,motion}`.
Dedicated containers, volumes and network were removed; the unrelated service
was retained. The older bulk-route failure is resolved for these ordinary
operations; this does not resolve the separately reproduced PIN/share limits.

Fresh Apple build passed all five Rust targets, XCFramework generation and iOS/macOS
builds (`/tmp/suwop-live-parent-single-route-apple1-20261016.log`). Targeted native
acceptance passed host16 and UI6, including normal/AX3 parent confirmation and
scrolling/full-guidance/action containment
(`/tmp/suwop-live-parent-single-route-target1-20261016.log`).

The record-disabled candidate run captured 46 screens: 44 matched and only the
two archive confirmation screens differed because the disclosure now includes
related videos. This expected comparison failure is not a strict VRT pass.
Parent reviewed normal and AX3 expected/actual/diff images before approving only
`immich-archive-confirmation` and `immich-archive-confirmation-large-text` updates.
The other 44 baseline hashes remain unchanged. Review and old/new SHA256 records:
`/tmp/suwop-live-parent-vrt-review-20261016.md` and
`/tmp/suwop-live-parent-approved-wording-baseline-record-20261016.json`.
Full strict VRT is running with recording disabled; hosted CI and merge remain
incomplete. These simulator/synthetic-server results do not establish actual
PhotoKit/device acceptance.


PR29 exact HEAD `d2746a5` passed all four hosted jobs in run38758342144 and had no
unresolved review threads. It merged as `d91269e`; main was fast-forwarded and
the merge tree equals the tested head tree. Post-merge run38763928780 remains
pending. This parent worktree is not rebased while strict VRT is in flight.


## Final local acceptance on merged base

Strict VRT completed successfully with recording disabled:
`DerivedData/VRTArtifacts/20261015T153824Z-61911/report.json` and
`/tmp/suwop-live-parent-single-route-strict1-20261016.log`.
All seven stages passed; host79 and UI43 had zero failures. All 46 actual screens
matched, and all baseline hashes stayed unchanged during this strict run.
Parent independently checked the report, test counts, and the reviewed baseline
receipt (exactly two intentional changes from the prior base, other 44 unchanged).

After terminal success, the uncommitted branch was moved to merged main `d91269e`
using a soft reset between identical trees. All 410 source files matched their
pre-operation SHA256 backup before and after. Recovery evidence is
`/tmp/suwop-live-parent-pre-main-rebase-20261016-1`, including source archive,
manifest, prior HEAD/diff and history-alignment receipt. No source or baseline
content changed during alignment. Hosted CI and merge of this parent increment
remain pending.
