"""Tests for tools/sign_manifest.py: python tools/test_sign_manifest.py (makes a throwaway key, never the real one)."""
import base64, json, subprocess, sys, tempfile
from pathlib import Path

TOOL = Path(__file__).with_name("sign_manifest.py")
REPO, REALM = "MShkolenko/algalon-launcher", "algalon"
fails = 0


def run(*args):
    return subprocess.run([sys.executable, str(TOOL), *map(str, args)], capture_output=True, text=True)


def check(name, ok):
    global fails
    print(("PASS " if ok else "FAIL ") + name)
    fails += not ok


def manifest(**over):
    m = {"schema": 1, "realm": REALM, "published": "2026-10-26T12:00:00Z", "platforms": {"windows-x64": {
        "version": "1.0.0", "url": f"https://github.com/{REPO}/releases/download/v1.0.0/algalon-launcher.exe",
        "sha256": "e5ba3dbdead5aadf635092e7c38c291cae9f746427eca9cf376d7fbb52751c23", "size": 431104}}}
    for k, v in over.items():
        if k in m:
            m[k] = v
        else:
            m["platforms"]["windows-x64"][k] = v
    return json.dumps(m, indent=2) + "\n"


with tempfile.TemporaryDirectory() as d:
    d = Path(d)
    key = d / "k.pem"
    r = run("new-key", key)
    check("new key created", r.returncode == 0 and key.exists())
    check("new key refuses to overwrite", run("new-key", key).returncode == 1)
    pub = run("pubkey", key).stdout.strip()
    check("pubkey is 128 hex", len(pub) == 128)
    other = d / "o.pem"
    run("new-key", other)
    other_pub = run("pubkey", other).stdout.strip()

    m = d / "manifest.json"
    m.write_text(manifest(), encoding="utf-8", newline="\n")
    r = run("sign", m, key, "--realm", REALM, "--repo", REPO)
    check("sign ok", r.returncode == 0 and (d / "manifest.json.sig").exists())
    sig = (d / "manifest.json.sig").read_text().strip()
    check("signature is 64 bytes", len(base64.b64decode(sig)) == 64)
    check("verify ok", run("verify", m, pub, "--realm", REALM, "--repo", REPO).returncode == 0)
    check("verify with another key fails", run("verify", m, other_pub, "--realm", REALM, "--repo", REPO).returncode == 1)
    check("verify for another realm fails", run("verify", m, pub, "--realm", "other", "--repo", REPO).returncode == 1)
    check("verify for another repo fails", run("verify", m, pub, "--realm", REALM, "--repo", "x/y").returncode == 1)

    good = m.read_bytes()
    m.write_bytes(good.replace(b"431104", b"431105"))
    check("one changed byte fails", run("verify", m, pub, "--realm", REALM, "--repo", REPO).returncode == 1)
    m.write_bytes(good.replace(b"\n", b"\r\n"))
    check("changed line endings fail", run("verify", m, pub, "--realm", REALM, "--repo", REPO).returncode == 1)
    m.write_bytes(good)
    (d / "manifest.json.sig").write_text(sig[:-4] + "\n")
    check("truncated signature fails", run("verify", m, pub, "--realm", REALM, "--repo", REPO).returncode == 1)
    (d / "manifest.json.sig").write_text("!!" + sig + "\n")
    check("non-base64 signature fails", run("verify", m, pub, "--realm", REALM, "--repo", REPO).returncode == 1)

    (d / "manifest.json.sig").unlink()
    bad = {
        "schema 2": manifest(schema=2),
        "schema true": manifest(schema=True),
        "wrong realm": manifest(realm="other"),
        "version with leading zero": manifest(version="1.01.0"),
        "version with newline": manifest(version="1.0.0\n"),
        "version too big": manifest(version="70000.0.0"),
        "non-ASCII digit": manifest(version="1.0.١"),
        "url of another repo": manifest(url="https://github.com/x/y/releases/download/v1/a.exe"),
        "url outside releases": manifest(url=f"https://github.com/{REPO}/raw/main/a.exe"),
        "uppercase sha256": manifest(sha256="E5BA3DBDEAD5AADF635092E7C38C291CAE9F746427ECA9CF376D7FBB52751C23"),
        "size true": manifest(size=True),
        "size too big": manifest(size=60 * 1024 * 1024),
        "bad published": manifest(published="yesterday"),
    }
    for name, text in bad.items():
        m.write_text(text, encoding="utf-8", newline="\n")
        r = run("sign", m, key, "--realm", REALM, "--repo", REPO)
        check(f"refuses {name}", r.returncode == 1 and not (d / "manifest.json.sig").exists())
    # each case below differs from a valid manifest in exactly one thing
    m.write_text(manifest().replace('"schema": 1,', '"schema": 1,\n  "schema": 1,', 1), encoding="utf-8", newline="\n")
    check("refuses duplicate keys", run("sign", m, key, "--realm", REALM, "--repo", REPO).returncode == 1)
    for seg in ("..", "."):
        m.write_text(manifest(url=f"https://github.com/{REPO}/releases/download/{seg}/a.exe"), encoding="utf-8", newline="\n")
        check(f"refuses url segment {seg!r}", run("sign", m, key, "--realm", REALM, "--repo", REPO).returncode == 1)
    m.write_text(manifest(), encoding="utf-8", newline="\n")
    check("valid manifest still signs", run("sign", m, key, "--realm", REALM, "--repo", REPO).returncode == 0)
    before = (d / "manifest.json.sig").read_bytes()
    check("sign without --realm refused", run("sign", m, key, "--repo", REPO).returncode == 1)
    check("sign without --repo refused", run("sign", m, key, "--realm", REALM).returncode == 1)
    check("invalid arguments change nothing", (d / "manifest.json.sig").read_bytes() == before)
    # a failed run removes a signature left from an earlier run
    m.write_text(manifest(), encoding="utf-8", newline="\n")
    run("sign", m, key, "--realm", REALM, "--repo", REPO)
    had = (d / "manifest.json.sig").exists()
    m.write_text(manifest(schema=2), encoding="utf-8", newline="\n")
    r = run("sign", m, key, "--realm", REALM, "--repo", REPO)
    check("failed sign removes the old .sig", had and r.returncode == 1 and not (d / "manifest.json.sig").exists())
    m.write_text(manifest(), encoding="utf-8", newline="\n")
    run("sign", m, key, "--realm", REALM, "--repo", REPO)
    r = run("sign", m, d / "missing.pem", "--realm", REALM, "--repo", REPO)
    check("unreadable key removes the old .sig", r.returncode == 1 and not (d / "manifest.json.sig").exists())
    check("no temporary file left", not (d / "manifest.json.sig.tmp").exists())

print("ALL PASSED" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
