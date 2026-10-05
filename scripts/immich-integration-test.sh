#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "$ROOT/docker/immich-test/docker-compose.yml")
export IMMICH_VERSION="${IMMICH_VERSION:-v3.2.4}"
export IMMICH_TEST_PORT="${IMMICH_TEST_PORT:-2283}"
export SUWOP_IMMICH_URL="${SUWOP_IMMICH_URL:-http://127.0.0.1:${IMMICH_TEST_PORT}}"

cleanup() {
  if [[ "${KEEP_IMMICH_TEST_ENV:-0}" != "1" ]]; then
    "${COMPOSE[@]}" down -v --remove-orphans
  fi
}
trap cleanup EXIT

"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d

if ! SUWOP_IMMICH_API_KEY="$(python3 "$ROOT/scripts/bootstrap_immich.py")"; then
  "${COMPOSE[@]}" ps >&2 || true
  "${COMPOSE[@]}" logs --no-color --tail=250 >&2 || true
  exit 1
fi
export SUWOP_IMMICH_API_KEY
export RUN_IMMICH_INTEGRATION=1

cd "$ROOT"
swift test --filter ImmichLiveTests
