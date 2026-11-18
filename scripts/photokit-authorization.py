"""Generate Photos fixtures and verify the exact executed authorization XCTest."""

import json
import struct
import sys
import zlib
from pathlib import Path


def chunk(kind: bytes, content: bytes) -> bytes:
    payload = kind + content
    return struct.pack(">I", len(content)) + payload + struct.pack(">I", zlib.crc32(payload))


def write_png(path: Path, width: int, height: int, rgb: bytes) -> None:
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    white = b"\xff\xff\xff"
    pixels = b"".join(
        b"\x00" + b"".join(rgb if (x // 12 + y // 12) % 2 else white for x in range(width))
        for y in range(height)
    )
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(pixels))
        + chunk(b"IEND", b"")
    )


def create_fixtures(root: Path) -> None:
    write_png(root / "red-landscape.png", 120, 72, b"\xcb\x12\x25")
    write_png(root / "blue-portrait.png", 72, 120, b"\x18\x37\xc3")


def test_cases(nodes: list[dict]) -> list[dict]:
    cases = []
    for node in nodes:
        if node["nodeType"] == "Test Case":
            cases.append(node)
        else:
            cases.extend(test_cases(node.get("children", [])))
    return cases


def verify_result(root: Path, method: str, udid: str) -> None:
    summary = json.loads((root / "summary.log").read_text())
    tests = json.loads((root / "tests.log").read_text())
    devices = tests.get("devices", [])
    if len(devices) != 1 or devices[0].get("deviceId") != udid:
        raise SystemExit("XCTest did not run on the new run-owned simulator.")
    if (
        summary.get("result") != "Passed"
        or summary.get("totalTestCount") != 1
        or summary.get("passedTests") != 1
        or any(summary.get(key) != 0 for key in ("failedTests", "skippedTests", "expectedFailures"))
    ):
        raise SystemExit("Expected exactly one passed authorization XCTest without skips.")
    cases = test_cases(tests.get("testNodes", []))
    identifier = f"PhotoAuthorizationTests/{method}"
    bundle = f"test://com.apple.xcode/Suwop/SuwopPhotoAuthorizationTests/{identifier}"
    if (
        len(cases) != 1
        or cases[0].get("nodeIdentifier") != identifier + "()"
        or cases[0].get("nodeIdentifierURL") != bundle
        or cases[0].get("result") != "Passed"
    ):
        raise SystemExit(f"Missing execution evidence for {identifier}.")
    print(identifier)


if __name__ == "__main__":
    _, action, root, *arguments = sys.argv
    if action == "fixtures":
        create_fixtures(Path(root))
    elif action == "verify":
        verify_result(Path(root), *arguments)
    else:
        raise SystemExit("Choose fixtures or verify.")
