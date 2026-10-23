#!/usr/bin/env bash
set -euo pipefail
# Tool versions and checksums are pinned in mise.toml and mise.lock.
command -v mise >/dev/null || { echo "Install mise, then run make setup." >&2; exit 1; }
# Only this repository's tools; a developer's global mise tools are not locked here.
tools=()
while read -r name _; do tools+=("$name"); done < <(mise ls --local --no-header)
if ! mise install --locked --dry-run-code "${tools[@]}" >/dev/null 2>&1; then
  echo "Pinned tools from mise.lock are missing. Run make setup." >&2
  exit 1
fi
# Rust is pinned by rust-toolchain.toml. Rustup can initialize the toolchain
# during this command; read all output so a closed pipe never stops it.
actual="$(cargo --version)"
actual="${actual%%$'\n'*}"
if [[ "$actual" != *1.95.0* ]]; then
  echo "Expected cargo 1.95.0; got $actual." >&2
  exit 1
fi
