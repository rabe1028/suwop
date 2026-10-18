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
uv run --no-project python - "$SUMMARY" <<'PYTHON'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    summary = json.load(source)
passed = summary.get("passedTests")
valid = (
    summary.get("result") == "Passed"
    and type(passed) is int
    and passed >= 8
    and type(summary.get("totalTestCount")) is int
    and summary.get("totalTestCount") == passed
    and all(
        type(summary.get(key)) is int and summary[key] == 0
        for key in ("failedTests", "skippedTests", "expectedFailures")
    )
)
if not valid:
    raise SystemExit("Live macOS acceptance requires at least 8 actual passes and zero failures/skips")
print(f"Live macOS xcresult: {passed} passed, zero failures/skips")
PYTHON
exit "$status"
