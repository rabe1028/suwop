"""Check the exact provider cutover test and its synthetic UI evidence."""

import json
import sys
from pathlib import Path

METHOD = "ProviderConfigUITests/testImmichAccountCutoverRejectsHeldRaster"
URL = f"test://com.apple.xcode/Suwop/SuwopProviderConfigTests/{METHOD}"
ATTACHMENTS = {
    "A-thumbnail",
    "A-preview",
    "A-selected",
    "A-raster-held",
    "B-before-A-release",
    "B-thumbnail-before-A-release",
    "B-after-A-release",
    "B-thumbnail-after-A-release",
    "B-preview-after-A-release",
    "Disconnected",
}


def read(path):
    return json.loads(path.read_text())


def test_cases(nodes):
    for node in nodes:
        if node["nodeType"] == "Test Case":
            yield node
        else:
            yield from test_cases(node.get("children", []))


def verify(directory, device):
    summary = read(directory / "summary.log")
    tests = read(directory / "tests.log")
    cases = list(test_cases(tests["testNodes"]))
    if (
        summary["result"] != "Passed"
        or summary["totalTestCount"] != 1
        or summary["passedTests"] != 1
        or any(summary[key] != 0 for key in ("failedTests", "skippedTests", "expectedFailures"))
        or len(tests["devices"]) != 1
        or tests["devices"][0]["deviceId"] != device
        or len(cases) != 1
        or cases[0]["nodeIdentifierURL"] != URL
        or cases[0]["result"] != "Passed"
    ):
        raise ValueError("Expected one passed provider cutover XCTest on the run-owned Simulator")
    manifest = read(directory / "Attachments" / "manifest.json")
    if len(manifest) != 1 or manifest[0]["testIdentifierURL"] != URL:
        raise ValueError("Unexpected fixture attachment test identity")
    names = [
        item["suggestedHumanReadableName"].split("_", 1)[0]
        for item in manifest[0]["attachments"]
        if item["deviceId"] == device and not item["isAssociatedWithFailure"]
    ]
    if len(names) != len(ATTACHMENTS) or set(names) != ATTACHMENTS:
        raise ValueError("Missing or duplicate provider cutover evidence")
    print(METHOD)


if __name__ == "__main__":
    try:
        location, udid = sys.argv[1:]
        verify(Path(location), udid)
    except (KeyError, OSError, ValueError) as error:
        sys.exit(str(error))
