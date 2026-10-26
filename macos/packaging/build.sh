#!/bin/bash
# Native universal build. Signing identities remain outside the repository.
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${1:-algalon}"
python3 packaging/profile.py "$PROFILE"
if [ -L dist ]; then echo "Refusing a symlink at the output directory" >&2; exit 1; fi
mkdir -p dist
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ForeverLauncher"
test -f "$BIN"
APP="dist/$(python3 -c 'import json; print(json.load(open("Generated/bundle.json"))["name"] + ".app")')"
# Only this build's owned bundle is replaced; the installed app and game are never touched.
if [ -L "$APP" ]; then echo "Refusing a symlink at the output bundle" >&2; exit 1; fi
if [ -e "$APP" ]; then
  test -d "$APP/Contents" || { echo "Unexpected bundle output" >&2; exit 1; }
  rm -rf -- "$APP"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/ForeverLauncher"
# Release DWARF contains local source paths; strip it before signing the distribution copy.
xcrun strip -S "$APP/Contents/MacOS/ForeverLauncher"
python3 - "$APP" <<'PYTHON'
import json
from pathlib import Path
import plistlib
import sys
profile = json.loads(Path("Generated/bundle.json").read_text())
info = plistlib.loads(Path("packaging/Info.plist").read_bytes())
info.update(CFBundleName=profile["name"], CFBundleDisplayName=profile["name"],
            CFBundleIdentifier=profile["bundleIdentifier"])
Path(sys.argv[1], "Contents/Info.plist").write_bytes(plistlib.dumps(info, sort_keys=True))
PYTHON
IDENTITY="${FOREVER_SIGN_IDENTITY:--}"
xcrun clang -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
  -I Generated -Wno-deprecated-declarations \
  Sources/RealmDNS/RealmDNS.c Sources/RealmDNS/RealmCA.c Sources/RealmDNS/RealmProxy.c \
  -framework Security -framework CoreFoundation -framework CFNetwork \
  -o "$APP/Contents/Frameworks/libRealmDNS.dylib"
python3 - "$APP" <<'PYTHON'
from pathlib import Path
import sys
app = Path(sys.argv[1])
home = str(Path.home()).encode()
for part in ["Contents/MacOS/ForeverLauncher", "Contents/Frameworks/libRealmDNS.dylib"]:
    if home in (app / part).read_bytes():
        raise SystemExit("Refusing to package a binary containing the builder's home path")
PYTHON
codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/libRealmDNS.dylib"
codesign --force --options runtime --entitlements packaging/Launcher.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
lipo -info "$APP/Contents/MacOS/ForeverLauncher"
ZIP="dist/${PROFILE}-launcher-macos.zip"
# Schema 1 requires one app root; AppleDouble resource metadata would add __MACOSX entries.
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
python3 - "$ZIP" "$APP" <<'PYTHON'
from pathlib import Path
import sys
import zipfile
prefix = Path(sys.argv[2]).name + "/"
with zipfile.ZipFile(sys.argv[1]) as archive:
    if not all(name.startswith(prefix) and ".." not in name.split("/")
               for name in archive.namelist()):
        raise SystemExit("Refusing an archive with entries outside its single application root")
PYTHON
echo "Built: $APP (profile: $PROFILE)"
shasum -a 256 "$ZIP"
stat -f 'ZIP bytes: %z' "$ZIP"
