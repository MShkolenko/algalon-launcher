# Public Mac 1.1.1 to 1.2.2 feed activation

Tested 2026-11-04 on macOS 27.2 arm64. This is a public signed-feed activation result;
it is not a 70790 game-authentication or world-entry result.

## Confirmed

The owner merged PR #4 as `ba14e23` and published Mac 1.2.2 in the full signed feed.
A fresh public 1.1.1(6) ad-hoc app was downloaded from `macos-updater-v1.1.1` without
modification or re-signing. Its 289218-byte ZIP SHA256 is
50f700bdc6cfbf2e5e618a20fff086156f5d6f8b4fe979769a3f1b2aff5bc01b.
It ran in a separate owned directory, preserving the installed Development1.2.2 app.

The exact 689-byte raw public latest manifest/signature pair passed the production
CryptoKit signature and platform parser; a tampered manifest was refused. The
selected Mac 1.2.2 ZIP is 505292 bytes, SHA256
5d3f421b1c6f8da77a17002e32053f66818afa2a681db459db5958e3eb812025.

At 23:13:31MSK the old launcher logged acceptance/handover and the new launcher
confirmed activation. The installed canary reports 1.2.2(10); all its bundle-file
bytes match the separately downloaded public 1.2.2 archive and strict all-architecture
signature validation passes. The old process is gone. At 23:13:33 the new launcher
swapped in its private 70790 copy; private-only re-signing completed 23:13:35.
The login form appeared and was cancelled. No game was launched, no credentials
were submitted, and no Keychain/TCC permissions or trust settings were changed.
The previous installed Development launcher remains byte-exact, as do all 78 official
app root/file/link/directory baseline records.

This closes the specific live public 1.1.1-to-1.2.2 activation gap. It does not test
rollback of this production release or downgrade: the updater does not downgrade.
The published 1.2.2 archive and its release were retained unchanged. Owner signing
keys and production manifest contents were not modified.

## Current client and review limits

Battle.net shows official wowf 1.60.1.70790 pre-installed with Play available.
The owner now accepts only 70790. The prepared Mac private copy is 70790, but the
previous account/realm/key/character/world acceptance belongs to 70707 on November 1.
No new 70790 Mac authentication, region-key or world result is inferred from it.

Owner review `6562552114` remains open: window-level input permits do not atomically
bind each key to the probed game widget, and a write error can be suppressed when
the process exits in the same sweep. Those product paths are unchanged in this
documentation follow-up. The former needs post-fill mask verification and an
actual same-window responder-change control; this is mitigation, not proof of
atomic widget ownership. The latter needs operation-level exit/error classification
and a targeted failure control. Do not mark either fixed from this activation test.
The existing scanner resource cost and ad-hoc prompt/clean-Mac/Intel/older-OS limits
also remain. The canonical site is now https://algaloncore.com on 443; 24713 redirects.

## Official cache readiness

The separate local official-only WDB collector is loaded every 60 seconds, last
exit 0, with no resident process between checks. Its installed runtime is unchanged;
a manual check completes in about 0.16 seconds with no duplicate snapshot. Eight
native process/isolation/archive/dedup/receipt/retention controls pass.

Four actual T7 snapshots pass archive, allowlist and file-hash checks. The current
enUS 70790 snapshot matches all six official source files byte-for-byte, but each
file is only a 32-byte header. No populated NPC/quest dataset is claimed. The helper
will snapshot changed stable WDB after official-game exit, on T7 beside the game.
It reads no private cache/WTF/logs and does not upload. Retention requires exact
recipient receipt/hash plus seven days, keeps two newest snapshots per locale,
and prunes at most one eligible snapshot per tick. No receipt or deletion occurred.
