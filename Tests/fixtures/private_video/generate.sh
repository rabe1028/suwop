#!/bin/sh
set -eu
output=${1:?output directory required}
mkdir -p "$output"
ffmpeg -version > "$output/tool-version.txt"
ffmpeg -hide_banner -nostdin -y \
  -f lavfi -i 'testsrc2=size=96x96:rate=12:duration=30' \
  -f lavfi -i 'sine=frequency=440:sample_rate=44100:duration=30' \
  -map 0:v:0 -map 1:a:0 -c:v libx264 -profile:v baseline \
  -pix_fmt yuv420p -preset veryslow -crf 28 -g 12 -c:a aac -b:a 32k \
  -movflags +faststart -map_metadata -1 -shortest "$output/synthetic-private-video.mp4" \
  2> "$output/encode.log"
ffmpeg -hide_banner -nostdin -y -i "$output/synthetic-private-video.mp4" -map 0 -c copy -f mov \
  "$output/synthetic-private-video.mov" 2> "$output/mov-remux.log"
ffprobe -v error -show_format -show_streams -of json \
  "$output/synthetic-private-video.mov" > "$output/mov-probe.json"
ffprobe -v error -show_format -show_streams -of json \
  "$output/synthetic-private-video.mp4" > "$output/probe.json"
ffmpeg -v error -nostdin -y -i "$output/synthetic-private-video.mp4" -map 0:v:0 \
  -f framemd5 "$output/decoded-frames.md5"
uv run --no-project python - "$output" <<'PY'
import hashlib
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
media = root / 'synthetic-private-video.mp4'
data = media.read_bytes()
probe = json.loads((root / 'probe.json').read_text())
frames = [line for line in (root / 'decoded-frames.md5').read_text().splitlines() if not line.startswith('#')]
assert len(frames) == 360
assert len({line.rsplit(',', 1)[-1].strip() for line in frames}) > 1
assert {s['codec_name'] for s in probe['streams']} == {'h264', 'aac'}
manifest = {
    'file': media.name, 'bytes': len(data), 'sha1': hashlib.sha1(data).hexdigest(),
    'sha256': hashlib.sha256(data).hexdigest(), 'decodedVideoFrames': len(frames),
    'synthetic': True, 'width': 96, 'height': 96, 'durationSeconds': 30,
}
(root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
mov = root / 'synthetic-private-video.mov'
mov_data = mov.read_bytes()
mov_manifest = {
    'file': mov.name, 'bytes': len(mov_data), 'sha1': hashlib.sha1(mov_data).hexdigest(),
    'sha256': hashlib.sha256(mov_data).hexdigest(), 'synthetic': True,
    'container': 'QuickTime MOV', 'source': media.name, 'remuxOnly': True,
}
(root / 'mov-manifest.json').write_text(json.dumps(mov_manifest, indent=2) + '\n')

PY
