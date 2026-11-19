#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if command -v mise > /dev/null; then PATH="$(mise bin-paths | tr '\n' ':')$PATH"; fi
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
export CARGO_TARGET_DIR="$PWD/target"

SIZES=(10000 100000)
if [[ $# == 1 && ( "$1" == 10000 || "$1" == 100000 ) ]]; then
    SIZES=("$1")
elif [[ $# != 0 ]]; then
    echo 'Usage: gallery-performance.sh [10000|100000]' >&2
    exit 2
fi
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo 'Gallery performance requires an Apple Silicon Mac.' >&2
    exit 1
fi

mkdir -p DerivedData/GalleryPerformance
mkdir DerivedData/VRT.lock || { echo 'Another simulator build owns the checkout lock.' >&2; exit 1; }
ARTIFACTS=""
UDID=""
CORE=Generated/RustCore.xcframework
PRIOR_CORE=""
CORE_BUILD_STARTED=0
simulator_state() {
    xcrun simctl list devices --json "$UDID" |
        uv run --no-project python scripts/gallery_performance.py simulator-state "$UDID"
}
cleanup() {
    local status=$?
    if [[ -n "$UDID" && "$(simulator_state)" != Shutdown ]]; then
        # Keep the run-owned simulator for diagnosis.
        if ! xcrun simctl shutdown "$UDID" > "$ARTIFACTS/shutdown.log" 2>&1 &&
            [[ "$(simulator_state)" != Shutdown ]]; then
            status=1
        fi
    fi
    if [[ "$CORE_BUILD_STARTED" == 1 && ( -e "$CORE" || -L "$CORE" ) ]]; then
        mv "$CORE" "$ARTIFACTS/RustCore.xcframework" || status=1
    fi
    if [[ -n "$PRIOR_CORE" && ( -e "$PRIOR_CORE" || -L "$PRIOR_CORE" ) ]]; then
        if [[ -e "$CORE" || -L "$CORE" ]]; then
            echo "Could not restore $CORE. The prior contents are preserved at $PRIOR_CORE." >&2
            status=1
        else
            mv "$PRIOR_CORE" "$CORE" || status=1
        fi
    fi
    rmdir DerivedData/VRT.lock || status=1
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ARTIFACTS="$(mktemp -d "$PWD/DerivedData/GalleryPerformance/run.XXXXXXXX")"
echo "Gallery performance artifacts: $ARTIFACTS"
config() { uv run --no-project python scripts/vrt.py config "$1"; }
stage() {
    local label=$1 status=0
    shift
    echo "Gallery performance: $label"
    "$@" > "$ARTIFACTS/$label.log" 2>&1 || status=$?
    if [[ "$status" != 0 ]]; then tail -80 "$ARTIFACTS/$label.log"; fi
    return "$status"
}

collect_app_evidence() {
    local count=$1 directory=$2 container file status=0
    if [[ "$(simulator_state)" != Booted ]]; then
        echo 'Restoring the run-owned Simulator for app evidence collection.'
        xcrun simctl bootstatus "$UDID" -b || return 1
    fi
    container="$(xcrun simctl get_app_container "$UDID" jp.rabe1028.suwop.gallery-performance data)" || return 1
    for file in app.json trace.json; do
        if [[ -f "$container/Documents/GalleryPerformance-$count/$file" ]]; then
            cp "$container/Documents/GalleryPerformance-$count/$file" "$directory/$file" || status=1
        else
            echo "Missing generated app evidence: $file" >&2
            status=1
        fi
    done
    return "$status"
}

xcodebuild -version > "$ARTIFACTS/xcode.txt"
EXPECTED_XCODE="$(printf 'Xcode %s\nBuild version %s' "$(config xcode)" "$(config xcode_build)")"
if [[ "$(cat "$ARTIFACTS/xcode.txt")" != "$EXPECTED_XCODE" ]]; then
    echo 'Select the Xcode pinned in VRT/environment.json with DEVELOPER_DIR.' >&2
    exit 1
fi
xcrun simctl list runtimes --json > "$ARTIFACTS/runtimes.json"
uv run --no-project python scripts/gallery_performance.py begin "$ARTIFACTS"
if [[ -e "$CORE" || -L "$CORE" ]]; then
    PRIOR_CORE="$ARTIFACTS/prior-rust-core.xcframework"
    mv "$CORE" "$PRIOR_CORE"
fi
CORE_BUILD_STARTED=1
stage rust bash scripts/build-rust-apple.sh --simulator-release
stage project xcodegen generate

UDID="$(xcrun simctl create "Suwop Gallery Performance $(basename "$ARTIFACTS")" "$(config device)" "$(config runtime)")"
printf '%s\n' "$UDID" > "$ARTIFACTS/simulator.txt"
ARGS=(
    -project Suwop.xcodeproj -scheme SuwopGalleryPerformance -configuration Release
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$ARTIFACTS/build"
    -clonedSourcePackagesDirPath "$ARTIFACTS/build/SourcePackages" -disableAutomaticPackageResolution
    CODE_SIGNING_ALLOWED=NO
)
TEST_ARGS=(
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1
    -testLanguage ja -testRegion JP
)
xcodebuild "${ARGS[@]}" -showBuildSettings -json > "$ARTIFACTS/build-settings.json"
stage build xcodebuild "${ARGS[@]}" build-for-testing
stage boot xcrun simctl bootstatus "$UDID" -b
RUN_STATUS=0
for count in "${SIZES[@]}"; do
    case "$count" in
        10000) method=testTenThousandGeneratedPhotos ;;
        100000) method=testHundredThousandGeneratedPhotos ;;
    esac
    CASE="$ARTIFACTS/$count"
    mkdir "$CASE"
    STATUS=0
    stage "$count/ui" xcodebuild "${ARGS[@]}" "${TEST_ARGS[@]}" \
        "-only-testing:SuwopGalleryPerformanceUI/GalleryPerformanceUITests/$method" \
        -resultBundlePath "$CASE/Test.xcresult" test-without-building || STATUS=$?
    if [[ -d "$CASE/Test.xcresult" ]]; then
        stage "$count/summary" xcrun xcresulttool get test-results summary --path "$CASE/Test.xcresult" || STATUS=$?
        stage "$count/tests" xcrun xcresulttool get test-results tests --path "$CASE/Test.xcresult" || STATUS=$?
        stage "$count/export" xcrun xcresulttool export attachments \
            --path "$CASE/Test.xcresult" --output-path "$CASE/attachments" || STATUS=$?
    fi
    stage "$count/container" collect_app_evidence "$count" "$CASE" || STATUS=$?
    if [[ "$STATUS" == 0 ]]; then
        uv run --no-project python scripts/performance_report.py "$CASE/trace.json" > "$CASE/trace-summary.json" ||
            STATUS=$?
    fi
    if [[ "$STATUS" == 0 ]]; then
        uv run --no-project python scripts/gallery_performance.py check "$CASE" || STATUS=$?
    fi
    if [[ "$STATUS" != 0 ]]; then RUN_STATUS="$STATUS"; fi
done
if [[ "$RUN_STATUS" != 0 ]]; then exit "$RUN_STATUS"; fi
uv run --no-project python scripts/gallery_performance.py finish "$ARTIFACTS" "${SIZES[@]}"
