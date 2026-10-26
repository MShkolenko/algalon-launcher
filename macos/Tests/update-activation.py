#!/usr/bin/env python3
"""Real signed bundle/process fixtures, with no game and no production signing key."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time


def bundle(path, binary, version, behavior="ready", identifier="org.example.update.fixture"):
    (path / "Contents/MacOS").mkdir(parents=True)
    shutil.copy2(binary, path / "Contents/MacOS/Fixture")
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture",
        "CFBundleVersion": "1", "CFBundleShortVersionString": version,
        "CFBundlePackageType": "APPL", "FixtureBehavior": behavior,
    }))
    subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", identifier, str(path)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="forever-update-activation-") as temporary:
        root = Path(temporary).resolve()
        for case in ["success", "crash", "hang", "foreign-identity", "wrong-version", "modified",
                     "retained-old", "lock-held", "no-accept"]:
            folder = root / case
            folder.mkdir()
            app = folder / "Fixture.app"
            staged = folder / "new/Fixture.app"
            (folder / "fixture.log").touch()
            bundle(app, binary, "1.0.3")
            bundle(staged, binary, "1.0.5" if case == "wrong-version" else "1.0.4",
                   behavior=case if case in ["crash", "hang"] else "ready",
                   identifier="org.other.fixture" if case == "foreign-identity"
                   else "org.example.update.fixture")
            if case == "modified":
                with (staged / "Contents/Info.plist").open("ab") as output:
                    output.write(b"tampered")
            if case == "no-accept":
                shutil.move(app, folder / "Fixture.app.old")
                shutil.move(staged, app)
            if case == "retained-old":
                shutil.copytree(app, folder / "Fixture.app.old")
            if case == "hang":
                # A stale/foreign token is not the child launched by this attempt.
                (folder / ("Fixture.app.started-" + "0" * 32)).write_text("0" * 32)
            if case == "lock-held":
                import fcntl
                with (folder / "fixture.lock").open("w") as held:
                    fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    result = subprocess.run([str(app / "Contents/MacOS/Fixture"), "success",
                                             str(folder)], timeout=5)
                    assert result.returncode == 27
                    assert app.exists() and staged.exists()
                    assert not (folder / "Fixture.app.old").exists()
                print("PASS: an existing native instance lock prevents replacement", flush=True)
                continue
            mode = case if case in ["success", "crash", "hang", "retained-old", "no-accept"] else "reject"
            started = time.monotonic()
            # The old executable runs inside the very signed bundle that the installer renames.
            subprocess.run([str(app / "Contents/MacOS/Fixture"), mode, str(folder)],
                           check=True, timeout=40)
            if case == "hang":
                assert 29 <= time.monotonic() - started <= 35
                print("PASS: actual 30-second startup timeout rolls back despite stale ready", flush=True)
            if case == "retained-old":
                assert (folder / "Fixture.app.old/Contents/Info.plist").read_bytes() == (
                    app / "Contents/Info.plist").read_bytes()
                print("PASS: retained old bundle survives a later normal start", flush=True)
            if case in ["success", "no-accept"]:
                marker = folder / ("activated" if case == "success" else "refused")
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                assert marker.exists(), case + " child did not complete its handshake"
                assert (folder / "Fixture.app.old").exists() == (case == "no-accept")
                print("PASS:", "accepted handover cleans old only after parent exit" if case == "success"
                      else "ready without acceptance preserves old after parent exit", flush=True)


if __name__ == "__main__":
    main()
