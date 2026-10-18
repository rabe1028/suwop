#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
xcodegen generate
mkdir -p DerivedData/PrivateLiveMac/TestResults
RESULT="DerivedData/PrivateLiveMac/TestResults/Test-$(date -u +%Y%m%dT%H%M%SZ)-$$.xcresult"
status=0
xcodebuild -clonedSourcePackagesDirPath "$ROOT/DerivedData/SourcePackages" -project Suwop.xcodeproj -scheme SuwopPrivateLiveMac \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData/PrivateLiveMac \
  -resultBundlePath "$RESULT" -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180 CODE_SIGNING_ALLOWED=NO test || status=$?
SUMMARY="${RESULT%.xcresult}-summary.json"
xcrun xcresulttool get test-results summary --path "$RESULT" --compact > "$SUMMARY"
TESTS="${RESULT%.xcresult}-tests.json"
AUDIT="${RESULT%.xcresult}-audit.json"
xcrun xcresulttool get test-results tests --path "$RESULT" --compact > "$TESTS"
uv run --no-project python -B scripts/private_live_mac_results.py "$SUMMARY" "$TESTS" "$AUDIT"
exit "$status"
