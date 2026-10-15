#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$PWD/.tools/bin:$PATH"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"
export CARGO_PROFILE_DEV_DEBUG="${CARGO_PROFILE_DEV_DEBUG:-0}"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo 'Native acceptance requires Apple Silicon and the pinned Xcode / iOS runtime.' >&2
    exit 1
fi
config() { uv run --no-project python scripts/vrt.py config "$1"; }
EXPECTED_XCODE="$(printf 'Xcode %s\nBuild version %s' "$(config xcode)" "$(config xcode_build)")"
if [[ "$(xcodebuild -version)" != "$EXPECTED_XCODE" || "$(simslim --version)" != "simslim $(config simslim)" ]]; then
    echo 'Select the pinned environment in VRT/environment.json; run make setup-vrt.' >&2
    exit 1
fi
mkdir -p DerivedData
# Same lock and device as VRT; the real Photos scenario must never overlap snapshots.
mkdir DerivedData/VRT.lock || { echo 'Another simulator test owns the checkout lock.' >&2; exit 1; }
trap 'rmdir DerivedData/VRT.lock' EXIT
UDID="$(xcrun simctl list --json | uv run --no-project python scripts/vrt.py device)"
if [[ -z "$UDID" ]]; then
    UDID="$(xcrun simctl create "$(uv run --no-project python scripts/vrt.py name)" "$(config device)" "$(config runtime)")"
fi
ARTIFACTS="$PWD/DerivedData/PhotoKitArtifacts/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$ARTIFACTS"
touch "$ARTIFACTS/stages.tsv"
cleanup() {
    local status=$?
    if ! xcrun simctl shutdown "$UDID" > "$ARTIFACTS/shutdown.log" 2>&1; then status=1; fi
    uv run --no-project python scripts/native-acceptance.py report "$ARTIFACTS" "$status" "$UDID"
    rmdir DerivedData/VRT.lock
    echo "PhotoKit artifacts: $ARTIFACTS"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stage() {
    local label=$1 started=$SECONDS status=0
    shift
    echo "PhotoKit: $label"
    "$@" > "$ARTIFACTS/$label.log" 2>&1 || status=$?
    printf '%s\t%s\t%s\n' "$label" "$((SECONDS - started))" "$status" >> "$ARTIFACTS/stages.tsv"
    if [[ "$status" != 0 ]]; then tail -80 "$ARTIFACTS/$label.log"; return "$status"; fi
}
stage slim simslim on "$UDID" --profile NativeAcceptance/simslim.json
stage profile simslim verify "$UDID" --profile NativeAcceptance/simslim.json --json
stage photos-services simslim doctor "$UDID" --requires photos --json
stage memory simslim measure "$UDID" --json
stage rust-simulator bash scripts/build-rust-apple.sh --simulator
stage project xcodegen generate
ARGS=(
    -clonedSourcePackagesDirPath "$PWD/DerivedData/SourcePackages"
    -project Suwop.xcodeproj -scheme SuwopPhotoKit
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath DerivedData/PhotoKit
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1
    CODE_SIGNING_ALLOWED=NO
)
stage build xcodebuild "${ARGS[@]}" build-for-testing
stage install xcrun simctl install "$UDID" DerivedData/PhotoKit/Build/Products/Debug-iphonesimulator/SuwopPhotoKitHost.app
stage permission xcrun simctl privacy "$UDID" grant photos jp.rabe1028.suwop.photokit.acceptance
stage native xcodebuild "${ARGS[@]}" -resultBundlePath "$ARTIFACTS/Tests.xcresult" test-without-building
stage coverage uv run --no-project python scripts/native-acceptance.py coverage "$ARTIFACTS"
