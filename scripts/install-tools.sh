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
  brew install xcodegen shellcheck protobuf
  PLATFORM=darwin
else
  # Lance's pinned Rust crates compile protobuf schemas during the build.
  if ! command -v protoc >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y protobuf-compiler
  fi
  PLATFORM=linux
  SHELLCHECK_ARCH="$ARCH"
  if [[ "$ARCH" == "arm64" ]]; then SHELLCHECK_ARCH=aarch64; fi
  curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.$SHELLCHECK_ARCH.tar.xz" -o "$TEMP/shellcheck.tar.xz"
  tar -xJf "$TEMP/shellcheck.tar.xz" -C "$TEMP"
  install -m 755 "$TEMP/shellcheck-v0.11.0/shellcheck" "$BIN/shellcheck"
fi
NEXTEST_VERSION=0.9.146
if [[ "$OS" == "Darwin" ]]; then
  NEXTEST_TARGET=universal-apple-darwin
  NEXTEST_SHA256=39785160b3c2f6ed9a765049cf4fa79f3b39aa02eb7598a5a0e2a1a0b9ffb9a8
elif [[ "$ARCH" == "arm64" ]]; then
  NEXTEST_TARGET=aarch64-unknown-linux-gnu
  NEXTEST_SHA256=b2e33d7c72de7ade0ff7b3a948ac37516b24f8a836b7a8870c1f634a94be9de9
else
  NEXTEST_TARGET=x86_64-unknown-linux-gnu
  NEXTEST_SHA256=682c21b777c333e96fd532e114d3a5a894e0729ab88d94c0a9f20f8419695428
fi
curl -fsSL "https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-$NEXTEST_VERSION/cargo-nextest-$NEXTEST_VERSION-$NEXTEST_TARGET.tar.gz" -o "$TEMP/nextest.tar.gz"
printf '%s  %s\n' "$NEXTEST_SHA256" "$TEMP/nextest.tar.gz" | shasum -a 256 -c - >/dev/null
tar -xzf "$TEMP/nextest.tar.gz" -C "$TEMP"
install -m 755 "$TEMP/cargo-nextest" "$BIN/cargo-nextest"
ACTION_ARCH="$ARCH"
if [[ "$ARCH" == "x86_64" ]]; then ACTION_ARCH=amd64; fi
curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_${PLATFORM}_${ACTION_ARCH}.tar.gz" -o "$TEMP/actionlint.tar.gz"
tar -xzf "$TEMP/actionlint.tar.gz" -C "$TEMP" actionlint
install -m 755 "$TEMP/actionlint" "$BIN/actionlint"
uv venv --allow-existing "$ROOT/.tools/python"
uv pip install --python "$ROOT/.tools/python/bin/python" --quiet ruff==0.17.0
ln -sf "$ROOT/.tools/python/bin/ruff" "$BIN/ruff"
