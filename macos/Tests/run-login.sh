#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/algalon-login-check.XXXXXX")
trap 'rm -rf "$CHECK_BUILD"' EXIT
python3 packaging/profile.py algalon
swiftc Generated/RealmProfile.swift Sources/ForeverLauncher/Constants.swift \
  Sources/ForeverLauncher/SavedLogin.swift Sources/ForeverLauncher/LoginScript.swift \
  Tests/saved-login/main.swift \
  -o "$CHECK_BUILD/saved-login"
codesign --force --sign - "$CHECK_BUILD/saved-login"
"$CHECK_BUILD/saved-login"
