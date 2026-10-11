#!/usr/bin/env bash
set -euo pipefail
check() {
  local actual
  actual="$("$1" "$2" | head -n 1)"
  if [[ "$actual" != *"$3"* ]]; then
    echo "Expected $1 $3; got $actual. Run make setup." >&2
    exit 1
  fi
}
check cargo --version 1.95.0
check ruff --version 0.17.0
check actionlint -version 1.7.12
if [[ "$(shellcheck --version)" != *"version: 0.11.0"* ]]; then
  echo "Expected ShellCheck 0.11.0. Run make setup." >&2
  exit 1
fi
if [[ "$(uname -s)" == Darwin ]]; then
  check swiftlint version 0.65.1
  check swiftformat --version 0.63.1
fi
