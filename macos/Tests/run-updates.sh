#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 packaging/profile.py algalon
CHECK_BUILD=$(mktemp -d "${TMPDIR:-/tmp}/forever-update-check.XXXXXX")
trap 'rm -rf "$CHECK_BUILD"' EXIT
TARGET="$(uname -m)-apple-macos12.0"
COMMON=(Sources/ForeverLauncher/Constants.swift Sources/ForeverLauncher/UpdateManifest.swift)
xcrun swiftc -target "$TARGET" -parse-as-library "${COMMON[@]}" \
  Tests/UpdateManifestTests.swift -o "$CHECK_BUILD/manifest"
"$CHECK_BUILD/manifest" ../docs/test-vector
xcrun clang -mmacosx-version-min=12.0 -Wall -Wextra -Werror -I Sources/ArchiveCheck/include \
  -c Sources/ArchiveCheck/ArchiveCheck.c -o "$CHECK_BUILD/archive.o"
ARCHIVE=(Sources/ForeverLauncher/UpdateArchive.swift "$CHECK_BUILD/archive.o" -lz)
xcrun swiftc -target "$TARGET" -parse-as-library -I Sources/ArchiveCheck/include \
  "${COMMON[@]}" "${ARCHIVE[@]}" Tests/UpdateArchiveTests.swift -o "$CHECK_BUILD/archive"
python3 Tests/update-archives.py "$CHECK_BUILD/archive" ${1:+"$1"}
xcrun swiftc -target "$TARGET" -parse-as-library -I Sources/ArchiveCheck/include \
  "${COMMON[@]}" "${ARCHIVE[@]}" Sources/ForeverLauncher/UpdateInstall.swift \
  Tests/UpdateActivationFixture.swift -o "$CHECK_BUILD/activation"
python3 Tests/update-activation.py "$CHECK_BUILD/activation"
xcrun swiftc -target "$TARGET" -parse-as-library -I Sources/ArchiveCheck/include \
  "${COMMON[@]}" "${ARCHIVE[@]}" Sources/ForeverLauncher/UpdateInstall.swift \
  Sources/ForeverLauncher/UpdateDownload.swift Sources/ForeverLauncher/SystemSetup.swift \
  Generated/RealmProfile.swift Tests/UpdateDownloadTests.swift -o "$CHECK_BUILD/download"
python3 Tests/update-download.py "$CHECK_BUILD/download"
