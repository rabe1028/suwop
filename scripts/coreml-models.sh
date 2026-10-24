#!/usr/bin/env bash
# Converts and compiles the EmbeddingGemma 2 Core ML models bundled by the apps.
# Downloads the pinned upstream checkpoint (~1.5 GB) unless EMBEDDINGGEMMA2_ROOT is set.
set -euo pipefail
cd "$(dirname "$0")/.."
out=Generated/CoreMLModels
venv=Generated/coreml-venv
expected=$(grep -A1 'pub const COREML_MODEL_SHA256' crates/suwop-core/src/inference.rs | grep -o '[0-9a-f]\{64\}')
uv venv --allow-existing --quiet --python 3.12 "$venv"
uv pip install --quiet --python "$venv/bin/python" -r scripts/coreml/requirements.txt
rm -rf "$out"
uv run --no-project --python "$venv/bin/python" python scripts/coreml/convert.py "$out/packages" --verify "$expected"
mkdir -p "$out/EmbeddingGemma2"
for model in VisionEncoder VisionHead Tokens Encoder; do
    xcrun coremlcompiler compile "$out/packages/$model.mlpackage" "$out/EmbeddingGemma2" > /dev/null
done
echo "Core ML models ready in $out/EmbeddingGemma2 ($expected)"
