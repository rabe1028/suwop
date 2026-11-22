#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if command -v mise >/dev/null; then PATH="$(mise bin-paths | tr '\n' ':')$PATH"; fi
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"
export CARGO_PROFILE_DEV_DEBUG="${CARGO_PROFILE_DEV_DEBUG:-0}"
config() { uv run --no-project python scripts/vrt.py config "$1"; }
EXPECTED_XCODE="$(printf 'Xcode %s\nBuild version %s' "$(config xcode)" "$(config xcode_build)")"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 || "$(xcodebuild -version)" != "$EXPECTED_XCODE" ]]; then
    echo 'Select the Xcode and iOS environment pinned in VRT/environment.json.' >&2
    exit 1
fi
xcrun simctl list --json | uv run --no-project python scripts/vrt.py device >/dev/null

mkdir -p DerivedData/ProviderConfig
ARTIFACTS="$(mktemp -d "$PWD/DerivedData/ProviderConfig/run.XXXXXXXX")"
mkdir DerivedData/VRT.lock || { echo 'Another simulator test owns the checkout lock.' >&2; exit 1; }
UDID=""
BOOT_STARTED=0
CORE=Generated/RustCore.xcframework
PRIOR_CORE=""
CORE_BUILD_STARTED=0
cleanup() {
    local status=$?
    if [[ -n "$UDID" && "$BOOT_STARTED" == 1 ]] &&
        ! xcrun simctl shutdown "$UDID" >"$ARTIFACTS/shutdown.log" 2>&1; then
        status=1
    fi
    if [[ "$CORE_BUILD_STARTED" == 1 && ( -e "$CORE" || -L "$CORE" ) ]]; then
        mv "$CORE" "$ARTIFACTS/RustCore.xcframework" || status=1
    fi
    if [[ -n "$PRIOR_CORE" && ( -e "$PRIOR_CORE" || -L "$PRIOR_CORE" ) ]]; then
        if [[ -e "$CORE" || -L "$CORE" ]]; then
            echo "Prior XCFramework preserved at $PRIOR_CORE." >&2
            status=1
        else
            mv "$PRIOR_CORE" "$CORE" || status=1
        fi
    fi
    rmdir DerivedData/VRT.lock || status=1
    echo "Immich provider configuration artifacts: $ARTIFACTS"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stage() {
    local label=$1 status=0
    shift
    echo "Provider configuration: $label"
    "$@" >"$ARTIFACTS/$label.log" 2>&1 || status=$?
    if [[ "$status" != 0 ]]; then tail -80 "$ARTIFACTS/$label.log"; fi
    return "$status"
}

if [[ -e "$CORE" || -L "$CORE" ]]; then
    PRIOR_CORE="$ARTIFACTS/prior-rust-core.xcframework"
    mv "$CORE" "$PRIOR_CORE"
fi
CORE_BUILD_STARTED=1
stage rust bash scripts/build-rust-apple.sh --simulator
stage project xcodegen generate
UDID="$(xcrun simctl create "Suwop Provider Config $(basename "$ARTIFACTS")" "$(config device)" "$(config runtime)")"
printf '%s\n' "$UDID" >"$ARTIFACTS/simulator.txt"
ARGS=(
    -project Suwop.xcodeproj -scheme SuwopProviderConfig
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$ARTIFACTS/build"
    -clonedSourcePackagesDirPath "$ARTIFACTS/build/SourcePackages" CODE_SIGNING_ALLOWED=NO
)
stage build xcodebuild "${ARGS[@]}" build-for-testing
BOOT_STARTED=1
stage boot xcrun simctl bootstatus "$UDID" -b
TEST_STATUS=0
stage test xcodebuild "${ARGS[@]}" -parallel-testing-enabled NO \
    -testLanguage ja -testRegion JP -resultBundlePath "$ARTIFACTS/Test.xcresult" \
    -only-testing:SuwopProviderConfigTests/ProviderConfigUITests/testImmichAccountCutoverRejectsHeldRaster \
    test-without-building || TEST_STATUS=$?
stage transport xcrun simctl spawn "$UDID" log show --last 15m --style compact \
    --predicate 'process == "SuwopProviderConfigHost" AND subsystem == "jp.rabe1028.suwop.provider-config" AND category == "transport-phase"' \
    || true
if [[ -d "$ARTIFACTS/Test.xcresult" ]]; then
    stage summary xcrun xcresulttool get test-results summary --path "$ARTIFACTS/Test.xcresult" || TEST_STATUS=1
    stage tests xcrun xcresulttool get test-results tests --path "$ARTIFACTS/Test.xcresult" || TEST_STATUS=1
    stage attachments xcrun xcresulttool export attachments \
        --path "$ARTIFACTS/Test.xcresult" \
        --output-path "$ARTIFACTS/Attachments" || TEST_STATUS=1
fi
if [[ "$TEST_STATUS" != 0 ]]; then exit "$TEST_STATUS"; fi
stage coverage uv run --no-project python scripts/provider-config-acceptance.py "$ARTIFACTS" "$UDID"
