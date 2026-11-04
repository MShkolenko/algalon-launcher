#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/algalon-input-channel.XXXXXX")
trap 'rm -rf "$CHECK_BUILD"' EXIT
xcrun clang -dynamiclib -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=12.0 \
  -I Generated -I Sources/RealmDNS Sources/RealmDNS/RealmInput.m Tests/input-channel/scope.c \
  -framework AppKit -framework Carbon -o "$CHECK_BUILD/libInputFixture.dylib"
codesign --force --sign - "$CHECK_BUILD/libInputFixture.dylib"
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos12.0" \
  Tests/input-channel/main.swift -o "$CHECK_BUILD/InputChannelHost"
codesign --force --sign - "$CHECK_BUILD/InputChannelHost"
"$CHECK_BUILD/InputChannelHost" "$CHECK_BUILD/libInputFixture.dylib"
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos12.0" \
  Sources/ForeverLauncher/LoginInputChannel.swift Tests/input-channel/parent.swift \
  -o "$CHECK_BUILD/InputChannelParent"
"$CHECK_BUILD/InputChannelParent"
