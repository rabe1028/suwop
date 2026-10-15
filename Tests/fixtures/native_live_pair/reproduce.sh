#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ "$#" -eq 0 ]; then
    output=$(mktemp -d "${TMPDIR:-/tmp}/suwop-native-live-pair-XXXXXX")
elif [ "$#" -eq 1 ]; then
    output=$1
    mkdir "$output"
else
    echo 'Usage: reproduce.sh [new-output-directory]' >&2
    exit 2
fi
xcrun swiftc -parse-as-library "$root/Generate.swift" -o "$output/generate"
xcrun swiftc -parse-as-library "$root/Verify.swift" -o "$output/verify"
"$output/generate" "$output"
"$output/verify" "$output" > "$output/native-validation.json"
printf '%s\n' "$output"
