# Algalon Forever launcher

Home of the launcher for the Algalon WoW Forever realm: one repository for every platform, its releases and its update feed.

| Path | What |
|---|---|
| `windows/` | Windows launcher (C++, single exe). Build: `windows/build.cmd`. Moved here from the owner's private ops repo, commit a1a95fd. |
| `macos/` | macOS launcher (Swift). To be brought in from `MShkolenko/algalon-mac` (release `macos-v1.0.3`). |

## Releases and updates (to be designed)

Today the Windows exe is published by hand at `algaloncore.com/files/algalon-launcher.exe`; there is no versioned
release, manifest or self-update yet, on any platform. Planned: GitHub Releases here plus a manifest (version, URL,
SHA256 per platform) signed with a key held only by the owner; launchers verify it with an embedded public key. No
tokens, credentials or private keys ever go into this repository or into a launcher.
