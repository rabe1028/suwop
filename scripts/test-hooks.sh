#!/usr/bin/env bash
set -euo pipefail
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
git init --quiet --initial-branch=main "$TEMP/repo"
cd "$TEMP/repo"
REPO="$(git rev-parse --show-toplevel)"
mkdir -p .githooks
touch .githooks/pre-commit .githooks/pre-push "$TEMP/shared-hook"
ln -s "$TEMP/shared-hook" .git/hooks/pre-commit
if bash "$SOURCE/scripts/install-hooks.sh" >/dev/null 2>&1; then
  echo "Setup replaced a shared hook." >&2
  exit 1
fi
[[ "$(readlink .git/hooks/pre-commit)" == "$TEMP/shared-hook" ]]
[[ ! -L .git/hooks/pre-push ]]
rm .git/hooks/pre-commit
ln -s "$TEMP/missing-hook" .git/hooks/pre-push
if bash "$SOURCE/scripts/install-hooks.sh" >/dev/null 2>&1; then
  echo "Setup replaced a broken symlink." >&2
  exit 1
fi
[[ "$(readlink .git/hooks/pre-push)" == "$TEMP/missing-hook" ]]
[[ ! -L .git/hooks/pre-commit ]]
rm .git/hooks/pre-push
printf 'original hook\n' > .git/hooks/pre-commit
if bash "$SOURCE/scripts/install-hooks.sh" >/dev/null 2>&1; then
  echo "Setup replaced a regular hook." >&2
  exit 1
fi
[[ "$(cat .git/hooks/pre-commit)" == "original hook" ]]
rm .git/hooks/pre-commit
bash "$SOURCE/scripts/install-hooks.sh"
bash "$SOURCE/scripts/install-hooks.sh"
[[ "$(readlink .git/hooks/pre-commit)" == "$REPO/.githooks/pre-commit" ]]
[[ "$(readlink .git/hooks/pre-push)" == "$REPO/.githooks/pre-push" ]]
