#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="$SCRIPT_DIR/results/profile-release"
DIRECTORY="${1:?Provide a new fixture directory}"
ROWS="${2:-20000}"
if [[ -e "$DIRECTORY" ]]; then
    echo "Fixture directory must not exist" >&2
    exit 1
fi
"$BINARY" prepare "$DIRECTORY" "$ROWS"
python3 "$SCRIPT_DIR/profile.py" seed "$DIRECTORY" "$ROWS"
/usr/bin/time -l "$BINARY" index "$DIRECTORY" 2> "$DIRECTORY/time.txt"
python3 "$SCRIPT_DIR/profile.py" summarize "$DIRECTORY" "$BINARY"
