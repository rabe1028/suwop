#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p Generated
if [[ "${1:-}" == "--host" ]]; then
    export SDKROOT
    SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
    cargo build --locked -p suwop-ffi
    rm -rf Generated/RustCore.xcframework
    xcodebuild -create-xcframework -library target/debug/libsuwop_ffi.a \
        -headers Sources/CSuwop/include -output Generated/RustCore.xcframework
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
done
mkdir -p target/apple/macos target/apple/simulator
lipo -create target/{aarch64,x86_64}-apple-darwin/release/libsuwop_ffi.a -output target/apple/macos/libsuwop_ffi.a
lipo -create target/aarch64-apple-ios-sim/release/libsuwop_ffi.a target/x86_64-apple-ios/release/libsuwop_ffi.a \
    -output target/apple/simulator/libsuwop_ffi.a
rm -rf Generated/RustCore.xcframework
xcodebuild -create-xcframework \
    -library target/apple/macos/libsuwop_ffi.a -headers Sources/CSuwop/include \
    -library target/apple/simulator/libsuwop_ffi.a -headers Sources/CSuwop/include \
    -library target/aarch64-apple-ios/release/libsuwop_ffi.a -headers Sources/CSuwop/include \
    -output Generated/RustCore.xcframework
