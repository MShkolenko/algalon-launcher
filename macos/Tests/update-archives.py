#!/usr/bin/env python3
"""Independent ZIP producer exercises the pre-extraction contract, never the game."""
import io
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile


def archive(entries, compression=zipfile.ZIP_DEFLATED):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=compression) as bundle:
        for path, content, mode in entries:
            info = zipfile.ZipInfo(path)
            info.create_system = 3
            info.external_attr = mode << 16
            info.compress_type = compression
            bundle.writestr(info, content)
    return output.getvalue()


def main():
    binary = sys.argv[1]
    file = stat.S_IFREG | 0o644
    link = stat.S_IFLNK | 0o777
    normal = [("Test.app/Contents/Info.plist", b"test plist", file)]
    accepted = {
        "stored.zip": archive(normal, zipfile.ZIP_STORED),
        "deflated.zip": archive(normal),
        "internal-links.zip": archive(normal + [
            ("Test.app/Contents/alias", b"Info.plist", link),
            ("Test.app/another", b"Contents/alias", link),
        ]),
    }
    refused = {}
    for name, entries in {
        "traversal": [("Test.app/../outside", b"x", file)],
        "absolute": [("/Test.app/a", b"x", file)],
        "backslash": [("Test.app/a\\b", b"x", file)],
        "colon": [("Test.app/a:b", b"x", file)],
        "outside-root": normal + [("sidecar", b"x", file)],
        "second-app": normal + [("Other.app/a", b"x", file)],
        "case-collision": normal + [("Test.app/contents/info.plist", b"x", file)],
        "symlink-parent": normal + [("Test.app/alias", b"Contents", link),
                                    ("Test.app/alias/a", b"x", file)],
        "file-parent": normal + [("Test.app/Contents/Info.plist/a", b"x", file)],
        "absolute-link": normal + [("Test.app/alias", b"/tmp", link)],
        "escape-link": normal + [("Test.app/Contents/alias", b"../../outside", link)],
        "link-cycle": normal + [("Test.app/a", b"b", link), ("Test.app/b", b"a", link)],
        # The link in the middle must be expanded before the following '..'.
        "indirect-escape": normal + [("Test.app/Contents/down", b"..", link),
                                     ("Test.app/alias", b"Contents/down/../outside", link)],
        "special-file": normal + [("Test.app/device", b"", stat.S_IFIFO | 0o600)],
    }.items():
        refused[name + ".zip"] = archive(entries)
    raw = archive(normal)
    central = raw.index(b"PK\x01\x02")
    # Each corruption changes an independent ZIP trust boundary while keeping other framing intact.
    for name, offset, value in [
        ("local-name", 30, b"X"),
        ("crc", central + 16, struct.pack("<I", 1)),
        ("encrypted", central + 8, struct.pack("<H", 1)),
        ("inflated-size", central + 24, struct.pack("<I", 262144001)),
        ("payload", 30 + len(normal[0][0]), b"\xff"),
    ]:
        changed = bytearray(raw)
        changed[offset:offset + len(value)] = value
        refused[name + ".zip"] = changed
    refused["truncated.zip"] = raw[:-1]
    refused["prepended.zip"] = b"unlisted bytes" + raw
    inflated = bytearray(raw)
    for offset in [22, central + 24]:
        inflated[offset:offset + 4] = struct.pack("<I", 1)
    refused["actual-inflate-exceeds-declared-size.zip"] = inflated
    with tempfile.TemporaryDirectory(prefix="forever-zip-contract-") as folder:
        base = Path(folder)
        for cases, decision in [(accepted, "accept"), (refused, "refuse")]:
            paths = []
            for name, data in cases.items():
                path = base / name
                path.write_bytes(data)
                paths.append(str(path))
            subprocess.run([binary, decision, *paths], check=True)
        if len(sys.argv) > 2:
            subprocess.run([binary, "accept", sys.argv[2]], check=True)


if __name__ == "__main__":
    main()
