#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo 'VRT requires an Apple Silicon Mac.' >&2
    exit 1
fi
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
curl -fsSL https://github.com/MobAI-App/simslim/releases/download/v0.12.2/simslim-v0.12.2-macos-arm64.tar.gz \
    -o "$TEMP/simslim.tar.gz"
printf '%s  %s\n' b47302da6fb83b8b4c21f4fdd61507469770c07b0ff07fd1f48207bda4270887 \
    "$TEMP/simslim.tar.gz" | shasum -a 256 -c -
tar -xzf "$TEMP/simslim.tar.gz" -C "$TEMP"
mkdir -p .tools/bin
install -m 755 "$TEMP/simslim" .tools/bin/simslim
.tools/bin/simslim --version
