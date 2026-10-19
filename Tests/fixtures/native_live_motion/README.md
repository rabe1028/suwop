# Changing-frame synthetic native Live pair

`media/` contains the exact originals produced by the accepted run1 on2026-10-17;
packaging copied these bytes without regeneration. Both standalone tools compiled
with Swift6 strict concurrency and warnings-as-errors, generation succeeded, and
the independent verifier succeeded (wrapper exit0,9.05 seconds). Exact versions
are Xcode26.4.1/17E202 and Apple Swift6.3.1; `evidence/tool-versions.txt` retains
the captured output. The existing `Tests/fixtures/native_live_pair` is unchanged.

`manifest.json` records the fixed originals' lengths/SHA-1/SHA-256 and expected
structure. `evidence/native-validation.json` is the byte-exact independent run1
report:48 decoded ordered frames, the matching embedded CID/timed metadata, red
centres15/63/71/47/31 at0/1/1.5/2/3 seconds, and JPEG/timed-frame meanRGB error
3.8464 (limit18). `evidence/generation-run.json` records actual per-step statuses,
source snapshot hashes and unchanged whole-source fingerprint from that run.
These are historical fixture evidence, not a claim of repeated execution during
packaging. The timeout/termination branch was not exercised by the successful run.

The deterministic synthetic input is 96×96, 12 fps, 48 independently allocated
frames (four seconds, no audio). A 16×24 red region moves horizontally over a
stationary checker background. The JPEG uses frame18 (1.5 seconds). Both media
embed the distinct fixed CID `A762B1E3-9D24-4B70-AD53-FA1642C8039E`:
ImageIO Apple maker dictionary key17, QuickTime `content.identifier`, and one
separate `mdta/com.apple.quicktime.still-image-time` timed signed-int8 zero at
18/12 seconds lasting 1/12 seconds. This repeats the public metadata structure
of the existing fixture; no camera provenance, Photos import or relationship
authority is inferred from the CID.

Generator inputs and presentation times are deterministic. Encoded JPEG/H.264
bytes, hashes and container timestamps may change across encoder/OS versions;
byte-identical regeneration is not promised. Generator buffers are unique per
frame, never mutated after append, and all retained through writer completion.
Readiness waits are at most10 seconds each, writer finish at most15 seconds;
the wrapper enforces per-tool60-second and overall180-second execution budgets.
A timed-out step then allows up to3 seconds after group TERM and, if any group
members remain (even after leader exit), up to3 seconds after group KILL. Thus
execution plus timeout shutdown has a180+6 second bound, excluding source
snapshot/report filesystem overhead. Process-exit races are tolerated; a group
not proved absent remains an explicit failed cleanup observation in the step
result, never a successful run. Timeouts/failures keep logs, source snapshots and partial
media; they never manufacture a successful manifest.

## Regenerate or reverify (require separately allocated execution slot)

From the repository root, on macOS with the selected Xcode installed:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  uv run --no-project python Tests/fixtures/native_live_motion/reproduce.py \
  --output /tmp/suwop-native-live-motion-generated-UNIQUE
```

The specified output directory must not exist. Without `--output`, the runner
creates a new temporary directory. It snapshots this source, records Xcode/Swift
versions and per-step command/status/timing/logs, compiles both tools separately
with Swift6 strict concurrency, writes new originals, then runs the verifier.
No existing checked-in samples are replaced. No Photos library access/write,
network media, server, simulator, package installation or product build occurs.

To independently verify an existing generated or downloaded pair:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  uv run --no-project python Tests/fixtures/native_live_motion/reproduce.py \
  --verify-only /absolute/path/to/media \
  --output /tmp/suwop-native-live-motion-verified-UNIQUE
```

`Verify.swift` does not import `Pattern.swift` or execute the generator. It reads
actual ImageIO and AVAsset metadata and decodes the full video using AVAssetReader.
It requires the fixed CID, exact key/type/value/timing, one video/metadata track,
zero audio, exact dimensions, all48 ordered timestamps and four-second duration.
It compares decoded frames0/12/24/36 (at least256 substantially changed pixels per
successive comparison), checks a substantial red region traverses at least40
pixels, and compares the JPEG with decoded timed frame18 (region centre within2
pixels and mean RGB error≤18, allowing lossy codecs). Reports include actual
sample timestamps, decoded pixel hashes/centres, lengths and SHA-1/SHA-256 of both
actual files. Its readers impose finite sample/time bounds; the outer wrapper
also bounds an individual framework call that does not return. These explicit
fixture checks are not production media-admission policy.

A future successful run writes `fixture-validation.json` and `result.json` in its
own output directory. The fixed manifest hashes apply only to this packaged run1,
not all future encodings. Preserve both originals with their hashes before use in
server/native acceptance; a later compiler/runtime failure remains a failure.
To reverify these packaged bytes, pass
`--verify-only "$PWD/Tests/fixtures/native_live_motion/media"` from the repository
root and a fresh output directory. No new generation or verification occurred
during packaging.

## Still required after fixture generation

Independent temporal decoding proves only that these original bytes contain
changing frames and consistent metadata. It **does not prove** PHLivePhoto full
materialization, PHLivePhotoView animation, protected attachment, cancellation
JOIN, exact-window ownership, physical-device playback, Apple-camera authenticity
or iCloud behavior. Protected iOS/macOS tests must later materialize this actual
matched pair and measure changing rendered frames/current playback, rather than
accept a poster or historical frame. Rust pairing/authorization and all PP-02
acceptance requirements remain separate. No manager or generated DTO wiring is
part of this fixture packaging.
