#!/usr/bin/env bash
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HOOKS="$(git rev-parse --path-format=absolute --git-path hooks)"
if git config --get core.hooksPath >/dev/null; then
  # The user's managed hooks explicitly delegate to per-worktree Git-dir hooks.
  # Never replace a configured shared directory or assume it delegates.
  for hook in pre-commit pre-push; do
    if [[ ! -x "$HOOKS/$hook" ]]; then
      echo "Custom hooksPath $HOOKS preserved; configure explicit hook delegation first." >&2
      exit 1
    fi
    content="$(cat "$HOOKS/$hook")"
    delegation_marker="repo_hook=\"\$(git rev-parse --git-dir)/hooks/$hook\""
    chain_marker="exec \"\$repo_hook\" \"\$@\""
    if [[ "$content" != *"$delegation_marker"* || "$content" != *"$chain_marker"* ]]; then
      echo "Custom hooksPath $HOOKS preserved; configure explicit hook delegation first." >&2
      exit 1
    fi
  done
  HOOKS="$(git rev-parse --absolute-git-dir)/hooks"
fi
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
  if [[ ! -L "$HOOKS/$hook" ]]; then
    ln -s "$ROOT/.githooks/$hook" "$HOOKS/$hook"
  fi
done
