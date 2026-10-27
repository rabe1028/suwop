"""Read-only inspection of one explicit built app; never distribution approval."""

import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
from pathlib import Path


def contained(root, path):
    if not path.resolve().is_relative_to(root):
        raise ValueError("A bundle path escapes the app directory")
    return path


def bundle_hash(root):
    digest = hashlib.sha256()
    files = 0
    for path in sorted(root.rglob("*")):
        contained(root, path)
        relative = path.relative_to(root).as_posix().encode()
        if path.is_symlink():
            content = b"symlink:" + str(path.readlink()).encode()
        elif path.is_file():
            item = hashlib.sha256()
            with path.open("rb") as source:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    item.update(block)
            content = item.digest()
        else:
            continue
        digest.update(
            relative + b"\0" + str(path.lstat().st_mode & 0o777).encode() + b"\0" + content + b"\0"
        )
        files += 1
    return digest.hexdigest(), files


def signature(root):
    executable = shutil.which("codesign")
    if executable is None:
        return {"state": "unavailable", "verified": False}
    verification = subprocess.run(  # noqa: S603 - fixed read-only argv, absolute bundle path, no shell
        [executable, "--verify", "--deep", "--strict", str(root)],
        capture_output=True,
        check=False,
    )
    details = subprocess.run(  # noqa: S603 - fixed read-only argv, absolute bundle path, no shell
        [executable, "--display", "--verbose=2", str(root)],
        capture_output=True,
        check=False,
    )
    verified = verification.returncode == 0
    state = "unsigned-or-invalid"
    if details.returncode == 0:
        state = "ad-hoc" if b"Signature=adhoc" in details.stderr else "signed"
    return {"state": state, "verified": verified}


def inspect_bundle(path, resources=(), check_signature=False):
    root = Path(path).resolve()
    result = {
        "schema_version": 1,
        "scope": "explicit built bundle inspection only",
        "bundle": str(root),
        "distribution_ready": False,
        "errors": [],
    }
    try:
        if root.suffix != ".app" or not root.is_dir():
            raise ValueError("Expected an explicit existing .app directory")
        mac = (root / "Contents").is_dir()
        info_path = contained(root, root / ("Contents/Info.plist" if mac else "Info.plist"))
        with info_path.open("rb") as source:
            info = plistlib.load(source)
        if not isinstance(info, dict):
            raise ValueError("Info.plist must contain a dictionary")
        required = (
            "CFBundleIdentifier",
            "CFBundleShortVersionString",
            "CFBundleVersion",
            "CFBundleExecutable",
            "NSPhotoLibraryUsageDescription",
            "NSPhotoLibraryAddUsageDescription",
        )
        for field in required:
            if not isinstance(info.get(field), str) or not info[field].strip():
                result["errors"].append(f"Missing or empty {field}")
        platform = info.get("DTPlatformName") or info.get("CFBundleSupportedPlatforms")
        valid_platform = (isinstance(platform, str) and bool(platform.strip())) or (
            isinstance(platform, list)
            and bool(platform)
            and all(isinstance(item, str) and item.strip() for item in platform)
        )
        if not valid_platform:
            result["errors"].append("Missing platform declaration")
        result["platform"] = platform
        result["identifier"] = info.get("CFBundleIdentifier")
        result["version"] = info.get("CFBundleShortVersionString")
        result["build"] = info.get("CFBundleVersion")
        name = info.get("CFBundleExecutable", "")
        if not isinstance(name, str) or not name or Path(name).name != name or name in (".", ".."):
            raise ValueError("CFBundleExecutable must be a single file name")
        executable = contained(root, root / ("Contents/MacOS" if mac else "") / name)
        if not executable.is_file() or executable.stat().st_mode & 0o111 == 0:
            result["errors"].append("Missing executable file or executable mode")
        for resource in resources:
            relative = Path(resource)
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("Required resources must be bundle-relative paths")
            if not contained(root, root / relative).exists():
                result["errors"].append(f"Missing required resource: {relative.as_posix()}")
        result["bundle_sha256"], result["hashed_entries"] = bundle_hash(root)
        if check_signature:
            result["signature"] = signature(root)
            if not result["signature"]["verified"]:
                result["errors"].append("Requested signature verification did not pass")
    except (OSError, ValueError, RuntimeError, plistlib.InvalidFileException) as error:
        result["errors"].append(
            str(error) if isinstance(error, ValueError) else "Bundle inspection failed"
        )
    result["checks_passed"] = not result["errors"]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--resource", action="append", default=[])
    parser.add_argument("--codesign", action="store_true")
    args = parser.parse_args()
    result = inspect_bundle(args.app, args.resource, args.codesign)
    print(json.dumps(result, sort_keys=True, indent=2))
    return 0 if result["checks_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
