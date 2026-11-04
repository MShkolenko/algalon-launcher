#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/algalon-region-monitor.XXXXXX")
trap 'rm -rf "$CHECK_BUILD"' EXIT
python3 packaging/profile.py algalon
printf 'module MachKeyStore { header "%s/Sources/MachKeyStore/include/keystore.h" export * }\n' \
  "$PWD" > "$CHECK_BUILD/module.modulemap"
xcrun clang -I Sources/MachKeyStore/include -c Sources/MachKeyStore/keystore.c \
  -o "$CHECK_BUILD/keystore.o"
xcrun swiftc -parse-as-library -I "$CHECK_BUILD" Generated/RealmProfile.swift \
  Sources/ForeverLauncher/{Constants,SystemSetup,ClientCopy,ConnectionGuard,RegionKeyMonitor}.swift \
  Sources/ForeverLauncher/{LoginInputChannel,LoginInputGuard}.swift \
  Tests/region-monitor/main.swift "$CHECK_BUILD/keystore.o" -o "$CHECK_BUILD/monitor"
cat > "$CHECK_BUILD/entitlements.plist" <<'PLIST'
<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.cs.debugger</key><true/><key>com.apple.security.get-task-allow</key><true/></dict></plist>
PLIST
codesign --force --sign - --entitlements "$CHECK_BUILD/entitlements.plist" "$CHECK_BUILD/monitor"
"$CHECK_BUILD/monitor"
