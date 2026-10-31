#!/bin/bash
# Build a foreground-only fictional input fixture; grant its own Accessibility permission manually.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/algalon-input-events.XXXXXX")
APP="$CHECK_BUILD/Algalon Input Safety Tests.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos12.0" \
  Sources/ForeverLauncher/LoginInputGuard.swift Sources/ForeverLauncher/LoginInput.swift \
  Tests/login-events/main.swift \
  -o "$APP/Contents/MacOS/InputSafety"
python3 - "$APP" "$CHECK_BUILD/result.json" <<'PYTHON'
from pathlib import Path
import plistlib
import sys
info = {
    "CFBundleIdentifier": "org.example.algalon.input-safety",
    "CFBundleName": "Algalon Input Safety Tests",
    "CFBundleExecutable": "InputSafety",
    "CFBundlePackageType": "APPL",
    "LSMinimumSystemVersion": "12.0",
    "AlgalonTestReport": sys.argv[2],
}
(Path(sys.argv[1]) / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
PYTHON
codesign --force --sign "${FOREVER_SIGN_IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
printf 'Fixture: %s\nReport: %s\n' "$APP" "$CHECK_BUILD/result.json"
printf 'Open the fixture, grant its own Accessibility permission, click Run fictional checks, then wait.\n'
