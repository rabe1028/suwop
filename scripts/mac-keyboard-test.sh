#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
unset SUWOP_PERFORMANCE_TRACE

mkdir -p DerivedData/MacKeyboardArtifacts
artifacts="$(mktemp -d "$PWD/DerivedData/MacKeyboardArtifacts/run.XXXXXXXX")"
derived="$PWD/DerivedData/MacKeyboard"
echo "Mac keyboard acceptance artifacts: $artifacts"

bash scripts/build-rust-apple.sh --host
xcodegen generate
args=(
    -clonedSourcePackagesDirPath "$PWD/DerivedData/SourcePackages"
    -project Suwop.xcodeproj -scheme SuwopMacKeyboard
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived"
    -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
)
xcodebuild "${args[@]}" build-for-testing

app="$derived/Build/Products/Debug/SuwopMacKeyboardHost.app"
# Xcode adds temporary filesystem exceptions to an app built for UI testing.
# Sign this fixture with its own restricted entitlements before any launch.
codesign --force --sign - --timestamp=none --generate-entitlement-der \
    --entitlements NativeAcceptance/MacKeyboardHost/Fixture.entitlements "$app"
codesign --verify --strict "$app"
codesign --display --xml --entitlements - "$app" > "$artifacts/entitlements.plist"
uv run --no-project python - "$app/Contents/Info.plist" "$artifacts/entitlements.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

info, entitlements = (plistlib.loads(Path(path).read_bytes()) for path in sys.argv[1:])
if info.get("CFBundleIdentifier") != "jp.rabe1028.suwop.mac-keyboard.fixture":
    raise SystemExit("Unexpected Mac keyboard acceptance bundle identifier")
if entitlements != {"com.apple.security.app-sandbox": True}:
    raise SystemExit("Mac keyboard fixture must have only the sandbox entitlement")
PY

xcodebuild "${args[@]}" -resultBundlePath "$artifacts/Tests.xcresult" test-without-building
xcrun xcresulttool get test-results summary --path "$artifacts/Tests.xcresult" > "$artifacts/summary.json"
uv run --no-project python - "$artifacts/summary.json" <<'PY'
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text())
counts = [summary[key] for key in ("passedTests", "failedTests", "skippedTests", "totalTestCount")]
if counts != [2, 0, 0, 2]:
    raise SystemExit(f"Expected two passing Mac keyboard tests. Receipt counts: {counts}")
PY
