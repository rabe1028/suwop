#!/usr/bin/env bash
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HOOKS="$(git rev-parse --absolute-git-dir)/hooks"
mkdir -p "$HOOKS"
for hook in pre-commit pre-push; do
  if [[ -e "$HOOKS/$hook" && ! -L "$HOOKS/$hook" ]]; then
    echo "Existing $HOOKS/$hook preserved; install the repository hook manually." >&2
    exit 1
  fi
  ln -sf "$ROOT/.githooks/$hook" "$HOOKS/$hook"
done
