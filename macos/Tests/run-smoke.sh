#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 packaging/profile.py algalon
CHECK_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/algalon-check.XXXXXX")
trap 'rm -rf "$CHECK_BUILD"' EXIT
xcrun clang -I Generated -dynamiclib -Wall -Wextra -Werror -Wno-deprecated-declarations \
  Sources/RealmDNS/RealmDNS.c Sources/RealmDNS/RealmCA.c Sources/RealmDNS/RealmProxy.c \
  -framework Security -framework CoreFoundation -framework CFNetwork -o "$CHECK_BUILD/libRealmDNS.dylib"
codesign --force --sign - "$CHECK_BUILD/libRealmDNS.dylib"
xcrun clang Tests/client-fixture.c -o "$CHECK_BUILD/client-fixture"
swiftc Generated/RealmProfile.swift Sources/ForeverLauncher/Constants.swift \
  Sources/ForeverLauncher/SystemSetup.swift \
  Sources/ForeverLauncher/ConnectionGuard.swift \
  Sources/ForeverLauncher/ClientCopy.swift Tests/main.swift \
  -o "$CHECK_BUILD/smoke"
"$CHECK_BUILD/smoke" "$CHECK_BUILD/libRealmDNS.dylib" "$CHECK_BUILD/client-fixture"
xcrun clang -I Sources/MachKeyStore/include Tests/keystore.c Sources/MachKeyStore/keystore.c \
  -o "$CHECK_BUILD/keystore"
"$CHECK_BUILD/keystore"
xcrun clang Tests/dns.c -o "$CHECK_BUILD/dns"
DYLD_INSERT_LIBRARIES="$CHECK_BUILD/libRealmDNS.dylib" "$CHECK_BUILD/dns" 0
PRIVATE_FIXTURE="$CHECK_BUILD/_forever_algalon_/World of Warcraft.app/Contents/MacOS/World of Warcraft"
mkdir -p "$(dirname "$PRIVATE_FIXTURE")"
cp "$CHECK_BUILD/dns" "$PRIVATE_FIXTURE"
FOREVER_PRIVATE_EXECUTABLE="$PRIVATE_FIXTURE" DYLD_INSERT_LIBRARIES="$CHECK_BUILD/libRealmDNS.dylib" "$PRIVATE_FIXTURE" 1
ln -s "$PRIVATE_FIXTURE" "$CHECK_BUILD/selected-client"
FOREVER_PRIVATE_EXECUTABLE="$CHECK_BUILD/selected-client" DYLD_INSERT_LIBRARIES="$CHECK_BUILD/libRealmDNS.dylib" "$PRIVATE_FIXTURE" 1

OTHER_FIXTURE="$CHECK_BUILD/other/_forever_algalon_/World of Warcraft.app/Contents/MacOS/World of Warcraft"
mkdir -p "$(dirname "$OTHER_FIXTURE")"
cp "$CHECK_BUILD/dns" "$OTHER_FIXTURE"
FOREVER_PRIVATE_EXECUTABLE="$PRIVATE_FIXTURE" DYLD_INSERT_LIBRARIES="$CHECK_BUILD/libRealmDNS.dylib" "$OTHER_FIXTURE" 0
DYLD_INSERT_LIBRARIES="$CHECK_BUILD/libRealmDNS.dylib" "$PRIVATE_FIXTURE" 0

xcrun clang -I Generated -Wall -Wextra -Werror -Wno-deprecated-declarations Tests/realm-trust.c \
  -framework Security -framework CoreFoundation -o "$CHECK_BUILD/realm-trust"
"$CHECK_BUILD/realm-trust"
xcrun clang -Wall -Wextra -Werror Tests/proxy.c -framework CFNetwork -framework CoreFoundation \
  -o "$CHECK_BUILD/proxy"
FOREVER_SERVER_IPV4=127.0.0.1 DYLD_INSERT_LIBRARIES="$CHECK_BUILD/libRealmDNS.dylib" "$CHECK_BUILD/proxy" 0
cp "$CHECK_BUILD/proxy" "$PRIVATE_FIXTURE"
FOREVER_SERVER_IPV4=127.0.0.1 FOREVER_PRIVATE_EXECUTABLE="$PRIVATE_FIXTURE" DYLD_INSERT_LIBRARIES="$CHECK_BUILD/libRealmDNS.dylib" "$PRIVATE_FIXTURE" 1
FOREVER_SERVER_IPV4=invalid DYLD_INSERT_LIBRARIES="$CHECK_BUILD/libRealmDNS.dylib" "$PRIVATE_FIXTURE" 0

xcrun swift Tests/VerifyUpdateVector.swift ../docs/test-vector
python3 packaging/profile.py example
cat > "$CHECK_BUILD/main.swift" <<'SWIFT'
import Foundation
precondition(C.server == "localhost" && C.hostName == "example.actual.battle.net")
precondition(C.privateProduct == "_forever_example_" && C.configName == "Example.wtf")
precondition(C.caPem.isEmpty && C.updateRepository.isEmpty && C.updatePublicKey.isEmpty)
print("PASS: example profile is isolated and has no configured trust or update feed")
SWIFT
swiftc Sources/ForeverLauncher/Constants.swift Generated/RealmProfile.swift \
  "$CHECK_BUILD/main.swift" -o "$CHECK_BUILD/example-profile"
"$CHECK_BUILD/example-profile"
if python3 packaging/profile.py ../algalon > "$CHECK_BUILD/invalid-profile.log" 2>&1; then
  echo "FAIL: profile traversal accepted" >&2; exit 1
fi
echo "PASS: profile path traversal is rejected"
python3 packaging/profile.py algalon
