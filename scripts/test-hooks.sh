#!/usr/bin/env bash
set -euo pipefail
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Git hooks export repository-local paths. The temporary repository must be isolated.
while IFS= read -r variable; do
  unset "$variable"
done < <(git rev-parse --local-env-vars)
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
mkdir -p "$TEMP/custom-hooks"
printf 'user hook\n' > "$TEMP/custom-hooks/pre-commit"
git config --local core.hooksPath "$TEMP/custom-hooks"
if bash "$SOURCE/scripts/install-hooks.sh" >/dev/null 2>&1; then
  echo "Setup ignored a custom hooksPath." >&2
  exit 1
fi
[[ "$(cat "$TEMP/custom-hooks/pre-commit")" == "user hook" ]]
[[ ! -L .git/hooks/pre-commit ]]
git config --local --unset core.hooksPath
bash "$SOURCE/scripts/install-hooks.sh"
bash "$SOURCE/scripts/install-hooks.sh"
[[ "$(readlink .git/hooks/pre-commit)" == "$REPO/.githooks/pre-commit" ]]
[[ "$(readlink .git/hooks/pre-push)" == "$REPO/.githooks/pre-push" ]]
