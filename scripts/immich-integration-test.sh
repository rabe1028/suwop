#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export IMMICH_TEST_PROJECT="${IMMICH_TEST_PROJECT:-suwop-rust-test}"
COMPOSE=(docker compose -p "$IMMICH_TEST_PROJECT" -f "$ROOT/docker/immich-test/docker-compose.yml")
export IMMICH_VERSION="${IMMICH_VERSION:-v3.2.4}"
case "$IMMICH_VERSION" in
  v3.2.4|v3.3.3) ;;
  *) printf 'Integration acceptance supports explicit v3.2.4 or v3.3.3 only\n' >&2; exit 1 ;;
esac
export IMMICH_TEST_PORT="${IMMICH_TEST_PORT:-2289}"
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

export SUWOP_NATIVE_LIVE_EVIDENCE_DIR="${SUWOP_NATIVE_LIVE_EVIDENCE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/suwop-native-live-evidence.XXXXXX")}"
printf 'Synthetic native Live evidence: %s\n' "$SUWOP_NATIVE_LIVE_EVIDENCE_DIR"
cd "$ROOT"
# Verify the actual raw release, not merely the requested container tag. No credentials saved.
python3 - <<'VERSION'
import json
import os
from pathlib import Path
from urllib.request import urlopen

with urlopen(os.environ["SUWOP_IMMICH_URL"] + "/api/server/version", timeout=15) as reply:
    actual = json.load(reply)
expected = [int(part) for part in os.environ["IMMICH_VERSION"][1:].split(".")]
if any(type(actual.get(field)) is not int for field in ("major", "minor", "patch")) or [actual.get(field) for field in ("major", "minor", "patch")] != expected or "prerelease" not in actual or actual["prerelease"] is not None:
    raise SystemExit("Actual server must match the selected stable acceptance release")
evidence = Path(os.environ["SUWOP_NATIVE_LIVE_EVIDENCE_DIR"])
evidence.mkdir(parents=True, exist_ok=True)
if any(evidence.iterdir()):
    raise SystemExit("Acceptance evidence directory must be new or empty")
(evidence / "server-version.json").write_text(json.dumps(actual) + "\n")
VERSION
"${COMPOSE[@]}" images --format json > "$SUWOP_NATIVE_LIVE_EVIDENCE_DIR/images.json"
suwop_test_container_id="$("${COMPOSE[@]}" ps -q immich-server)"
suwop_test_image_id="$(docker inspect --format '{{.Image}}' "$suwop_test_container_id")"
docker image inspect --format '{"id":{{json .Id}},"repoDigests":{{json .RepoDigests}}}' "$suwop_test_image_id" > "$SUWOP_NATIVE_LIVE_EVIDENCE_DIR/image-identity.json"
TEST_ARGS=(--ignored --test-threads=1)
if [[ "$IMMICH_VERSION" == v3.2.4 ]]; then
  # Positive mutations belong to the verified-write release. The native matrix case
  # instead asserts zero confirmation/Persist/PUT on this real old server.
  TEST_ARGS+=(--skip visibility::real_immich_single_image_visibility_removes_two_owned_albums_and_never_restores_them)
fi
cargo test --locked -p suwop-core --test immich_live -- "${TEST_ARGS[@]}" --list > "$SUWOP_NATIVE_LIVE_EVIDENCE_DIR/applicable-tests.txt"
python3 - <<'LIST'
import os
from pathlib import Path

names = [line.removesuffix(": test") for line in Path(os.environ["SUWOP_NATIVE_LIVE_EVIDENCE_DIR"], "applicable-tests.txt").read_text().splitlines() if line.endswith(": test")]
expected = 12 if os.environ["IMMICH_VERSION"] == "v3.2.4" else 13
if len(names) != expected or not any(name.endswith("real_exact_release_native_image_write_gate_preserves_related_resources") for name in names):
    raise SystemExit("Applicable integration case list does not match the explicit release matrix")
LIST
cargo test --locked -p suwop-core --test immich_live -- "${TEST_ARGS[@]}"
