"""Bind CI release slices to one clean source revision before XCFramework assembly."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

TARGETS = (
    "aarch64-apple-darwin",
    "aarch64-apple-ios",
    "aarch64-apple-ios-sim",
)


def revision():
    if subprocess.check_output(["/usr/bin/git", "status", "--porcelain"], text=True).strip():
        raise ValueError("CI slices require a clean source checkout")
    return subprocess.check_output(["/usr/bin/git", "rev-parse", "HEAD"], text=True).strip()


def identity(root, target, commit):
    if target not in TARGETS:
        raise ValueError("Unsupported Apple target")
    library = root / target / "libsuwop_ffi.a"
    if library.is_symlink() or not library.is_file() or library.stat().st_size == 0:
        raise ValueError(f"Missing release library: {target}")
    digest = hashlib.sha256()
    with library.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"target": target, "revision": commit, "sha256": digest.hexdigest()}


def stamp(root, target, commit):
    manifest = identity(root, target, commit)
    (root / target / "manifest.json").write_text(json.dumps(manifest) + "\n")


def verify(root, commit):
    for target in TARGETS:
        expected = identity(root, target, commit)
        actual = json.loads((root / target / "manifest.json").read_text())
        if actual != expected:
            raise ValueError(f"Release slice does not match source revision or digest: {target}")


def main():
    root = Path("Generated/RustSlices")
    commit = revision()
    if len(sys.argv) == 3 and sys.argv[1] == "stamp":
        stamp(root, sys.argv[2], commit)
    elif sys.argv[1:] == ["verify"]:
        verify(root, commit)
    else:
        raise ValueError("Usage: apple_slices.py stamp TARGET | verify")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
