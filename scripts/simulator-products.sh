#!/usr/bin/env bash
# Build VRT and PhotoKit test products once for every simulator lane.
# Lanes run them with test-without-building -xctestrun and never rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if command -v mise > /dev/null; then PATH="$(mise bin-paths | tr '\n' ':')$PATH"; fi
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
export CARGO_INCREMENTAL="${CARGO_INCREMENTAL:-0}"
export CARGO_PROFILE_DEV_DEBUG="${CARGO_PROFILE_DEV_DEBUG:-0}"
OUTPUT="${1:?Usage: simulator-products.sh OUTPUT_DIR}"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo 'Simulator products require an Apple Silicon Mac.' >&2
    exit 1
fi
config() { uv run --no-project python scripts/vrt.py config "$1"; }
if [[ "$(xcodebuild -version)" != "$(printf 'Xcode %s\nBuild version %s' "$(config xcode)" "$(config xcode_build)")" ]]; then
    echo 'Select the Xcode pinned in VRT/environment.json with DEVELOPER_DIR.' >&2
    exit 1
fi
# The pinned device is the build destination and boots only to enumerate tests.
UDID="$(xcrun simctl list --json | uv run --no-project python scripts/vrt.py device)"
if [[ -z "$UDID" ]]; then
    UDID="$(xcrun simctl create "$(uv run --no-project python scripts/vrt.py name)" "$(config device)" "$(config runtime)")"
fi
bash scripts/build-rust-apple.sh --simulator
xcodegen generate
COMMON=(
    -clonedSourcePackagesDirPath "$PWD/DerivedData/SourcePackages" -project Suwop.xcodeproj
    -destination "platform=iOS Simulator,id=$UDID"
    -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1
    CODE_SIGNING_ALLOWED=NO
)
# Lanes replace these scheme environment values in the xctestrun before running.
xcodebuild "${COMMON[@]}" -scheme SuwopVRT -derivedDataPath DerivedData/VRT \
    -testLanguage ja -testRegion JP \
    SUWOP_VRT_RECORD=0 SUWOP_VRT_BASELINES=unbound SUWOP_VRT_ARTIFACTS=unbound build-for-testing
# Enumerate the built VRT tests once for every lane. Enumeration needs a booted
# device, so it runs while PhotoKit builds instead of in each lane.
ENUMERATION="$PWD/DerivedData/VRTEnumeration"
mkdir -p "$ENUMERATION"
rm -f "$ENUMERATION/registered-raw.json"
WAS_BOOTED=0
if xcrun simctl list devices | grep -F "$UDID" | grep -q Booted; then WAS_BOOTED=1; fi
VRT_RUN="$(find DerivedData/VRT/Build/Products -maxdepth 1 -name '*.xctestrun' | head -1)"
{
    # A stock simulator needs about 4 GB; booting it beside the PhotoKit build
    # swapped on 7 GB runners (run 39919532380). Boot it slim, as lanes do.
    if [[ "$WAS_BOOTED" == 0 ]]; then simslim on "$UDID" --profile VRT/simslim.json; fi
    xcodebuild test-without-building -xctestrun "$VRT_RUN" -destination "platform=iOS Simulator,id=$UDID" \
        -enumerate-tests -test-enumeration-style flat -test-enumeration-format json \
        -test-enumeration-output-path "$ENUMERATION/registered-raw.json"
} > "$ENUMERATION/enumerate.log" 2>&1 &
ENUMERATE_PID=$!
xcodebuild "${COMMON[@]}" -scheme SuwopPhotoKit -derivedDataPath DerivedData/PhotoKit build-for-testing
if ! wait "$ENUMERATE_PID"; then
    tail -50 "$ENUMERATION/enumerate.log" >&2
    exit 1
fi
# A lane that already booted and slimmed this device keeps it running.
if [[ "$WAS_BOOTED" == 0 ]]; then xcrun simctl shutdown "$UDID"; fi
uv run --no-project python scripts/simulator_products.py stage "$OUTPUT"
