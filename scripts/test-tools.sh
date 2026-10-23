#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
export SUWOP_TOOL_PROBE="$TEMP/cargo-completed"
cat > "$TEMP/cargo" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo 'cargo 1.95.0'
# Simulate first-use setup output larger than a pipe buffer. A head consumer
# kills this producer before its setup work can finish.
printf '%0128d\n' {1..2048}
touch "$SUWOP_TOOL_PROBE"
STUB
cat > "$TEMP/mise" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == ls ]]; then echo 'uv 0.11.24 mise.toml 0.11.24'; exit 0; fi
exit "${SUWOP_MISE_MISSING:-0}"
STUB
chmod +x "$TEMP"/{cargo,mise}
PATH="$TEMP:$PATH" bash "$ROOT/scripts/check-tools.sh"
test -f "$SUWOP_TOOL_PROBE"
# Missing pinned tools must fail the check.
if SUWOP_MISE_MISSING=1 PATH="$TEMP:$PATH" bash "$ROOT/scripts/check-tools.sh" 2>/dev/null; then
  echo "check-tools.sh accepted missing mise tools" >&2
  exit 1
fi
