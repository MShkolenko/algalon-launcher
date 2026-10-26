"""Sign and verify update manifests (docs/update-feed.md) with the realm owner's ECDSA P-256 key.

    python tools/sign_manifest.py sign <manifest.json> <private-key.pem> --realm <id> --repo <owner/repo>
        once its arguments are valid: removes an old <manifest.json>.sig, checks the manifest, writes the new
        signature to a temporary file, verifies it there and only then renames it to .sig; any failure from that
        point on removes the .sig and the temporary file, as far as the disk allows the removal itself
        (invalid arguments change nothing at all)
    python tools/sign_manifest.py verify <manifest.json> <pubkey-hex> --realm <id> --repo <owner/repo>
        verifies <manifest.json>.sig and the manifest the way a launcher must; exit 0 only when everything holds
    python tools/sign_manifest.py new-key <private-key.pem>     creates a key; never overwrites an existing file
    python tools/sign_manifest.py pubkey <private-key.pem>      prints the 64-byte X||Y hex for the profiles

Needs the `cryptography` package.
"""
import base64, binascii, hashlib, json, re, sys
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature, encode_dss_signature

MAX_MANIFEST = 64 * 1024
MAX_SIG = 1024
MAX_ASSET = 50 * 1024 * 1024
VERSION = re.compile(r"(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,4})", re.ASCII)
PLATFORMS = {"windows-x64", "macos-universal"}


class Bad(Exception):
    pass


def no_duplicates(pairs):
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise Bad("duplicate key in a JSON object")
    return dict(pairs)


def parse_version(v):
    if not isinstance(v, str):
        raise Bad("version must be a string")
    m = VERSION.fullmatch(v)
    if not m or any(int(x) > 65535 for x in m.groups()):
        raise Bad(f"version {v!r} must be MAJOR.MINOR.PATCH, each 0..65535, no leading zeros")
    return tuple(int(x) for x in m.groups())


def check_manifest(raw, realm, repo):
    if len(raw) > MAX_MANIFEST:
        raise Bad("manifest larger than 64 KiB")
    try:
        m = json.loads(raw.decode("utf-8"), object_pairs_hook=no_duplicates)
    except (UnicodeDecodeError, ValueError) as e:
        raise Bad(f"not UTF-8 JSON: {e}")
    if not isinstance(m, dict):
        raise Bad("root must be an object")
    if type(m.get("schema")) is not int or m["schema"] != 1:
        raise Bad("schema must be the integer 1")
    if m.get("realm") != realm:
        raise Bad(f"realm must be {realm!r}")
    if "published" in m and not (isinstance(m["published"], str) and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", m["published"], re.ASCII)):
        raise Bad("published must be YYYY-MM-DDTHH:MM:SSZ")
    plats = m.get("platforms")
    if not isinstance(plats, dict) or not plats:
        raise Bad("platforms must be a non-empty object")
    prefix = f"https://github.com/{repo}/releases/download/"
    for name, p in plats.items():
        if name not in PLATFORMS:
            raise Bad(f"unknown platform {name!r}")
        if not isinstance(p, dict):
            raise Bad(f"{name}: must be an object")
        parse_version(p.get("version"))
        url = p.get("url")
        tail = url[len(prefix):].split("/") if isinstance(url, str) and url.startswith(prefix) else []
        if len(tail) != 2 or not all(re.fullmatch(r"[A-Za-z0-9._-]+", t, re.ASCII) and t not in (".", "..") for t in tail):
            raise Bad(f"{name}: url must be {prefix}<tag>/<file>")
        if not isinstance(p.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", p["sha256"], re.ASCII):
            raise Bad(f"{name}: sha256 must be 64 lowercase hex digits")
        if type(p.get("size")) is not int or not 0 < p["size"] <= MAX_ASSET:
            raise Bad(f"{name}: size must be an integer 1..{MAX_ASSET}")
    return m


def read_sig(path):
    text = path.read_bytes()
    if len(text) > MAX_SIG:
        raise Bad("signature file too large")
    try:
        sig = base64.b64decode(text.strip(), validate=True)
    except (binascii.Error, ValueError):
        raise Bad("signature is not strict base64")
    if len(sig) != 64:
        raise Bad(f"signature must be 64 bytes r||s, got {len(sig)}")
    return sig


def verify(manifest, pub, realm, repo, sig_path=None):
    raw = manifest.read_bytes()
    sig = read_sig(sig_path or manifest.with_name(manifest.name + ".sig"))
    der = encode_dss_signature(int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:], "big"))
    try:
        pub.verify(der, raw, ec.ECDSA(hashes.SHA256()))  # signature first, then the content checks
    except InvalidSignature:
        raise Bad("signature does not verify")
    check_manifest(raw, realm, repo)
    return raw


def load_private(path):
    key = serialization.load_pem_private_key(Path(path).read_bytes(), password=None)
    if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp256r1":
        raise Bad("not an ECDSA P-256 private key")
    return key


def pub_from_hex(h):
    if not re.fullmatch(r"[0-9A-Fa-f]{128}", h, re.ASCII):
        raise Bad("public key must be 128 hex digits (X||Y)")
    return ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), b"\x04" + bytes.fromhex(h))


def pubkey_hex(key):
    point = key.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return point[1:].hex().upper()


def opts(args):
    out, rest = {}, []
    it = iter(args)
    for a in it:
        if a in ("--realm", "--repo"):
            out[a[2:]] = next(it, "")
        else:
            rest.append(a)
    if not out.get("realm") or not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", out.get("repo", ""), re.ASCII):
        raise Bad("--realm <id> and --repo <owner/repo> are required")
    return rest, out["realm"], out["repo"]


def main(argv):
    cmd, args = (argv[1], argv[2:]) if len(argv) > 1 else ("", [])
    if cmd == "new-key" and len(args) == 1:
        key = ec.generate_private_key(ec.SECP256R1())
        pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
        try:
            with open(args[0], "xb") as f:  # exclusive create: never replaces a key
                f.write(pem)
        except FileExistsError:
            raise Bad(f"{args[0]} exists, not overwritten")
        print(f"wrote {args[0]}; public key {pubkey_hex(key)}")
    elif cmd == "pubkey" and len(args) == 1:
        print(pubkey_hex(load_private(args[0])))
    elif cmd == "sign":
        (manifest, keyfile), realm, repo = opts(args)
        manifest = Path(manifest)
        sig_path = manifest.with_name(manifest.name + ".sig")
        tmp = manifest.with_name(manifest.name + ".sig.tmp")
        # An old signature is removed before anything else, so a failed run never leaves a .sig that may not match;
        # the new one is written to a temporary file, verified there, and only then renamed into place.
        sig_path.unlink(missing_ok=True)
        tmp.unlink(missing_ok=True)
        try:
            key = load_private(keyfile)
            raw = manifest.read_bytes()
            check_manifest(raw, realm, repo)
            r, s = decode_dss_signature(key.sign(raw, ec.ECDSA(hashes.SHA256())))
            tmp.write_text(base64.b64encode(r.to_bytes(32, "big") + s.to_bytes(32, "big")).decode("ascii") + "\n", encoding="ascii")
            if verify(manifest, key.public_key(), realm, repo, tmp) != raw:
                raise Bad("manifest changed while signing")
            tmp.replace(sig_path)
        except BaseException:
            tmp.unlink(missing_ok=True)
            sig_path.unlink(missing_ok=True)
            raise
        print(f"signed {manifest} ({len(raw)} bytes, sha256 {hashlib.sha256(raw).hexdigest()}), verified")
    elif cmd == "verify":
        (manifest, pubhex), realm, repo = opts(args)
        verify(Path(manifest), pub_from_hex(pubhex), realm, repo)
        print("VALID")
    else:
        raise Bad(__doc__)


if __name__ == "__main__":
    try:
        main(sys.argv)
    except (Bad, ValueError, OSError) as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        sys.exit(1)
