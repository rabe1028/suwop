#!/usr/bin/env bash
set -euo pipefail
# Retry only registry throttling, before any fixtures or test mutations run.
# Accept the caller's compose argv so its project/file/version remain unchanged.
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
for attempt in 1 2 3; do
    status=0
    "$@" pull > "$LOG" 2>&1 || status=$?
    cat "$LOG"
    if [[ "$status" == 0 ]]; then exit 0; fi
    if [[ "$attempt" == 3 ]] || ! grep -Eiq 'toomanyrequests|too many requests|(^|[^0-9a-f])429([^0-9a-f]|$)' "$LOG"; then
        exit "$status"
    fi
    echo "Registry throttled image acquisition; retry $attempt/2 after $((attempt * 10))s." >&2
    sleep "$((attempt * 10))"
done
