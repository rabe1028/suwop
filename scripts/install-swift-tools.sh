#!/usr/bin/env bash
# Pinned SwiftLint and SwiftFormat. On Linux, SwiftLint's SourceKit-backed rules
# (custom_rules, statement_position) need the Swift toolchain's libsourcekitdInProc,
# so CI runs it inside the pinned Swift container.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.tools/bin"
mkdir -p "$BIN"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
fetch() { # url sha256 output
  curl -fsSL "$1" -o "$3"
  if command -v sha256sum >/dev/null; then
    printf '%s  %s\n' "$2" "$3" | sha256sum -c - >/dev/null
  else
    printf '%s  %s\n' "$2" "$3" | shasum -a 256 -c - >/dev/null
  fi
}
SWIFTLINT=https://github.com/realm/SwiftLint/releases/download/0.65.1
SWIFTFORMAT=https://github.com/nicklockwood/SwiftFormat/releases/download/0.63.1
case "$(uname -s)-$(uname -m)" in
  Darwin-*)
    fetch "$SWIFTLINT/portable_swiftlint.zip" \
      c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0 "$TEMP/swiftlint.zip"
    fetch "$SWIFTFORMAT/swiftformat.zip" \
      385ef1a263ba28685157b98c5536b9c9105e124518f28b7ef8a2bee4b167eaeb "$TEMP/swiftformat.zip"
    ;;
  Linux-x86_64)
    fetch "$SWIFTLINT/swiftlint_linux_amd64.zip" \
      caeed6f4a679c35539ffaf124f6c4ab4a8416917f7d8796279dc52b74026059d "$TEMP/swiftlint.zip"
    fetch "$SWIFTFORMAT/swiftformat_linux.zip" \
      9e10090e0213378c68cedb42adc2c6461916a9c8e457cf452b5585b84096c333 "$TEMP/swiftformat.zip"
    ;;
  Linux-aarch64 | Linux-arm64)
    fetch "$SWIFTLINT/swiftlint_linux_arm64.zip" \
      9ffa52f478e6d8eb485d37d14715ffac90abc81c58f3370d598bf75be05605f8 "$TEMP/swiftlint.zip"
    fetch "$SWIFTFORMAT/swiftformat_linux_aarch64.zip" \
      5ef87b1732964b0efc08eb66fc6c2a6ad01e3de26aa7bcccbf2cfbf983fb3ead "$TEMP/swiftformat.zip"
    ;;
  *) echo "Unsupported platform for Swift tools" >&2; exit 1 ;;
esac
unzip -q "$TEMP/swiftlint.zip" -d "$TEMP/swiftlint"
unzip -q "$TEMP/swiftformat.zip" -d "$TEMP/swiftformat"
# The dynamic Linux build loads SourceKit; the static one silently skips its rules.
install -m 755 "$TEMP/swiftlint/swiftlint" "$BIN/swiftlint"
install -m 755 "$(find "$TEMP/swiftformat" -type f -name 'swiftformat*' | head -1)" "$BIN/swiftformat"
