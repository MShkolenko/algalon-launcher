#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/algalon-login-check.XXXXXX")
trap 'rm -rf "$CHECK_BUILD"' EXIT
swiftc Sources/ForeverLauncher/SavedLogin.swift \
  Sources/ForeverLauncher/LoginLayout.swift \
  Tests/saved-login/main.swift \
  -o "$CHECK_BUILD/saved-login"
codesign --force --sign - "$CHECK_BUILD/saved-login"
"$CHECK_BUILD/saved-login"
