# Forever launcher

Starts the World of Warcraft: Forever (Classic 1.60) client against a private realm, without modifying the client
files and without touching the official game setup. Open source (MIT). The official release binaries are built for the
**Algalon Forever** realm (https://algaloncore.com), but the code names no realm: everything realm-specific lives in a
build profile, so anyone can build it for their own server.

The realm side is the TrinityCore fork for WoW Forever by advocaite:
https://github.com/advocaite/TrinityCore/tree/forever (branch `forever`).

| Path | What |
|---|---|
| `windows/` | Windows launcher: one C++ file (`forever-launcher.cpp`), Win32 API, statically linked, no installer. |
| `windows/profiles/<name>/` | A realm profile: `profile.h` (server, portal, CA certificate, names), `launcher.rc` (icon). |
| `windows/profiles/algalon/` | The Algalon Forever realm: the profile of the official releases. |
| `windows/profiles/example/` | A neutral template to copy for your own realm. |
| `macos/` | macOS launcher: coming. |

## What the launcher does on your computer

It asks for administrator rights once, and only when something is missing, to:

1. add one line to the `hosts` file that points `<portal>.actual.battle.net` (for Algalon: `algalon.actual.battle.net`)
   at the realm server. Other lines are kept byte for byte, a backup `hosts.bak-<id>-<time>` is written first;
2. add the realm's CA certificate to the computer's trusted roots. The certificate carries a critical name constraint:
   it can vouch for `<portal>.actual.battle.net` and nothing else, so it cannot be used to impersonate any other site.

Then, with no special rights:

3. it keeps its own copy of the client next to the official one (`_forever_<id>_`), so the realm never shares the
   official client's cache; Blizzard files are copied, never modified;
4. it starts that copy with its own settings file (`WTF\<config>.wtf`); the official `Config.wtf` is never touched,
   so the game started from Battle.net still goes to the official servers;
5. while the client runs, it replaces one region key in the client's runtime key store (in memory, never on disk)
   with the realm server's public key, so the login to the realm can succeed. It also watches the client's connection
   log and closes the client if it tries to log in at any other host, before the password is sent (this guard is
   built but not yet exercised in a live session).

Settings and the log are in `%LOCALAPPDATA%\<realm long name>\` (`launcher.ini`, `launcher.log`).

## Build

Visual Studio 2022 or newer with the "Desktop development with C++" workload.

```
windows\build.cmd algalon     the official Algalon Forever launcher (algalon-launcher.exe)
windows\build.cmd example     the template (example-launcher.exe)
windows\test.cmd              tests of the hosts file logic (sample files only, the real hosts is never touched)
```

## Verify a release

The build is deterministic (`/Brepro`): the same source and profile give a byte-identical exe. To check that a
released `algalon-launcher.exe` is exactly this code, check out the release tag, run `windows\build.cmd algalon` and
compare the SHA256 of your exe with the one published in the release.

## Your own realm

Copy `windows/profiles/example` to `windows/profiles/<yours>`, set your server, portal and names in `profile.h`, put in
your own CA certificate (public part only, with a critical nameConstraints permitting only
`DNS:<portal>.actual.battle.net`) and run `build.cmd <yours>`. Never put a private key in a profile.

## Releases and updates

Planned: GitHub Releases in this repository plus a manifest (version, URL, SHA256 per platform) signed with a key held
only by the realm owner; launchers verify it with an embedded public key. No tokens, credentials or private keys go
into this repository or into a launcher.

## Disclaimer

This is an unofficial fan project for private, non-commercial servers. It is not affiliated with, endorsed or
sponsored by Blizzard Entertainment. World of Warcraft, Battle.net and Blizzard Entertainment are trademarks or
registered trademarks of Blizzard Entertainment, Inc. No Blizzard game files are distributed here. Using a private
server may be against the terms of use of the official service; you are responsible for how you use this software.

## License

MIT, see [LICENSE](LICENSE).
