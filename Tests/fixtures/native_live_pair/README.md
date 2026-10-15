# Structured synthetic native Live pair

Canonical repository path: `Tests/fixtures/native_live_pair/` (capital `Tests`;
paths are case-sensitive on Linux). Run the commands below from that directory.

`media/` contains a fixed, entirely synthetic 64×64 JPEG and H.264 MOV. Both
embed content identifier `B18D9CC0-335C-4B73-880D-627A3A78D9C3`. The still uses
Apple maker dictionary key 17; the movie uses QuickTime `content.identifier`
and a separate timed metadata track with `mdta/com.apple.quicktime.still-image-time`,
signed int8 value 0 at 0.4 seconds for 0.2 seconds. The movie has five frames,
one second duration and no audio. Pixels are a solid generated green; there is
no personal, camera, copyrighted or downloaded source media.

`manifest.json` identifies the exact fixed files by length, SHA-1 and SHA-256.
`evidence/` preserves the original independent ImageIO/AVAssetReader report,
ffprobe report and toolchain versions. These are historical generation evidence,
not a claim that verification was rerun during fixture packaging.

## Regenerate into a new directory

On macOS with Xcode installed, run `./reproduce.sh`. It compiles only the two
small standalone tools and creates an independent directory under `$TMPDIR`.
An optional argument names a **new, nonexistent** output directory. It never
replaces the checked-in samples. Byte-identical regeneration is **not**
guaranteed: encoder/OS revisions and container creation timestamps can change
bytes. New outputs must satisfy the independent metadata verifier; fixed sample
hashes apply only to the checked-in files.

`Generate.swift` writes pixels, identifiers and the timed metadata track using
ImageIO and AVAssetWriter. `Verify.swift` independently reads the JPEG and MOV
with ImageIO, AVAssetReader and AVAsset metadata APIs; it does not call the
generator or modify its inputs. It emits a JSON report on stdout and rejects
missing/mismatched identifiers, missing/wrong timed metadata, a still-image-time
start outside the movie, or absent video. It reports dimensions, codec and hashes
for comparison with the manifest. To verify the fixed files without
regenerating them:

```sh
work=$(mktemp -d "${TMPDIR:-/tmp}/suwop-native-live-verify-XXXXXX")
xcrun swiftc -parse-as-library Verify.swift -o "$work/verify"
"$work/verify" "$PWD/media" > "$work/native-validation.json"
```

## Consumer contract and limits

Use `media/synthetic-still.jpg` as P and `media/synthetic-motion.mov` as M.
Check manifest hashes before upload. A disposable Immich acceptance run may
upload the two originals, establish/observe an API relation separately, download
both originals, compare exact bytes and independently parse the downloaded
metadata. Server-created asset IDs and owner/account scope are runtime facts;
never substitute this embedded identifier for an Immich asset ID or authorize
content from a relation alone. No embedded GPS/time provenance is asserted.

This fixture is separate from API-linked mock records. Its structured metadata
does **not** prove PhotoKit import/PHLivePhoto rendering, physical-device
playback, Apple-camera authenticity, production metadata preservation or iCloud
behavior. Packaging and verification perform no Photos library writes. Those
acceptance steps require their own explicit test and evidence.
