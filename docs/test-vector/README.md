# Test vector for docs/update-feed.md

Signed with a throwaway key that no longer exists, for the realm `example` and the repository `example/example`.
Use it to test a launcher's verification, never as a real feed.

- `pubkey.hex`: the public key, 64 bytes X||Y in hex.
- `manifest.json` + `manifest.json.sig`: MUST verify.
- `manifest-tampered.json` + `manifest-tampered.json.sig`: one byte differs (a size), the same signature: MUST NOT verify.

Reference check: `python tools/sign_manifest.py verify docs/test-vector/manifest.json <pubkey> --realm example --repo example/example`.
