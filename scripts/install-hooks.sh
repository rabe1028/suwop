#!/usr/bin/env bash
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HOOKS="$(git rev-parse --absolute-git-dir)/hooks"
mkdir -p "$HOOKS"
for hook in pre-commit pre-push; do
  if [[ -L "$HOOKS/$hook" && "$(readlink "$HOOKS/$hook")" == "$ROOT/.githooks/$hook" ]]; then
    continue
  fi
  if [[ -e "$HOOKS/$hook" || -L "$HOOKS/$hook" ]]; then
    echo "Existing $HOOKS/$hook preserved; install the repository hook manually." >&2
    exit 1
  fi
done
for hook in pre-commit pre-push; do
  ln -sf "$ROOT/.githooks/$hook" "$HOOKS/$hook"
done
