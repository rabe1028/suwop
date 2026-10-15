# Immich PIN visibility write contract

PIN-protected visibility changes use Immich’s bulk visibility API so that locking
also removes the selected original from its albums. Immich 3.2.4 queues sidecar
work even for this visibility-only update. With native content identifiers, the
observed follow-up metadata processing can relink a selected image and change a
related motion asset’s placement and album membership. A current null link alone
therefore does not establish that this write preserves related resources.

The write contract recognizes only the runtime-tested stable 3.3.3 response:
major/minor/patch are exactly 3/3/3 and prerelease is explicitly null. Missing,
malformed, prerelease and unrecognized releases do not authorize writes. This is
separate from the older-server read contract: PIN authentication, locked previews,
history, Inspect and persistence recovery remain available without write approval.
Ordinary Timeline/Archive changes retain their separate single-asset API route.

Write approval is ephemeral and belongs to a dedicated authenticated session.
The ordinary connection’s numeric version can at most offer a PIN verification
step; it cannot authorize a mutation. Fresh dedicated version checks are required
before confirmation and again after current asset validation immediately before
submission. Account, scene, generation and deadline checks still apply. A failed
fresh check revokes that session’s write proof and updates action availability,
while leaving independently valid read access intact. A late response from an old
session must not modify a newer session’s approval.

A rejection before durable intent emits no intent or provider mutation. A proven
rejection before submission after intent is saved is recorded as NotApplied;
failed final persistence remains uncertain. Transport failure after submission
remains Unknown and is not replayed. Saved observations and journal outcomes never
restore a write grant after restart.

The UI distinguishes a PIN verification step, a supported write action and an
unavailable write action. Unsupported media, changed witnesses and unresolved
journals retain their existing restrictions. VIDEO and Live PIN changes are not
enabled by the server-version check.

This contract does not make every external access path private. Existing shared
links can continue to return the original after locking, and are not automatically
revoked. Confirmation discloses this limitation. A version response is a server
self-report, not image attestation, and a client cannot make a server deployment
switch between its last check and PUT atomic. Separate external metadata work can
still change related assets. Runtime queue observations cover only the measured
operation and bounded observation window.

## Validation status

Local `make check` passed with 368 Rust and 65 Swift tests, lint and generated
DTO reproducibility. This includes all 52 visibility tests and two strict-release
and proof tests. The 12 real-server cases ignored by that gate were evaluated in
separate release-specific acceptance runs: 11 cases passed on actual stable 3.2.4
and 12 on stable 3.3.3.

Old-server Prepare emitted zero confirmation, intent persistence or PUT while
read access and Inspect remained usable. On 3.3.3, native-image lock/unlock
preserved related identity, placement, albums and original bytes. Each bounded
window had 20 unchanged queue and metadata observations. Shared-key detail and
original access still returned 200 with matching original bytes while locked.
Both dedicated environments were removed after their runs.

Apple builds passed all five Rust targets, XCFramework and iOS/macOS apps.
Targeted host tests passed 9/9. The changed UI class passed 12/12, followed by
normal and added AX3 unsupported-server read tests passing 2/2 after the final
menu-navigation helper update. Parent review confirmed full AX3 verification
labels, guidance, scrolling to preview, actual raster display and Close access.
These are simulator results, separate from physical-device and iCloud acceptance.

All 48 candidate images were captured. The unchanged comparator detected three
intentional old-server roster differences: disabled write actions and explanatory
text, with reading retained. Their baseline update was explicitly approved after
visual and interaction review; the other 45 baselines remained byte-identical.
Final record-off VRT passed all 84 host and 48 UI tests, with all 48 captures
within the unchanged comparator and all seven stages exiting successfully.
All baseline hashes were unchanged during that run. Hosted CI is pending. Some targeted runs could not collect
simulator diagnostics because their diagnostic subprocess could not find simctl;
this did not fail their test cases and remains a separate diagnostic limitation.
