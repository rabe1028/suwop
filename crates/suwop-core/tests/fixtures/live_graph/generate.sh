#!/bin/sh
set -eu
cd "$(dirname "$0")"
for entry in V:red M:blue; do
  name=${entry%:*}
  color=${entry#*:}
  ffmpeg -hide_banner -nostdin -y -f lavfi -i "color=c=$color:s=64x64:r=5:d=1" \
    -frames:v 5 -an -c:v libx264 -preset medium -profile:v baseline -level:v 1.0 \
    -crf 18 -pix_fmt yuv420p -threads 1 -x264-params 'threads=1:lookahead_threads=1:keyint=5:min-keyint=5:scenecut=0' \
    -fflags +bitexact -flags:v +bitexact -map_metadata -1 -movflags +faststart \
    "$name.mp4" 2> "$name.encode.log"
done
