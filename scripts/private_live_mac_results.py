"""Audit exact macOS Live test identities from observed xcresult summary and test-tree JSON."""

import hashlib
import json
import sys
from pathlib import Path

BUNDLE = "SuwopPrivateLiveMacTests"
SUITE = "PrivateLiveSurfaceTests"
METHODS = frozenset(
    {
        "testActualFullPlaybackHasCurrentCallbacksAndChangingRenderedSurfaceFrames",
        "testSingleReplayDuringActualPlaybackRestartsFullMotionAfterActualEnd",
        "testOwnerRevocationAtActualEndCancelsQueuedReplayBeforeNativeStart",
        "testSameAccessOldSurfaceDetachPreservesNewSurfaceAndSharedStateClaim",
        "testUnregisterHiddenWindowAndExactReplacementImmediatelyShield",
        "testFreshAttachmentCannotAssignAfterOwnerUnregisterOrRequestRetirement",
        "testReusedNativeSurfaceBindsNewAccessAndDetachStopsCurrentObject",
        "testPublishedSurfaceSurvivesOldAcquisitionDeadlineWithRealSessionCheck",
        "testActualPlatformWindowUnavailableEventsClearNativeObject",
        "testActualSwiftUIContentDisappearanceStopsAndClearsHostedSurface",
    }
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def container(node, kind, name, url=None):
    require(isinstance(node, dict), "Invalid result node")
    require(
        node.get("nodeType") == kind
        and node.get("name") == name
        and node.get("result") == "Passed",
        "Wrong, incomplete or failed result container",
    )
    if url is not None:
        require(node.get("nodeIdentifierURL") == url, "Wrong container identity")
    children = node.get("children")
    require(isinstance(children, list) and children, "Incomplete result children")
    return children


def audit(summary, tests):
    require(isinstance(summary, dict) and isinstance(tests, dict), "Invalid result document")
    nodes = tests.get("testNodes")
    require(isinstance(nodes, list) and len(nodes) == 1, "Expected one complete test plan")
    bundles = container(nodes[0], "Test Plan", "SuwopPrivateLiveMac")
    require(len(bundles) == 1, "Expected exactly the Live bundle")
    base = f"test://com.apple.xcode/Suwop/{BUNDLE}"
    suites = container(bundles[0], "Unit test bundle", BUNDLE, base)
    require(len(suites) == 1, "Expected exactly the Live surface suite")
    cases = container(suites[0], "Test Suite", SUITE, f"{base}/{SUITE}")
    identifiers = set()
    for case in cases:
        require(isinstance(case, dict), "Invalid case")
        name = case.get("name")
        require(isinstance(name, str) and name.endswith("()"), "Invalid case method")
        method = name.removesuffix("()")
        require(
            case.get("nodeType") == "Test Case"
            and case.get("result") == "Passed"
            and method in METHODS
            and case.get("nodeIdentifier") == f"{SUITE}/{method}()"
            and case.get("nodeIdentifierURL") == f"{base}/{SUITE}/{method}",
            "Unaccepted status or wrong/unknown case identity",
        )
        require(method not in identifiers, "Duplicate execution or retry")
        identifiers.add(method)
        for child in case.get("children", []):
            require(
                isinstance(child, dict)
                and child.get("nodeType") == "Runtime Warning"
                and not child.get("children"),
                "Failure, repetition or unknown case child",
            )
    require(identifiers == METHODS, "Missing required Live surface case")
    devices = tests.get("devices")
    configs = summary.get("devicesAndConfigurations")
    require(
        isinstance(devices, list)
        and isinstance(configs, list)
        and len(devices) == len(configs) == 1,
        "Expected one device/configuration",
    )
    device = devices[0]
    require(
        isinstance(device, dict)
        and isinstance(configs[0], dict)
        and device.get("architecture") == "arm64"
        and device.get("platform") == "macOS"
        and configs[0].get("device") == device,
        "Wrong device/configuration",
    )
    require(summary.get("result") == "Passed", "Summary did not pass")
    start, finish = summary.get("startTime"), summary.get("finishTime")
    require(
        type(start) in (int, float) and type(finish) in (int, float) and 0 < start < finish,
        "Incomplete result time",
    )
    require(summary.get("testFailures") == [], "Missing or nonempty failures list")
    for stats in (summary, configs[0]):
        for key, value in (
            ("passedTests", len(METHODS)),
            ("failedTests", 0),
            ("skippedTests", 0),
            ("expectedFailures", 0),
        ):
            require(
                type(stats.get(key)) is int and stats[key] == value, "Summary/inventory mismatch"
            )
    require(
        type(summary.get("totalTestCount")) is int and summary["totalTestCount"] == len(METHODS),
        "Total/inventory mismatch",
    )
    return sorted(f"{BUNDLE}/{SUITE}/{method}" for method in identifiers)


def main():
    summary_path, tests_path, output = map(Path, sys.argv[1:])
    receipt = {
        "schema_version": 1,
        "summary_sha256": hashlib.sha256(summary_path.read_bytes()).hexdigest(),
        "tests_sha256": hashlib.sha256(tests_path.read_bytes()).hexdigest(),
    }
    try:
        receipt["identifiers"] = audit(
            json.loads(summary_path.read_text()), json.loads(tests_path.read_text())
        )
    except ValueError as error:
        receipt.update(accepted=False, reason=str(error))
        output.write_text(json.dumps(receipt, indent=2) + "\n")
        raise SystemExit(str(error)) from error
    receipt["accepted"] = True
    output.write_text(json.dumps(receipt, indent=2) + "\n")
    print("Live macOS xcresult: all ten exact cases passed once, zero failures/skips")


if __name__ == "__main__":
    main()
