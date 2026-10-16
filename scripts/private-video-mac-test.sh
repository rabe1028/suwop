#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
xcodegen generate
mkdir -p DerivedData/PrivateVideoMac/TestResults
RESULT="DerivedData/PrivateVideoMac/TestResults/Test-$(date -u +%Y%m%dT%H%M%SZ)-$$.xcresult"
xcodebuild -clonedSourcePackagesDirPath "$ROOT/DerivedData/SourcePackages" -project Suwop.xcodeproj -scheme SuwopPrivateVideoMac \
  -destination 'platform=macOS' -derivedDataPath DerivedData/PrivateVideoMac \
  -resultBundlePath "$RESULT" -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
