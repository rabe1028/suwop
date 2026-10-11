#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
cd "$ROOT"
cargo run --locked --quiet -p suwop-core --bin schema > "$TEMP/schema.json"
python3 scripts/generate-swift.py "$TEMP/Types.swift" < "$TEMP/schema.json"
diff -u Sources/SuwopShell/Generated/Types.swift "$TEMP/Types.swift"
