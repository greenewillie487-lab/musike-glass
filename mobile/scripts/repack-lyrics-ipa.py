#!/usr/bin/env python3
"""Package the lyrics-only web update into the verified upstream unsigned 1.5.1 IPA.

Usage: python3 mobile/scripts/repack-lyrics-ipa.py ORIGINAL.ipa OUTPUT.ipa
Run pnpm --filter @musike/web build:native first. Native code/plugins must match
the original release; native changes require the normal macOS/Xcode build.
"""

import hashlib
from pathlib import Path
import sys
import zipfile

EXPECTED = "488e991ec264a0b335cf18ee409c856e97ce1e5213184259ea480daa5211a638"
PUBLIC = "Payload/Musike.app/public/"


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    source, target = map(Path, sys.argv[1:])
    if hashlib.sha256(source.read_bytes()).hexdigest() != EXPECTED:
        raise SystemExit("Input is not the verified upstream Musike v1.5.1 IPA.")
    built = Path(__file__).resolve().parents[2] / "web" / "dist-native"
    if not (built / "index.html").is_file():
        raise SystemExit("Build the native web bundle first.")
    if not target.parent.is_dir():
        raise SystemExit("The output directory must already exist.")
    if target.exists():
        raise SystemExit("Output already exists; choose a new filename.")
    bridge_files = {PUBLIC + "cordova.js", PUBLIC + "cordova_plugins.js"}
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(target, "x", compression=zipfile.ZIP_DEFLATED) as output:
        for info in original.infolist():
            if not info.filename.startswith(PUBLIC) or info.filename in bridge_files:
                output.writestr(info, original.read(info))
        for path in sorted(built.rglob("*")):
            if path.is_file():
                output.write(path, PUBLIC + path.relative_to(built).as_posix())
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(target) as output:
        if output.testzip() is not None:
            raise SystemExit("Archive integrity check failed.")
        for info in original.infolist():
            if not info.filename.startswith(PUBLIC):
                assert original.read(info) == output.read(info.filename), info.filename
        for path in built.rglob("*"):
            if path.is_file():
                assert path.read_bytes() == output.read(PUBLIC + path.relative_to(built).as_posix())
    print(f"Verified all native resources unchanged and all new web assets included.\n{target}")
    print(f"SHA-256: {hashlib.sha256(target.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
