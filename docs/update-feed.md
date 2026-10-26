# Update feed (schema 1)

How a launcher learns that a newer launcher exists and proves the download is genuine. One feed per realm profile;
the realm owner alone holds the signing key. The words MUST and MUST NOT are requirements for every launcher.

## What it protects, and what it does not

Protected, as long as the private key is not stolen: nobody else (a mirror, a network attacker, someone who took over
the GitHub account) can make a launcher install a file the owner did not sign, install a version not greater than its
own, or install a manifest signed for another realm.

Accepted, by decision of the project: the feed gives **no freshness guarantee**. Whoever controls the GitHub account or
the network can hide new releases, serve an old signed manifest forever, or offer an old signed version to launchers
that are older still. Updates are best effort: a launcher that cannot update simply starts the game as before.
Signed expiry dates would detect a frozen feed but not force an update through; for a small private project they
are not worth the extra failure modes.

## Where

A launcher reads two files from the **latest full release** of the repository its profile names:

```
https://github.com/<owner>/<repo>/releases/latest/download/manifest.json
https://github.com/<owner>/<repo>/releases/latest/download/manifest.json.sig
```

For the `algalon` profile: `MShkolenko/algalon-launcher`. Plain HTTPS, no token, no GitHub API. GitHub answers these
URLs with a redirect to its asset storage; following HTTPS redirects is allowed, because the signature and the hash,
not the host, decide what is trusted.

Pre-releases are how a build is tested before it ships: GitHub does not serve them under `latest`. This is a GitHub
behaviour, not a cryptographic barrier: anything signed with the production key is installable by production
launchers if it is ever served, so sign a manifest only for a build meant to ship.

## Publication order (owner)

1. Upload the platform files to the release. 2. Write `manifest.json` with their SHA256 and size, sign it
(`tools/sign_manifest.py sign`), check it (`tools/sign_manifest.py verify`). 3. Upload `manifest.json` and
`manifest.json.sig` last, then mark the release as full. A launcher that meets a mismatched pair (fetched during a
publication) treats it as "no update" and tries again at its next start.

## manifest.json

UTF-8 JSON. A launcher verifies the bytes it downloaded and MUST NOT normalize, re-serialize, strip a BOM or change
line endings before verifying.

```json
{
  "schema": 1,
  "realm": "algalon",
  "published": "2026-10-26T12:00:00Z",
  "platforms": {
    "windows-x64": {
      "version": "1.0.0",
      "url": "https://github.com/MShkolenko/algalon-launcher/releases/download/v1.0.0/algalon-launcher.exe",
      "sha256": "e5ba3dbdead5aadf635092e7c38c291cae9f746427eca9cf376d7fbb52751c23",
      "size": 431104
    }
  }
}
```

Rules, checked only after the signature verifies:

- the root is an object; duplicate keys anywhere make the manifest invalid;
- `schema` is the integer 1; anything else means "no update", never an error dialog;
- `realm` equals the launcher's own profile id;
- `published` is optional and informational only (`YYYY-MM-DDTHH:MM:SSZ`); nothing depends on it;
- `platforms` is a non-empty object whose members are named `windows-x64` or `macos-universal`; a platform that is
  not listed has no update;
- `version` is a string `MAJOR.MINOR.PATCH`, ASCII digits, no leading zeros, each part 0..65535, compared as three
  integers; a launcher installs only a version **strictly greater** than its own built-in version;
- `url` is exactly `https://github.com/<owner>/<repo>/releases/download/<tag>/<file>` of the profile's repository,
  where `<tag>` and `<file>` contain only `A-Z a-z 0-9 . _ -` and neither is `.` or `..`;
- `sha256` is 64 lowercase hex digits and `size` an integer 1..52428800 (50 MiB), both of the file at `url`.

Limits: `manifest.json` at most 64 KiB, `manifest.json.sig` at most 1 KiB; a download that grows past `size` is
aborted. Timeouts: 5 s to connect, 10 s for the manifest and signature, 120 s for the download.

## manifest.json.sig

ECDSA over NIST P-256 with SHA-256, over the exact bytes of `manifest.json`. The file holds the raw 64-byte signature
`r || s` (32 bytes each, big-endian, left-padded with zeros) in strict base64 on one line; surrounding whitespace is
ignored, anything that does not decode to exactly 64 bytes is invalid.

## The public key

Each profile embeds the realm's public key as 64 bytes `X || Y` (big-endian coordinates of the uncompressed point,
without the 0x04 prefix), hex. Windows: `REALM_UPDATE_PUBKEY` in `windows/profiles/<id>/profile.h`; macOS: the same
bytes in its profile. A profile without a key has no self-update. The key is never taken from the network.

Native verification, normative:

- **Windows (CNG):** `BCryptImportKeyPair` with `BCRYPT_ECCPUBLIC_BLOB`: a `BCRYPT_ECCKEY_BLOB` header
  (`dwMagic = BCRYPT_ECDSA_PUBLIC_P256_MAGIC`, `cbKey = 32`, native ULONGs) followed by the 64 bytes `X || Y`
  unchanged (do not reverse them). Then `BCryptVerifySignature(key, NULL, sha256(manifest) [32 bytes], 32,
  sig [64 bytes r||s], 64, 0)`: CNG takes the hash, not the message, and the raw signature, not DER.
- **macOS (CryptoKit):** `P256.Signing.PublicKey(x963Representation: [0x04] + X || Y)`,
  `P256.Signing.ECDSASignature(rawRepresentation: sig)`, then `isValidSignature(sig, for: manifestBytes)` with the
  manifest bytes (CryptoKit hashes them). Passing an already computed SHA-256 as plain `Data` would hash it twice.

`tools/sign_manifest.py verify` is the reference check; a launcher implementation is tested against a manifest and
signature it produced before it ships.

## Installing an update

The launcher never replaces itself until the new file is fully verified, keeps the previous one until the new one has
proved it starts, and tries to put the previous one back by itself when the new one does not.

"Started" below means: the new launcher has read its settings and reached the point where it would start the game,
and has confirmed it through a handshake bound to this one attempt. Before starting the new launcher the old process
makes a random 128-bit attempt token (32 hex digits) and passes it as `--update-token <token>`:

- Windows: the old process first creates a new, non-signalled, manual-reset event `Local\<id>LauncherUpdated-<token>`
  (creation fails if it already exists, then the attempt is abandoned); the new launcher opens that exact name and
  signals it. Only the old process's own handle is waited on.
- macOS: the old process deletes every `<app>.started-*` file, then the new launcher creates
  `<app>.started-<token>` containing the token; the old process accepts only that file name with that content.

The old process waits at most 30 seconds. A confirmation with any other token, or one that existed before the new
launcher was started, never counts.

**Windows** (`<exe>` is the running launcher's own path):

1. download to `<exe>.new` in the same folder; check `size` and `sha256`; on any mismatch delete it and stop;
2. rename `<exe>` to `<exe>.old` (Windows allows renaming a running exe), then rename `<exe>.new` to `<exe>`;
   if the second rename fails, rename `<exe>.old` back and stop;
3. start `<exe>` with `--updated-from <pid> --update-token <token>` and wait for the handshake;
4. handshake received: the old process exits; the new launcher deletes `<exe>.old` after the handshake;
5. no handshake within 30 s (it crashed, was blocked, or would not start): the old process ends the new one if it is
   still running, deletes an earlier `<exe>.bad` if there is one, renames `<exe>` to `<exe>.bad`, renames `<exe>.old`
   back to `<exe>`, logs why, and continues as the old launcher. `<exe>.bad` is kept for diagnosis and that version
   is not offered again in this session.

At start, a launcher started without `--updated-from` that finds `<exe>.old` next to itself leaves it alone (it may be
the only good copy after an interrupted update) and logs it; it is deleted only by a launcher that completed step 4.

**macOS** (`<app>` is the running bundle):

1. download the zip to a temporary folder on the same volume as `<app>`; check `size` and `sha256` of the zip;
2. before extracting, list the archive entries and refuse it unless every entry is a relative path without `..`
   components, all entries sit under exactly one top-level `<name>.app/`, no entry's path passes through an entry
   that is a symlink, and every symlink target is relative and resolves inside that `.app`;
3. extract with `ditto -x -k` into the temporary folder; then check again that every symlink in the extracted tree
   resolves inside the bundle;
4. check the extracted bundle's code signature (`codesign --verify --deep --strict`) and that its signing identity and
   bundle identifier equal those of the running `<app>`; on any failure delete the folder and stop;
5. rename `<app>` to `<app>.old`, move the new bundle to `<app>`; if the move fails, rename `<app>.old` back and stop;
6. relaunch `<app>` with the token and wait for the handshake; on success the old process exits and the new launcher
   deletes `<app>.old`; without it within 30 s the old process terminates the new one, deletes an earlier `<app>.bad`,
   moves `<app>` to `<app>.bad`, renames `<app>.old` back and continues as the old launcher.

**If putting the old launcher back fails** (the new process cannot be ended, a file is locked, a rename is refused):
the old process stops trying, changes nothing further, writes the exact state to its log and shows the player one
message naming the file to rename by hand (`<exe>.old` to `<exe>`, or `<app>.old` to `<app>`). The old launcher is
never deleted in this case.

**What is not covered, accepted:** a power loss or a kill of the old process between the two renames (step 2 on
Windows, step 5 on macOS) or while it waits for the handshake leaves `<exe>.old` / `<app>.old` as a complete working
launcher next to a missing or unproven new one; the player renames it back by hand (the launcher's log says which
file to rename). No automatic recovery is attempted from a later start for that case. Manual recovery is likewise
the accepted answer to the failures listed in the paragraph above.

## Key loss and compromise

The private key is kept offline by the realm owner with one backup, never in this repository, a launcher, CI or a bot.

- **Lost:** no further self-updates for launchers that embed its public key. Players download one new launcher (with
  a new key) by hand from the realm's site.
- **Stolen:** anyone holding it can ship an "update" to every launcher with that key. The owner makes a new key,
  publishes a new launcher with it, and tells players through the realm's own channels to replace their launcher by
  hand. Launchers with the old key cannot be told to distrust it; that manual step is the recovery.
