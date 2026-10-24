#!/usr/bin/env bash
set -euo pipefail
# Retry only registry throttling, before any fixtures or test mutations run.
# Accept the caller's compose argv so its project/file/version remain unchanged.
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
# GHCR's per-minute limit outlasted 10s/20s waits (main run 39887115193).
WAITS=(15 30 60 60)
for attempt in 1 2 3 4 5; do
    status=0
    "$@" pull --policy missing > "$LOG" 2>&1 || status=$?
    cat "$LOG"
    if [[ "$status" == 0 ]]; then exit 0; fi
    if [[ "$attempt" == 5 ]] || ! grep -Eiq 'toomanyrequests|too many requests|(^|[^0-9a-f])429([^0-9a-f]|$)' "$LOG"; then
        exit "$status"
    fi
    wait="${WAITS[$((attempt - 1))]}"
    echo "Registry throttled image acquisition; retry $attempt/4 after ${wait}s." >&2
    sleep "$wait"
done
