#!/usr/bin/env python3
"""Generate Mac build inputs from the canonical public realm profile."""
import hashlib
import json
from pathlib import Path
import re
import ssl
import subprocess
import sys


def generate(profile):
    root = Path(__file__).resolve().parents[1]
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", profile):
        raise ValueError("invalid profile name")
    header = root.parent / "windows" / "profiles" / profile / "profile.h"
    output = subprocess.check_output(
        ["xcrun", "clang", "-E", "-dM", "-x", "c", "-include", str(header), "-"],
        input="", text=True
    )
    definitions = dict(re.findall(r"^#define (REALM_\w+) (.*)$", output, re.MULTILINE))

    def string(name):
        value = definitions[name]
        pattern = r'(?:L)?("(?:[^"\\]|\\.)*")'
        if re.sub(pattern, "", value).strip():
            raise ValueError("profile value must be a literal string: " + name)
        return "".join(json.loads(v) for v in re.findall(pattern, value))

    identifier = string("REALM_ID")
    portal = string("REALM_PORTAL")
    if identifier != profile or not re.fullmatch(r"[a-z][a-z0-9-]{0,62}", portal):
        raise ValueError("invalid profile id or portal")
    platform = json.loads((root / "profiles" / profile / "profile.json").read_text())
    if not re.fullmatch(r"[A-Za-z0-9.-]+", platform["bundleIdentifier"]):
        raise ValueError("invalid bundle identifier")
    region_key = platform["regionPublicKey"]
    if not re.fullmatch(r"[0-9A-Fa-f]{64}", region_key):
        raise ValueError("invalid public region key")
    pem = string("REALM_CA_PEM")
    der = ssl.PEM_cert_to_DER_cert(pem) if pem else b""
    host = portal + ".actual.battle.net"
    name = string("REALM_NAME")
    long_name = string("REALM_LONG_NAME")
    for value in [name, long_name]:
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9 _-]{0,63}", value):
            raise ValueError("unsafe realm display name")
    server = string("REALM_SERVER")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,252}", server):
        raise ValueError("invalid realm server hostname")
    config = string("REALM_CONFIG")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+\.wtf", config):
        raise ValueError("invalid private config filename")
    values = {
        "id": identifier, "name": name, "longName": long_name,
        "server": server, "portalHost": portal,
        "portalLine": portal + ":1120", "configName": config, "hostName": host,
        "privateProduct": "_forever_" + identifier + "_", "newKeyHex": region_key,
        "caSha1": hashlib.sha1(der).hexdigest().upper() if der else "",
        "caPem": pem, "updateRepository": string("REALM_UPDATE_REPO"),
        "updatePublicKey": string("REALM_UPDATE_PUBKEY"),
    }
    public_key = values["updatePublicKey"]
    if public_key and not re.fullmatch(r"[0-9A-Fa-f]{128}", public_key):
        raise ValueError("invalid update public key")
    generated = root / "Generated"
    generated.mkdir(exist_ok=True)
    swift = "// Generated from the selected canonical public realm profile.\nextension C {\n"
    for key, value in values.items():
        swift += "  static let " + key + " = " + json.dumps(value, ensure_ascii=False) + "\n"
    (generated / "RealmProfile.swift").write_text(swift + "}\n")
    digest = hashlib.sha256(der).digest() if der else bytes(32)
    native = {
        "REALM_HOST": host, "REALM_CA_LABEL": long_name + " CA",
        "REALM_PRIVATE_SUFFIX": "/" + values["privateProduct"]
        + "/World of Warcraft.app/Contents/MacOS/World of Warcraft",
    }
    c = "// Generated from the selected canonical public realm profile.\n#pragma once\n"
    for key, value in native.items():
        c += "#define " + key + " " + json.dumps(value) + "\n"
    c += "#define REALM_CA_SHA256_BYTES {" + ",".join(hex(v) for v in digest) + "}\n"
    (generated / "RealmProfile.h").write_text(c)
    (generated / "bundle.json").write_text(json.dumps({
        "name": name + " Launcher", "bundleIdentifier": platform["bundleIdentifier"],
    }) + "\n")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: profile.py <profile>")
    generate(sys.argv[1])
