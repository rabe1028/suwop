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

# Exercise the real repository hooks with Git's inherited hook environment.
# A real foreign object must remain accessible from make, as SwiftPM's Git
# subprocesses need to inspect their own repositories rather than this one.
git init --quiet --initial-branch=main "$TEMP/foreign"
FOREIGN_BLOB="$(printf 'foreign dependency object\n' | git -C "$TEMP/foreign" hash-object -w --stdin)"
mkdir -p "$REPO/subdirectory" "$TEMP/alternate-objects"
printf 'ordinary index\n' > indexed.txt
git add indexed.txt
cp .git/index "$TEMP/alternate-index"
printf 'alternate staged index\n' > indexed.txt
GIT_INDEX_FILE="$TEMP/alternate-index" git add indexed.txt
cp .git/index "$TEMP/ordinary-index-before"
cp "$TEMP/alternate-index" "$TEMP/alternate-index-before"
cat > "$TEMP/global-config" <<'CONFIG'
[suwopHook]
    marker = global-configuration-preserved
CONFIG
cat > "$TEMP/assert-hook-environment.sh" <<'ASSERTIONS'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$(pwd -P)" != "$HOOK_EXPECT_ROOT" ]]; then
  printf 'Wrong make root: expected %s, observed %s\n' "$HOOK_EXPECT_ROOT" "$(pwd -P)" >&2
  exit 1
fi
if ! git -C "$HOOK_FOREIGN_REPO" cat-file -e "$HOOK_FOREIGN_BLOB"; then
  echo 'Foreign Git object unavailable under inherited repository environment.' >&2
  exit 1
fi
[[ "$(git -C "$HOOK_FOREIGN_REPO" cat-file -p "$HOOK_FOREIGN_BLOB")" == 'foreign dependency object' ]]
while IFS= read -r variable; do
  if declare -p "$variable" >/dev/null 2>&1; then
    echo "Repository-local environment leaked into make: $variable" >&2
    exit 1
  fi
done < <(git rev-parse --local-env-vars)
[[ "$(git -C "$HOOK_FOREIGN_REPO" config --get suwopHook.marker)" == 'global-configuration-preserved' ]]
if git -C "$HOOK_FOREIGN_REPO" config --get suwopHook.local; then
  echo 'Repository-local command configuration leaked into the dependency.' >&2
  exit 1
fi
[[ "$GIT_SSH_COMMAND" == 'ssh -o ServerAliveInterval=30' ]]
[[ "$HOOK_USER_SETTING" == 'user-environment-preserved' ]]
printf '%s\n' "$1" >> "$HOOK_CALL_LOG"
if [[ "${HOOK_FAIL_TARGET:-}" == "$1" ]]; then exit 23; fi
ASSERTIONS
cat > Makefile <<'MAKEFILE'
.PHONY: lint test
lint test:
	@bash "$(HOOK_ASSERTIONS)" "$@"
MAKEFILE

run_inherited_hook() {
  local hook=$1
  (
    cd "$REPO/subdirectory"
    env GIT_DIR="$REPO/.git" GIT_WORK_TREE="$REPO" \
      GIT_COMMON_DIR="$REPO/.git" GIT_OBJECT_DIRECTORY="$REPO/.git/objects" \
      GIT_ALTERNATE_OBJECT_DIRECTORIES="$TEMP/alternate-objects" \
      GIT_INDEX_FILE="$TEMP/alternate-index" GIT_PREFIX='subdirectory/' \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=suwopHook.local \
      GIT_CONFIG_VALUE_0=repository-local-must-not-leak \
      GIT_CONFIG_GLOBAL="$TEMP/global-config" GIT_CONFIG_NOSYSTEM=1 \
      GIT_SSH_COMMAND='ssh -o ServerAliveInterval=30' \
      HOOK_USER_SETTING='user-environment-preserved' \
      HOOK_EXPECT_ROOT="$(cd "$REPO" && pwd -P)" HOOK_FOREIGN_REPO="$TEMP/foreign" \
      HOOK_FOREIGN_BLOB="$FOREIGN_BLOB" \
      HOOK_ASSERTIONS="$TEMP/assert-hook-environment.sh" \
      HOOK_CALL_LOG="$TEMP/hook-calls" \
      bash "$SOURCE/.githooks/$hook"
  )
}

run_inherited_hook pre-commit
run_inherited_hook pre-push
printf 'lint\ntest\n' > "$TEMP/expected-calls"
cmp "$TEMP/expected-calls" "$TEMP/hook-calls"
# Clearing GIT_INDEX_FILE for nested repositories must not modify either index.
cmp "$TEMP/ordinary-index-before" .git/index
cmp "$TEMP/alternate-index-before" "$TEMP/alternate-index"
# Neither hook may hide a failing normal make target.
for entry in 'pre-commit lint' 'pre-push test'; do
  read -r hook target <<< "$entry"
  if HOOK_FAIL_TARGET="$target" run_inherited_hook "$hook"; then
    echo "$hook ignored a failed make $target." >&2
    exit 1
  fi
done
printf 'Repository hooks isolate nested Git and preserve make checks.\n'
