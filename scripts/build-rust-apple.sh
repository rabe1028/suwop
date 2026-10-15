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
TARGETS=(aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)
for triple in "${TARGETS[@]}"; do
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
done
mkdir -p target/apple/macos target/apple/simulator
lipo -create Generated/RustSlices/{aarch64,x86_64}-apple-darwin/libsuwop_ffi.a -output target/apple/macos/libsuwop_ffi.a
lipo -create Generated/RustSlices/aarch64-apple-ios-sim/libsuwop_ffi.a Generated/RustSlices/x86_64-apple-ios/libsuwop_ffi.a \
    -output target/apple/simulator/libsuwop_ffi.a
rm -rf Generated/RustCore.xcframework
xcodebuild -create-xcframework \
    -library target/apple/macos/libsuwop_ffi.a -headers Generated/RustHeaders \
    -library target/apple/simulator/libsuwop_ffi.a -headers Generated/RustHeaders \
    -library Generated/RustSlices/aarch64-apple-ios/libsuwop_ffi.a -headers Generated/RustHeaders \
    -output Generated/RustCore.xcframework
