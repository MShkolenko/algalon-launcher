# Forever launcher for macOS

Native Swift/C launcher for the macOS release client. This is the profile-separated port of the
working Mac baseline, licensed under this repository's MIT license with the operator's explicit
consent. No game files, credentials, session proofs, private signing keys or raw logs are included.

See [remembered server login](../docs/saved-login.md) for the native login form,
Keychain storage, optional macOS14 autofill permissions and current acceptance limits.

## Profiles and build

The canonical realm inputs are `../windows/profiles/<name>/profile.h`: server, portal, private
configuration name, display names, public CA, update repository and public update key. They are
preprocessed by the native compiler and consumed as string literals by `packaging/profile.py`.
`profiles/<name>/profile.json` adds the Mac bundle identifier and public runtime region key.
The generator derives the private product path and both certificate fingerprints; there is no
second manually maintained copy of the CA or update key in the Mac code.

Requirements: macOS with Xcode command-line tools, Swift 5.7 or later, and Python 3. The declared
deployment target is macOS 12. The verified build environment is Xcode 27 / Apple Swift 6.4 on
macOS 27.0.1. Intel hardware and older supported OS versions have not been exercised.

From the repository root:

```sh
bash macos/packaging/build.sh algalon
bash macos/packaging/build.sh example
bash macos/Tests/run-smoke.sh
bash macos/Tests/run-updates.sh
```

Each build regenerates its inputs before compiling both arm64 and x86_64 slices. The resulting
`Algalon Launcher.app` or `Example Launcher.app` is created inside `macos/dist/`. The example profile
has no CA and no update feed; configure the public trust material before using it with a server.
The commands are repeatable build steps; byte-identical Mac builds have not been established.
Do not build different profiles concurrently in the same checkout.

The distribution copy has DWARF stripped before signing and is checked for the builder's home
path. Local `.build` diagnostics remain available; raw build logs and debug data are not shipped.

The default is hardened ad-hoc signing. A distributor may set `FOREVER_SIGN_IDENTITY` to a locally
installed Developer ID Application identity. The script signs the library before the outer bundle
and verifies the complete result with `codesign --verify --deep --strict`. Signing identities and
private keys are never build inputs stored in Git. Developer ID distribution, notarization and
Gatekeeper installation on a clean Mac remain pending the owner's distribution decision.

To package a verified bundle without losing its symlinks or signature:

```sh
cd macos/dist
ditto -c -k --norsrc --keepParent "Algalon Launcher.app" algalon-launcher-macos.zip
shasum -a 256 algalon-launcher-macos.zip
stat -f %z algalon-launcher-macos.zip
```

## Client isolation

The launcher discovers `_forever_/World of Warcraft.app`, including clients on mounted volumes.
`FOREVER_WOW` may select the parent `World of Warcraft` folder explicitly. The old beta product
is never selected as a release fallback. The Algalon profile preserves the existing
`_forever_algalon_` copy, `Algalon.wtf`, private cache and player settings. A refresh after a
Battle.net update copies the release application and preserves private state. Shared `Data`
remains shared; normal CASC metadata writes are not claimed to be immutable.

The private application is re-signed inside out, preserving each nested executable's original
entitlements and adding debugger access only where needed. Its complete signature is verified
before launch. The official application is only read; its signature, files, settings and cache
are not rewritten. Symlink checks prevent private executable, log and state paths from resolving
into the official product. Backups and staged-copy recovery remain in the copy transaction.

The private configuration retains unrelated preferences and exactly one portal, text locale and
audio locale. Valid private locales take priority, followed by official locales, the active `wowf`
build tags, and `enUS`. Both locales are seeded before first launch to avoid the region chooser
overwriting the portal. Credentials are entered in the native launcher form or
manually in the game; optional storage uses the login Keychain, never Config.wtf.

## Network and trust boundaries

The launcher retains native certificate verification and scoped SSL user trust for the exact realm
hostname. It does not disable verification, modify SIP, install a root helper, edit hosts or change
global proxy settings. Existing system trust is preserved. If the exact user trust setting is
missing, macOS requires the player's separate confirmation before adding it.

The bundled resolver/trust/proxy library is admitted only in the canonical private executable
selected for that launch. Its canonical path must also have the profile's private-product suffix.
Process-local DNS redirects only the expected realm alias. Other Battle.net login aliases are
refused. The `connect` interposition admits login traffic only to the selected IPv4 on port 1120;
other ordinary ports retain native behavior. These are scoped `getaddrinfo`/`connect` checks, not
a claim to mediate every socket API. Only HTTPS to the exact realm on port 8082 receives the
existing process-local proxy exception.

A fresh private `Connection.log` is monitored, with prior logs retained in `Logs/Previous`.
Unexpected or malformed logon endpoints stop the exact owned child after checking its canonical
executable path again. The log monitor is reactive and may see buffered output late; synchronous
DNS/transport checks provide the earlier guard for the intercepted APIs.

The runtime scanner accepts only a complete validated 12-entry Blizzard key table. It replaces
region group 8 in private process memory and confirms the write. No disk key patch is made. A
failed login before the realm stage does not prove key-table incompatibility.

## Verification and current scope

The original 1.0.3(4) arm64 baseline passed native release 1.60.1.70532 account/SRP and realm
authentication, one validated region-key installation, existing character selection, visual world
loading and clean exit on 2026-10-26. All 144 official application files retained their previous
hashes, sizes, modes and modification times after that session. The current profile-separated
source requires its own build/fixture checks; that session is not a claim of a new live run.

`Tests/run-smoke.sh` exercises the real copy, signing, configuration and log-guard functions using
temporary native application fixtures. It also checks Mach scanning, DNS/process/transport scope,
CA settings and exact HTTPS proxy scope without launching the real game or changing OS trust.
The example profile and path-traversal refusal have independent checks.

## Authenticated launcher updates

Version 1.1.1 implements schema 1 in `../docs/update-feed.md`, using the public repository and
embedded P-256 key from the selected canonical profile. An empty key/repository disables updates.
Each normal start reads the public latest-full-release manifest and signature through URLSession,
with system DNS/proxy/TLS validation, no cookies or credential store, bounded bytes and deadlines.
Response headers must arrive within five seconds, a stricter bound than connection alone. A missing
feed, transient GitHub publication mismatch, invalid signature, or other pre-install failure simply
continues with the current launcher. No GitHub login is required or embedded.

The downloaded ZIP is size/SHA256 checked before extraction. A bounded native preflight checks local
and central headers, CRC/deflate data, unique paths, single app root and symlink resolution. It accepts
the builder's ASCII stored/deflate ZIP subset: at most 4096 entries and 250 MiB expanded. ZIP64,
non-ASCII names, encrypted files and path-override extras fail closed. Use `--norsrc` above: AppleDouble
sidecars under a second `__MACOSX` root violate the feed contract. System zlib is the only archive
library; no downloaded dependency or shell interpreter processes archive paths.

Extraction uses native ditto into an exclusively created sibling staging directory. The extracted
tree is checked again. Security.framework performs the equivalent of deep strict codesign validation
for every architecture; bundle ID and signing certificate (or ad-hoc signing category) must match the
running app. The signed version must equal the manifest version. Changing from ad-hoc to Developer ID
signing requires a manual bootstrap; certificate rotation likewise requires a matching identity.

A per-profile native file lock prevents concurrent launches. The installer retains `<app>.old`,
starts the new executable with a fresh attempt token, and waits up to 30 seconds. The child opens its
log and takes the lock before signalling ready. It requires a separate parent acceptance and actual
parent exit before deleting `.old`; a late ready alone cannot destroy recovery. Copy refresh and
player prompts occur after activation. Startup failure restores the prior app and saves the failed
ZIP identity in `<app>.bad.sha256`; that exact archive is skipped on subsequent starts. An existing
`.old`, or `.bad` without its hash, suspends updates pending manual recovery. In a failed recovery,
close launchers, retain the failed bundle for diagnosis, and rename `<app>.old` back to `<app>`.
No game, player settings or system trust is part of this app-replacement transaction.

`Tests/run-updates.sh [optional-built-zip]` calls the production manifest/archive/install/download
functions. It checks the owner-provided good/tampered/double-hash vectors, signed invalid manifests,
hostile archives, actual signed native child handover, crash/30-second rollback, existing lock/old
preservation and ready-without-acceptance. It also reads the public owner-signed v1.1.0 manifest via
HTTPS redirects and rejects a local untrusted TLS leaf before HTTP; it never changes OS trust. Native
fixture keys are test-only and unrelated to the owner's offline production key. No real game runs.

Production manifest signing and full-release promotion belong only to the owner. A real owner-signed
Mac feed activation of the distributed app and a fresh game session remain release acceptance gates;
fixture success and reading a signed Windows-only manifest are not substitutes for those steps.

Launcher logs are under `~/Library/Logs/<realm long name>/`; game logs and settings are under the
private product. Treat them as private. Share only sanitized timestamps, stage codes and booleans,
never account values, passwords, cookies, tokens, runtime keys, personal paths or machine identity.
