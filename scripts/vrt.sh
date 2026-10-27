#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if command -v mise > /dev/null; then PATH="$(mise bin-paths | tr '\n' ':')$PATH"; fi
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"
export CARGO_PROFILE_DEV_DEBUG="${CARGO_PROFILE_DEV_DEBUG:-0}"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo 'VRT requires an Apple Silicon Mac.' >&2
    exit 1
fi
RECORD=0
CAPTURE=0
LANE=""
if [[ "${1:-}" == --record && $# == 1 ]]; then RECORD=1
elif [[ "${1:-}" == --capture && $# == 1 ]]; then CAPTURE=1
elif [[ "${1:-}" == --ci-lane && $# == 2 ]]; then
    case "$2" in host-snapshots|ui-[1-9]) LANE="$2" ;; *) echo 'Unknown CI VRT lane' >&2; exit 1 ;; esac
elif [[ $# != 0 ]]; then echo 'Usage: vrt.sh [--record|--capture|--ci-lane host-snapshots|ui-N]' >&2; exit 1
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
    if [[ -n "$LANE" ]]; then
        uv run --no-project python scripts/vrt_lanes.py report "$ARTIFACTS" "$LANE" "$status" "$PASSED" || status=1
    else
        uv run --no-project python scripts/vrt.py report "$ARTIFACTS" "$RECORD" "$PASSED" "$UDID"
    fi
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
if [[ -n "$LANE" ]]; then stage begin uv run --no-project python scripts/vrt_lanes.py begin "$ARTIFACTS"; fi
stage slim simslim on "$UDID" --profile VRT/simslim.json
stage verify-profile simslim verify "$UDID" --profile VRT/simslim.json --json
stage memory simslim measure "$UDID" --json
lane_products() {
    # CI builds simulator products once for every lane; a local lane builds its own.
    if [[ -z "${SUWOP_SIMULATOR_PRODUCTS:-}" ]]; then
        SUWOP_SIMULATOR_PRODUCTS="$PWD/DerivedData/SimulatorProducts/$(basename "$ARTIFACTS")"
        bash scripts/simulator-products.sh "$SUWOP_SIMULATOR_PRODUCTS"
    fi
    uv run --no-project python scripts/simulator_products.py prepare-vrt \
        "$SUWOP_SIMULATOR_PRODUCTS" "$ARTIFACTS" > "$ARTIFACTS/xctestrun.txt"
}
if [[ -n "$LANE" ]]; then
    stage products lane_products
    ARGS=(
        -xctestrun "$(cat "$ARTIFACTS/xctestrun.txt")"
        -destination "platform=iOS Simulator,id=$UDID"
        -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1
    )
else
    stage rust-simulator bash scripts/build-rust-apple.sh --simulator
    stage project xcodegen generate
    ARGS=(
        -clonedSourcePackagesDirPath "$PWD/DerivedData/SourcePackages"
        -project Suwop.xcodeproj -scheme SuwopVRT
        -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath DerivedData/VRT
        -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1
        -testLanguage ja -testRegion JP CODE_SIGNING_ALLOWED=NO
        "SUWOP_VRT_RECORD=$RECORD" "SUWOP_VRT_BASELINES=$PWD/VRT/Baselines"
        "SUWOP_VRT_ARTIFACTS=$ARTIFACTS"
    )
    stage build xcodebuild "${ARGS[@]}" build-for-testing
fi
if [[ -n "$LANE" ]]; then
    stage enumerate xcodebuild "${ARGS[@]}" test-without-building -enumerate-tests \
        -test-enumeration-style flat -test-enumeration-format json \
        -test-enumeration-output-path "$ARTIFACTS/registered-raw.json"
    stage inventory uv run --no-project python scripts/vrt_lanes.py inventory \
        "$ARTIFACTS/registered-raw.json" "$ARTIFACTS/registered-tests.json"
    # UI lanes enumerate every test; organization/selection classes each have one
    # explicit owner and remaining tests balance deterministically by duration.
    stage select uv run --no-project python scripts/vrt_lanes.py select "$ARTIFACTS" "$LANE"
    ONLY=()
    while IFS= read -r selected; do ONLY+=("-only-testing:$selected"); done < "$ARTIFACTS/only-testing.txt"
    stage compare xcodebuild "${ARGS[@]}" "${ONLY[@]}" \
        -resultBundlePath "$ARTIFACTS/Tests.xcresult" test-without-building
else
    stage compare xcodebuild "${ARGS[@]}" -resultBundlePath "$ARTIFACTS/Tests.xcresult" test-without-building
fi
if [[ -n "$LANE" ]]; then
    stage test-inventory xcrun xcresulttool get test-results tests --path "$ARTIFACTS/Tests.xcresult" --compact
    stage test-summary xcrun xcresulttool get test-results summary --path "$ARTIFACTS/Tests.xcresult" --compact
    stage lane-validation uv run --no-project python scripts/vrt_lanes.py validate "$ARTIFACTS" "$LANE"
else
    uv run --no-project python scripts/vrt.py coverage "$ARTIFACTS"
fi
if [[ "$RECORD" == 0 && "$(uv run --no-project python scripts/vrt.py hashes)" != "$BEFORE" ]]; then
    echo 'Comparison modified baseline images.' >&2
    exit 1
fi
PASSED=1
if [[ "$RECORD" == 1 ]]; then echo 'Review recorded images, then run make vrt to compare.'; fi
