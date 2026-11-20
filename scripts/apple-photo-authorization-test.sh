#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
    full) SCENARIO=testInitialFullGrant ;;
    limited) SCENARIO=testLimitedMembership ;;
    denied) SCENARIO=testInitialDenial ;;
    interrupted) SCENARIO=testInterruptsRealPhotoKitScanAndRequiresFreshAuthority ;;
    settings-denial) SCENARIO=testSettingsDenialAndRegrantPreserveIsolation ;;
    duplicates) SCENARIO=testRealOriginalIndexEnablesReadOnlyDuplicateReview ;;
    *) echo 'Choose full, limited, denied, interrupted, settings-denial or duplicates.' >&2; exit 2 ;;
esac
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if command -v mise >/dev/null; then PATH="$(mise bin-paths | tr '\n' ':')$PATH"; fi
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"
export CARGO_PROFILE_DEV_DEBUG="${CARGO_PROFILE_DEV_DEBUG:-0}"
config() { uv run --no-project python scripts/vrt.py config "$1"; }
EXPECTED_XCODE="$(printf 'Xcode %s\nBuild version %s' "$(config xcode)" "$(config xcode_build)")"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ||
    "$(xcodebuild -version)" != "$EXPECTED_XCODE" || "$(simslim --version)" != "simslim $(config simslim)" ]]; then
    echo 'Select the pinned Xcode and iOS environment in VRT/environment.json; run make setup-vrt.' >&2
    exit 1
fi
# Verify exact available runtime before creating a device. The returned VRT destination is unused.
xcrun simctl list --json | uv run --no-project python scripts/vrt.py device >/dev/null
RUN="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ARTIFACTS="$PWD/DerivedData/PhotoAuthorizationArtifacts/$RUN"
mkdir -p "$ARTIFACTS"
# VRT shares the generated Xcode project and Rust product in this checkout.
mkdir DerivedData/VRT.lock || { echo 'Another simulator test owns the checkout lock.' >&2; exit 1; }
UDID=
cleanup() {
    local status=$?
    if [[ -n "$UDID" ]] && ! xcrun simctl shutdown "$UDID" >"$ARTIFACTS/shutdown.log" 2>&1; then status=1; fi
    rmdir DerivedData/VRT.lock
    echo "Photo authorization artifacts: $ARTIFACTS"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stage() {
    local label=$1 started=$SECONDS status=0
    shift
    echo "Photo authorization: $label"
    "$@" >"$ARTIFACTS/$label.log" 2>&1 || status=$?
    printf '%s\t%s\t%s\n' "$label" "$((SECONDS - started))" "$status" >>"$ARTIFACTS/stages.tsv"
    if [[ "$status" != 0 ]]; then tail -80 "$ARTIFACTS/$label.log"; fi
    return "$status"
}

stage rust-simulator bash scripts/build-rust-apple.sh --simulator
stage project xcodegen generate
CHECKOUT_ID="$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12)"
UDID="$(xcrun simctl create "Suwop PhotoAuth $CHECKOUT_ID $RUN" "$(config device)" "$(config runtime)")"
printf '%s\n' "$UDID" >"$ARTIFACTS/simulator-udid.txt"
stage slim simslim on "$UDID" --profile NativeAcceptance/simslim.json
stage profile simslim verify "$UDID" --profile NativeAcceptance/simslim.json --json
stage photos-services simslim doctor "$UDID" --requires photos --json
stage fixtures uv run --no-project python scripts/photokit-authorization.py fixtures "$ARTIFACTS"
stage fixture-hashes shasum -a 256 "$ARTIFACTS/red-landscape.png" "$ARTIFACTS/blue-portrait.png"
stage addmedia xcrun simctl addmedia "$UDID" "$ARTIFACTS/red-landscape.png" "$ARTIFACTS/blue-portrait.png"

ARGS=(
    -clonedSourcePackagesDirPath "$PWD/DerivedData/SourcePackages"
    -project Suwop.xcodeproj -scheme SuwopPhotoAuthorization
    -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath DerivedData/PhotoAuthorization
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1
    CODE_SIGNING_ALLOWED=NO
)
stage build xcodebuild "${ARGS[@]}" build-for-testing
NATIVE_STATUS=0
stage native xcodebuild "${ARGS[@]}" -resultBundlePath "$ARTIFACTS/Tests.xcresult" \
    "-only-testing:SuwopPhotoAuthorizationTests/PhotoAuthorizationTests/$SCENARIO" test-without-building || NATIVE_STATUS=$?
if [[ -d "$ARTIFACTS/Tests.xcresult" ]]; then
    stage summary xcrun xcresulttool get test-results summary --path "$ARTIFACTS/Tests.xcresult" || NATIVE_STATUS=1
    stage tests xcrun xcresulttool get test-results tests --path "$ARTIFACTS/Tests.xcresult" || NATIVE_STATUS=1
    stage attachments xcrun xcresulttool export attachments --path "$ARTIFACTS/Tests.xcresult" \
        --output-path "$ARTIFACTS/Attachments" || NATIVE_STATUS=1
fi
if [[ "$NATIVE_STATUS" != 0 ]]; then exit "$NATIVE_STATUS"; fi
stage coverage uv run --no-project python scripts/photokit-authorization.py verify "$ARTIFACTS" "$SCENARIO" "$UDID"
