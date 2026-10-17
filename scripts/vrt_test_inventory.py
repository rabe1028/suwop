"""Strict inventory checks for the observed Xcode 26.4 xcresult JSON schema."""

import re
from urllib.parse import urlparse

BUNDLES = {"SuwopVRT", "SuwopVRTUI"}
CONTAINERS = {"Test Plan", "Unit test bundle", "UI test bundle", "Test Suite"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def registered_inventory(data):
    """Our normalized contract, not a guessed xcodebuild enumeration format."""
    require(data.get("schema_version") == 1, "Unknown registered inventory schema")
    groups = data.get("bundles", {})
    require(set(groups) == BUNDLES, "Registered inventory must include both complete bundles")
    for bundle, identifiers in groups.items():
        require(isinstance(identifiers, list) and identifiers, "Empty registered bundle")
        require(len(identifiers) == len(set(identifiers)), "Duplicate registered identifier")
        require(
            all(isinstance(item, str) and item.startswith(bundle + "/") for item in identifiers),
            "Registered identifier belongs to another bundle",
        )
    return {bundle: sorted(items) for bundle, items in groups.items()}


def enumerate_inventory(raw):
    """Normalize the observed unfiltered flat Xcode 26.4.1 enumeration."""
    require(set(raw) == {"errors", "values"} and raw["errors"] == [], "Enumeration errors/schema")
    values = raw["values"]
    require(isinstance(values, list) and len(values) == 1, "Expected one complete test plan")
    plan = values[0]
    require(
        set(plan) == {"disabledTests", "enabledTests", "testPlan"}
        and plan["testPlan"] == "SuwopVRT"
        and plan["disabledTests"] == [],
        "Wrong plan, disabled tests or unknown enumeration schema",
    )
    require(isinstance(plan["enabledTests"], list), "Missing enabled inventory")
    groups = {bundle: [] for bundle in BUNDLES}
    for entry in plan["enabledTests"]:
        require(
            isinstance(entry, dict) and set(entry) == {"identifier"}, "Unknown enumeration entry"
        )
        identifier = entry["identifier"]
        require(isinstance(identifier, str), "Invalid enumeration identifier")
        match = re.fullmatch(
            r"(SuwopVRT|SuwopVRTUI)/[A-Za-z_][A-Za-z0-9_]*/test[A-Za-z0-9_]+\(\)", identifier
        )
        require(match is not None, "Unknown/parameterized enumeration identifier")
        groups[match[1]].append(identifier.removesuffix("()"))
    return registered_inventory({"schema_version": 1, "bundles": groups})


def executed_inventory(data, summary, config):
    devices = data.get("devices", [])
    configurations = summary.get("devicesAndConfigurations", [])
    require(len(devices) == len(configurations) == 1, "Expected one device/configuration")
    device = devices[0]
    require(configurations[0].get("device") == device, "Device configuration mismatch")
    require(
        device.get("modelName") == "iPhone 17 Pro"
        and device.get("architecture") == "arm64"
        and device.get("platform") == "iOS Simulator"
        and device.get("osVersion") == config["runtime_version"]
        and device.get("osBuildNumber") == config["runtime_build"],
        "Result device differs from pinned environment",
    )
    groups = {}

    def visit(node, bundle=None, parent=None):
        kind = node.get("nodeType")
        if kind == "Runtime Warning":
            require(parent == "Test Case" and not node.get("children"), "Unexpected warning node")
            return
        require(node.get("result") == "Passed", "A result node did not pass")
        if kind in {"Unit test bundle", "UI test bundle"}:
            bundle = node.get("name")
            require(bundle in BUNDLES and bundle not in groups, "Duplicate or unexpected bundle")
            groups[bundle] = []
        if kind == "Test Case":
            require(bundle in groups, "Case outside a known bundle")
            url = urlparse(node.get("nodeIdentifierURL", ""))
            parts = url.path.strip("/").split("/")
            require(
                url.scheme == "test"
                and url.netloc == "com.apple.xcode"
                and len(parts) == 4
                and parts[:2] == ["Suwop", bundle],
                "Unknown test identifier URL",
            )
            identifier = "/".join(parts[1:])
            require(
                node.get("nodeIdentifier") == "/".join(parts[2:]) + "()",
                "Unexpected parameterized/repeated identifier",
            )
            require(identifier not in groups[bundle], "Duplicate execution/retry")
            groups[bundle].append(identifier)
        else:
            require(kind in CONTAINERS, "Unknown result node type")
            require(parent != "Test Case", "Unexpected repeated test child")
        for child in node.get("children", []):
            visit(child, bundle, kind)

    nodes = data.get("testNodes", [])
    require(len(nodes) == 1 and nodes[0].get("nodeType") == "Test Plan", "Incomplete test plan")
    visit(nodes[0])
    count = sum(len(items) for items in groups.values())
    require(count > 0, "No completed tests")
    require(summary.get("result") == "Passed", "Summary did not pass")
    require(summary.get("finishTime", 0) > summary.get("startTime", 0), "Incomplete result time")
    require(not summary.get("testFailures"), "Summary contains failures")
    for stats in [summary, configurations[0]]:
        require(stats.get("passedTests") == count, "Summary/inventory count mismatch")
        require(
            all(stats.get(key) == 0 for key in ("failedTests", "skippedTests", "expectedFailures")),
            "Failed, skipped or expected-failure tests are not acceptance",
        )
    require(summary.get("totalTestCount") == count, "Total count mismatch")
    return {bundle: sorted(items) for bundle, items in groups.items()}
