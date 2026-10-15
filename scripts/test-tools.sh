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
for spec in 'uv 0.11.24' 'ruff 0.17.0' 'actionlint 1.7.12' 'shellcheck version: 0.11.0' 'swiftlint 0.65.1' 'swiftformat 0.63.1'; do
  name="${spec%% *}"
  version="${spec#* }"
  printf '#!/usr/bin/env bash\necho %s\n' "$version" > "$TEMP/$name"
done
chmod +x "$TEMP"/{cargo,uv,ruff,actionlint,shellcheck,swiftlint,swiftformat}
PATH="$TEMP:$PATH" bash "$ROOT/scripts/check-tools.sh"
test -f "$SUWOP_TOOL_PROBE"
