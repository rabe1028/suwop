#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.tools/bin"
command -v uv >/dev/null || { echo "Install uv before running make setup." >&2; exit 1; }
mkdir -p "$BIN"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
OS="$(uname -s)"
ARCH="$(uname -m)"
if [[ "$ARCH" == "aarch64" ]]; then ARCH=arm64; fi
if [[ "$OS" == "Darwin" ]]; then
  curl -fsSL https://github.com/realm/SwiftLint/releases/download/0.65.1/portable_swiftlint.zip -o "$TEMP/swiftlint.zip"
  unzip -q "$TEMP/swiftlint.zip" -d "$TEMP/swiftlint"
  install -m 755 "$TEMP/swiftlint/swiftlint" "$BIN/swiftlint"
  curl -fsSL https://github.com/nicklockwood/SwiftFormat/releases/download/0.63.1/swiftformat.zip -o "$TEMP/swiftformat.zip"
  unzip -q "$TEMP/swiftformat.zip" -d "$TEMP/swiftformat"
  install -m 755 "$TEMP/swiftformat/swiftformat" "$BIN/swiftformat"
  brew install xcodegen shellcheck
  PLATFORM=darwin
else
  PLATFORM=linux
  SHELLCHECK_ARCH="$ARCH"
  if [[ "$ARCH" == "arm64" ]]; then SHELLCHECK_ARCH=aarch64; fi
  curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.$SHELLCHECK_ARCH.tar.xz" -o "$TEMP/shellcheck.tar.xz"
  tar -xJf "$TEMP/shellcheck.tar.xz" -C "$TEMP"
  install -m 755 "$TEMP/shellcheck-v0.11.0/shellcheck" "$BIN/shellcheck"
fi
ACTION_ARCH="$ARCH"
if [[ "$ARCH" == "x86_64" ]]; then ACTION_ARCH=amd64; fi
curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_${PLATFORM}_${ACTION_ARCH}.tar.gz" -o "$TEMP/actionlint.tar.gz"
tar -xzf "$TEMP/actionlint.tar.gz" -C "$TEMP" actionlint
install -m 755 "$TEMP/actionlint" "$BIN/actionlint"
uv venv --allow-existing "$ROOT/.tools/python"
uv pip install --python "$ROOT/.tools/python/bin/python" --quiet ruff==0.17.0
ln -sf "$ROOT/.tools/python/bin/ruff" "$BIN/ruff"
