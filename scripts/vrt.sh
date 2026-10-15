#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$PWD/.tools/bin:$PATH"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"
export CARGO_PROFILE_DEV_DEBUG="${CARGO_PROFILE_DEV_DEBUG:-0}"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo 'VRT requires an Apple Silicon Mac.' >&2
    exit 1
fi
RECORD=0
CAPTURE=0
if [[ "${1:-}" == --record && $# == 1 ]]; then RECORD=1
elif [[ "${1:-}" == --capture && $# == 1 ]]; then CAPTURE=1
elif [[ $# != 0 ]]; then echo 'Usage: vrt.sh [--record|--capture]' >&2; exit 1
fi
if [[ ( "$RECORD" == 1 || "$CAPTURE" == 1 ) && -n "${CI:-}" ]]; then
    echo 'Baseline recording and incomplete-baseline capture are forbidden in CI.' >&2
    exit 1
fi
mkdir -p DerivedData
# Atomic, per-checkout lock prevents simultaneous builds/profile changes. A stale lock fails visibly.
mkdir DerivedData/VRT.lock || { echo 'Another VRT run owns DerivedData/VRT.lock.' >&2; exit 1; }
trap 'rmdir DerivedData/VRT.lock' EXIT
config() { uv run --no-project python scripts/vrt.py config "$1"; }
XCODE_VERSION="$(config xcode)"
XCODE_BUILD="$(config xcode_build)"
SIMSLIM_VERSION="$(config simslim)"
EXPECTED_XCODE="$(printf 'Xcode %s\nBuild version %s' "$XCODE_VERSION" "$XCODE_BUILD")"
if [[ "$(xcodebuild -version)" != "$EXPECTED_XCODE" ]]; then
    echo 'Select the Xcode pinned in VRT/environment.json with DEVELOPER_DIR.' >&2
    exit 1
fi
if [[ "$(simslim --version)" != "simslim $SIMSLIM_VERSION" ]]; then
    echo 'Run make setup-vrt to install the pinned simslim.' >&2
    exit 1
fi
if [[ "$RECORD" == 0 && "$CAPTURE" == 0 ]]; then uv run --no-project python scripts/vrt.py baseline-check; fi
UDID="$(xcrun simctl list --json | uv run --no-project python scripts/vrt.py device)"
if [[ -z "$UDID" ]]; then
    UDID="$(xcrun simctl create "$(uv run --no-project python scripts/vrt.py name)" "$(config device)" "$(config runtime)")"
fi
ARTIFACTS="$PWD/DerivedData/VRTArtifacts/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$ARTIFACTS" VRT/Baselines
touch "$ARTIFACTS/stages.tsv"
BEFORE="$(uv run --no-project python scripts/vrt.py hashes)"
PASSED=0
cleanup() {
    local status=$?
    if ! xcrun simctl shutdown "$UDID" > "$ARTIFACTS/shutdown.log" 2>&1; then
        echo 'VRT simulator shutdown failed; inspect shutdown.log.' >&2
        status=1
        PASSED=0
    fi
    uv run --no-project python scripts/vrt.py report "$ARTIFACTS" "$RECORD" "$PASSED" "$UDID"
    rmdir DerivedData/VRT.lock
    echo "VRT artifacts: $ARTIFACTS"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stage() {
    local label=$1 started=$SECONDS status=0
    shift
    echo "VRT: $label"
    "$@" > "$ARTIFACTS/$label.log" 2>&1 || status=$?
    printf '%s\t%s\t%s\n' "$label" "$((SECONDS - started))" "$status" >> "$ARTIFACTS/stages.tsv"
    if [[ "$status" != 0 ]]; then tail -100 "$ARTIFACTS/$label.log"; return "$status"; fi
}
stage slim simslim on "$UDID" --profile VRT/simslim.json
stage verify-profile simslim verify "$UDID" --profile VRT/simslim.json --json
stage memory simslim measure "$UDID" --json
stage rust-simulator bash scripts/build-rust-apple.sh --simulator
stage project xcodegen generate
ARGS=(
    -project Suwop.xcodeproj -scheme SuwopVRT
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath DerivedData/VRT
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1
    -testLanguage ja -testRegion JP CODE_SIGNING_ALLOWED=NO
    "SUWOP_VRT_RECORD=$RECORD" "SUWOP_VRT_BASELINES=$PWD/VRT/Baselines"
    "SUWOP_VRT_ARTIFACTS=$ARTIFACTS"
)
stage build xcodebuild "${ARGS[@]}" build-for-testing
stage compare xcodebuild "${ARGS[@]}" -resultBundlePath "$ARTIFACTS/Tests.xcresult" test-without-building
uv run --no-project python scripts/vrt.py coverage "$ARTIFACTS"
if [[ "$RECORD" == 0 && "$(uv run --no-project python scripts/vrt.py hashes)" != "$BEFORE" ]]; then
    echo 'Comparison modified baseline images.' >&2
    exit 1
fi
PASSED=1
if [[ "$RECORD" == 1 ]]; then echo 'Review recorded images, then run make vrt to compare.'; fi
