#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export IMMICH_TEST_PROJECT="${IMMICH_TEST_PROJECT:-suwop-rust-test}"
COMPOSE=(docker compose -p "$IMMICH_TEST_PROJECT" -f "$ROOT/docker/immich-test/docker-compose.yml")
export IMMICH_VERSION="${IMMICH_VERSION:-v3.2.4}"
export IMMICH_TEST_PORT="${IMMICH_TEST_PORT:-2289}"
export SUWOP_IMMICH_URL="${SUWOP_IMMICH_URL:-http://127.0.0.1:${IMMICH_TEST_PORT}}"

cleanup() {
  if [[ "${KEEP_IMMICH_TEST_ENV:-0}" != "1" ]]; then
    "${COMPOSE[@]}" down -v --remove-orphans
  fi
}
trap cleanup EXIT

"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
bash "$ROOT/scripts/pull-test-images.sh" "${COMPOSE[@]}"
"${COMPOSE[@]}" up -d --pull never

if ! SUWOP_IMMICH_API_KEY="$(python3 "$ROOT/scripts/bootstrap_immich.py")"; then
  "${COMPOSE[@]}" ps >&2 || true
  "${COMPOSE[@]}" logs --no-color --tail=250 >&2 || true
  exit 1
fi
export SUWOP_IMMICH_API_KEY

export SUWOP_NATIVE_LIVE_EVIDENCE_DIR="${SUWOP_NATIVE_LIVE_EVIDENCE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/suwop-native-live-evidence.XXXXXX")}"
printf 'Synthetic native Live evidence: %s\n' "$SUWOP_NATIVE_LIVE_EVIDENCE_DIR"
cd "$ROOT"
cargo test --locked -p suwop-core --test immich_live -- --ignored --test-threads=1
