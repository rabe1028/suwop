# Immich selected-original observation recovery

When an IMAGE is locked through C2, Immich can subsequently link that same
original to a motion asset. The original lock operation's immutable witness
requires an unlinked image; the former Inspect path rejected the changed graph
and could not report the selected original's current state. This increment adds
a separate authenticated read observation without authorizing another mutation.

## Authority and persistence

Rust owns the parser, identity checks, journal migration, read proofs and fences.
Swift presents the resulting status and executes existing native I/O. Generated
DTOs come from `make generate-types`.

Schema8 adds optional `selectedObservation` to the operation. It records the
selected own-identity digest, observed visibility and configuration (unlinked,
linked, stacked or unverified), with a configuration digest only when validated.
Old operations retain their original witness, outcome and matching-configuration
observation. Ordinary legacy schemas migrate without invented evidence; a
pre8 record carrying non-null schema8 evidence is rejected. The authenticated
summary exposes visibility/configuration, not digests, filenames or child IDs.

Inspect validates the exact selected key, account/owner, IMAGE type, own checksum
and current visibility. Reconstructing the historical IMAGE witness verifies
only its own-identity components; it does not assert that the former null graph
is still current. There are no related-original requests and no PUT. A new
full original-policy matching observation supersedes fallback evidence.

Inspection invalidates only the selected preview and pending ticket, retaining
the row on failure. Unrelated keys are untouched. A fresh, durably recorded
locked observation with known configuration can create an ephemeral read proof
for an old Unknown operation. It is bound to the exact operation, identity,
configuration, current scene, grant and generation. Native preview reads verify
fresh facts before and after I/O; link/stack/type or access drift rejects them.
Close, reauthentication, Refresh and authenticated Recover clear these proofs.
Saved evidence alone never grants C1 reading after restart or recovery.

Fallback evidence keeps ordinary content, mutation, transfer and deletion fenced.
Both hints and direct Prepare enforce the restriction. An unlocked changed-graph
observation is history-only in this increment. Restoring ordinary presentation
requires a later explicit read-only permission and fresh-scan contract; this
increment does not claim that work complete.

## User-facing behavior

History distinguishes the original operation result from the selected original's
last observed visibility and configuration. The lock confirmation explicitly
states that existing shared links may continue to display/download this original
and are not automatically revoked. Album-removal consequences remain separate.
This disclosure is shared by iOS, macOS and fallback confirmation paths.

## Evidence and limits

The prior isolated actual-C2 probe against3.2.4 reproduced a null-forward native
IMAGE becoming linked after lock while its motion lost album membership. A
separate3.3.3 probe observed the pure-visibility enqueue trigger removed over a
bounded queue/timestamp observation interval, but the pre-existing individual
share key still returned the locked original. Evidence:
`/tmp/suwop-cid-image-probe-evidence-20261016-1` and
`/tmp/suwop-v333-c2-probe-20261016-1/RESULT.md`.
These server observations motivate recovery and disclosure; they do not prove
all external access revoked or future metadata jobs safe.

Current local verification: generated DTOs succeeded on attempt2; focused
selected-observation regressions passed15/15 on attempt2. The first focused run
caught authenticated Recover not clearing a proof when persistence was already
certain; it was corrected without releasing mutation fences. Full check attempt5 passed Rust352 and Swift65, including static checks and
generated reproducibility. Attempts1–4 stopped on style/import/test-helper issues
and remain preserved. This result precedes the later PR30 base alignment and
additional native capture sources, so it is not the final integrated-source gate. Failed attempts are retained under
`/tmp/suwop-selected-observation-*20261016-*.log`.
After alignment onto PR30 `09cee1c`, the full check passed Rust359 and Swift65,
including static checks and generated reproducibility; the focused visibility
suite passed46/46. Full Apple build attempt1 passed all five Rust targets, the
XCFramework, iOS and macOS applications. Logs are
`/tmp/suwop-selected-observation-aligned-check-20261016-1.log` and
`/tmp/suwop-selected-observation-apple-20261016-1.log`.
Targeted native checks also passed: macOS NSAlert14/14, iOS host11/11 and
iOS UI4/4, including selected-observation history at normal/AX3 text sizes,
existing lost-response recovery and the full lock disclosure at AX3. Logs:
`/tmp/suwop-selected-observation-mac-20261016-1.log` and
`/tmp/suwop-selected-observation-target-20261016-1.log`.
All48 visual candidates were reviewed: the two existing lock confirmations
changed only for the share disclosure, and two new selected-history captures
were added. The44 other baseline files remained byte-identical. The first
history capture framed the roster instead of history; capture-only scrolling
was corrected and the reviewed normal/AX3 images were recorded. Receipt:
`/tmp/suwop-selected-observation-approved-baseline-record-20261016-1.json`.
Final integrated `make check` passed Rust360/Swift65. The new test adapter
initially had two compile-only type mismatches; attempt2 passed without product
changes. Logs: `/tmp/suwop-selected-recovery-check{1,2}.log`.

The real-server suite passed11/11 on actual Immich3.2.4 in29.03 seconds.
The new seeded legacy Applied/Unknown case exercised schema7 migration, real
PIN authentication, exact selected Inspect and durable reload. Each Inspect
trace was GET status, GET selected detail, GET status, Persist; original fields
remained identical and no related requests or writes occurred. Separately
observed P/M/P2 identity, placement, memberships and original hashes stayed
unchanged after controlled external fixture setup. This proves recovery, not
automatic native-metadata causation. Dedicated Docker resources were removed
and the unrelated Kukunochi container retained. Report:
`/tmp/suwop-selected-recovery-evidence-20261016-1/validation-report.json`.
Final record-off strict VRT passed: host81/UI45, all48 captures with zero differences, all seven stages exit0. Baseline hashes were identical before and after the run. Report: `DerivedData/VRTArtifacts/20261015T164525Z-84819/report.json`. Hosted CI remains required.
No physical-device/PhotoKit/iCloud acceptance is implied by simulator or synthetic
server evidence. Exact-version write gating, ordinary read-only redisplay,
VIDEO/Live PIN and the remaining PP01–16 roadmap remain outstanding.


The unchanged PR30 checkout `09cee1c` also passed all ten existing real-server
cases on isolated3.3.3 in31.08 seconds. The wrapper checked exact test names,
actual server version/image digest, a clean unchanged checkout and removal of all
dedicated containers/volumes/network while retaining Kukunochi. Report:
`/tmp/suwop-v333-pr30-suite-20261016-1/report.json`.
This compatibility run includes ordinary native P/M and C1/C2 lock/unlock; it is
not a runtime test of this recovery increment or VIDEO/Live PIN enablement.
