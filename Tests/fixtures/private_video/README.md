# Synthetic private VIDEO fixture

`synthetic-private-video.mp4` is generated entirely from FFmpeg's `testsrc2` pixels
and a generated 440 Hz sine wave. It contains no personal or copyrighted media.
It is a standalone VIDEO, with no Apple Live Photo pairing metadata.

Run `./generate.sh <output-directory>` with FFmpeg/ffprobe available. The retained
`tool-version.txt` records the exact installed encoder libraries and versions;
`encode.log` records the invocation result. Captured log lines have trailing whitespace removed. Encoder/container revisions can change
bytes, so regeneration is not promised to reproduce the fixed manifest hash.

The fixed 335,902-byte fixture has H.264 Constrained Baseline 96×96 video, 12 fps,
360 decoded frames over thirty seconds, and mono AAC audio. `probe.json` independently
records the tracks. `decoded-frames.md5` contains differing decoded frame hashes,
proving changing source pixels rather than a poster-only sample. `manifest.json`
records SHA-1 and SHA-256 of the fixed original bytes.

These media facts alone do not prove native playback. Native tests separately
must inspect an actual AVPlayer's decoded frames, elapsed time, seek result and
audio track/player state. They cannot establish audible output on a real device,
PhotoKit acceptance, or iCloud behavior.

`synthetic-private-video.mov` is an explicit FFmpeg QuickTime container remux of
the same generated tracks (`-map 0 -c copy -f mov`), not a renamed MP4. Its own
probe and manifest retain the distinct container hash. Native tests exercise
both files through a real loopback original endpoint with absent and generic
HTTP MIME types. Filename-derived MIME is only a parser hint from the exact
Rust-bound original resource; actual AV video-track parsing remains required.
