#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# All native dependencies must inherit the application's minimum OS from their first build.
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export MACOSX_DEPLOYMENT_TARGET=14.0
mkdir -p Generated/RustHeaders/CSuwop
# Namespace the module map: LiteRT also installs headers into Products/include.
cp Sources/CSuwop/include/module.modulemap Sources/CSuwop/include/suwop.h Generated/RustHeaders/CSuwop/

if [[ "${1:-}" == "--simulator" ]]; then
    # VRT needs only the current Apple Silicon simulator slice; retain Cargo's build cache.
    export SDKROOT
    SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    rustup target add aarch64-apple-ios-sim
    cargo build --locked -p suwop-ffi --target aarch64-apple-ios-sim
    rm -rf Generated/RustCore.xcframework
    xcodebuild -create-xcframework -library target/aarch64-apple-ios-sim/debug/libsuwop_ffi.a \
        -headers Generated/RustHeaders -output Generated/RustCore.xcframework
    exit 0
fi
if [[ "${1:-}" == "--host" ]]; then
    export SDKROOT
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
    cargo build --locked -p suwop-ffi
    rm -rf Generated/RustCore.xcframework
    xcodebuild -create-xcframework -library target/debug/libsuwop_ffi.a \
        -headers Generated/RustHeaders -output Generated/RustCore.xcframework
    exit 0
fi
TARGETS=(aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim)
build_slice() {
    local triple="$1" SDK
    rustup target add "$triple"
    case "$triple" in
        *-apple-darwin) SDK=macosx ;;
        aarch64-apple-ios) SDK=iphoneos ;;
        *) SDK=iphonesimulator ;;
    esac
    export SDKROOT
    SDKROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
    cargo build --locked --release -p suwop-ffi --target "$triple"
    # Retain finished slices while optionally reclaiming large Lance object caches.
    mkdir -p "Generated/RustSlices/$triple"
    cp "target/$triple/release/libsuwop_ffi.a" "Generated/RustSlices/$triple/libsuwop_ffi.a"
    if [[ "${SUWOP_CLEAN_CHECK:-0}" == "1" ]]; then
        # Only this completed, retained slice's generated objects; keep host/test caches.
        rm -rf -- "target/$triple/release"
    fi
}
case "${1:-}" in
    --slice)
        [[ "$#" == 2 ]] || { echo "Expected one Apple target" >&2; exit 1; }
        case "$2" in
            aarch64-apple-darwin|aarch64-apple-ios|aarch64-apple-ios-sim) ;;
            *) echo "Unsupported Apple target: $2" >&2; exit 1 ;;
        esac
        build_slice "$2"
        uv run --no-project python scripts/apple_slices.py stamp "$2"
        exit 0
        ;;
    --package)
        [[ "$#" == 1 ]] || exit 1
        # Require all three ARM64 slices from this exact clean checkout before replacing output.
        uv run --no-project python scripts/apple_slices.py verify
        ;;
    "")
        for triple in "${TARGETS[@]}"; do build_slice "$triple"; done
        ;;
    *) echo "Unknown build mode: $1" >&2; exit 1 ;;
esac
rm -rf Generated/RustCore.xcframework
xcodebuild -create-xcframework \
    -library Generated/RustSlices/aarch64-apple-darwin/libsuwop_ffi.a -headers Generated/RustHeaders \
    -library Generated/RustSlices/aarch64-apple-ios-sim/libsuwop_ffi.a -headers Generated/RustHeaders \
    -library Generated/RustSlices/aarch64-apple-ios/libsuwop_ffi.a -headers Generated/RustHeaders \
    -output Generated/RustCore.xcframework
