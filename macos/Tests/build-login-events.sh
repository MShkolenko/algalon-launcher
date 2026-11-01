#!/bin/bash
# Build an autonomous fictional fixture; its existing input and capture grants are required.
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/algalon-input-events.XXXXXX")
APP="$CHECK_BUILD/Algalon Input Safety Tests.app"
TARGET_APP="$APP/Contents/Resources/Algalon Input Target.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$TARGET_APP/Contents/MacOS"
xcrun clang -dynamiclib -fobjc-arc -mmacosx-version-min=12.0 \
  -I Generated -I Sources/RealmDNS Sources/RealmDNS/RealmInput.m Tests/input-channel/scope.c \
  -framework AppKit -framework Carbon -o "$APP/Contents/Frameworks/libInputFixture.dylib"
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos12.0" \
  Sources/ForeverLauncher/LoginInputGuard.swift Sources/ForeverLauncher/LoginInput.swift \
  Sources/ForeverLauncher/LoginInputChannel.swift \
  Tests/login-events/main.swift \
  -o "$APP/Contents/MacOS/InputSafety"
cp "$APP/Contents/MacOS/InputSafety" "$TARGET_APP/Contents/MacOS/InputSafety"
python3 - "$APP" "$CHECK_BUILD/result.json" <<'PYTHON'
from pathlib import Path
import plistlib
import hashlib
import sys
info = {
    "CFBundleIdentifier": "org.example.algalon.input-safety",
    "CFBundleName": "Algalon Input Safety Tests",
    "CFBundleExecutable": "InputSafety",
    "CFBundlePackageType": "APPL",
    "LSMinimumSystemVersion": "12.0",
    "AlgalonTestReport": sys.argv[2],
    "AlgalonTestLibrary": str(Path(sys.argv[1]) / "Contents/Frameworks/libInputFixture.dylib"),
    "AlgalonTestTargetExecutable": str(Path(sys.argv[1]) / "Contents/Resources/Algalon Input Target.app/Contents/MacOS/InputSafety"),
}
sources = [Path("Sources/RealmDNS/RealmInput.m"), Path("Tests/input-channel/scope.c"),
           Path("Sources/ForeverLauncher/LoginInputGuard.swift"),
           Path("Sources/ForeverLauncher/LoginInput.swift"),
           Path("Sources/ForeverLauncher/LoginInputChannel.swift"),
           Path("Tests/login-events/main.swift")]
digest = hashlib.sha256()
for source in sources:
    digest.update(str(source).encode() + b"\0" + source.read_bytes() + b"\0")
info["AlgalonTestSourceSHA256"] = digest.hexdigest()
(Path(sys.argv[1]) / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
info.update(CFBundleIdentifier="org.example.algalon.input-target", CFBundleName="Algalon Input Target")
(Path(sys.argv[1]) / "Contents/Resources/Algalon Input Target.app/Contents/Info.plist").write_bytes(plistlib.dumps(info))
PYTHON
codesign --force --sign "${FOREVER_SIGN_IDENTITY:--}" "$APP/Contents/Frameworks/libInputFixture.dylib"
codesign --force --sign "${FOREVER_SIGN_IDENTITY:--}" "$TARGET_APP"
codesign --force --sign "${FOREVER_SIGN_IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
printf 'Fixture: %s\nReport: %s\n' "$APP" "$CHECK_BUILD/result.json"
printf 'Open the fixture with its existing grants; fictional checks run automatically.\n'
