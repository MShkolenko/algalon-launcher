#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/algalon-login-safety.XXXXXX")
trap 'rm -rf "$CHECK_BUILD"' EXIT
xcrun swiftc -target "$(uname -m)-apple-macos12.0" \
  Sources/ForeverLauncher/MaskedLoginField.swift Sources/ForeverLauncher/LoginLayout.swift \
  Tests/login-safety/main.swift \
  -o "$CHECK_BUILD/probe"
"$CHECK_BUILD/probe"
