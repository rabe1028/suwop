"""Exercise the compare failure and EXIT paths without building or using a simulator."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import vrt
import vrt_lanes as lanes
from vrt_test_inventory import enumerate_inventory

ENUMERATION = Path(__file__).parent / "fixtures/vrt26/enumeration.json"
SCOPE = "ui-3"
CASE_HEADER = "VRT: Failed XCTest cases:"
UNAVAILABLE = "VRT: Failed XCTest identifiers unavailable."
ASSERTION = "synthetic assertion must stay in the artifact"
CORRUPT = "synthetic corrupt xcresult value"
SHIMS = r"""
uname() { case "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac; }
mise() { :; }
simslim() { if [[ "$1" == --version ]]; then echo 'simslim 0.12.2'; fi; }
uv() {
    shift 3
    local helper="${1#scripts/}"
    shift
    case "$helper:$1" in
        vrt.py:device) cat > /dev/null; echo MOCK-VRT-DEVICE ;;
        vrt_lanes.py:begin) : ;;
        simulator_products.py:prepare-vrt) echo fixture.xctestrun ;;
        *) "$MOCK_PYTHON" -B "$MOCK_SCRIPTS/$helper" "$@" ;;
    esac
}
xcodebuild() {
    if [[ "$1" == -version ]]; then printf 'Xcode 26.4.1\nBuild version 17E202\n'; return; fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -test-enumeration-output-path) cp "$MOCK_ENUMERATION" "$2"; return ;;
            -resultBundlePath)
                if [[ "$MOCK_RESULT" != missing ]]; then mkdir "$2"; fi
                echo 'original compare log'
                return 65
                ;;
        esac
        shift
    done
    return 99
}
"""
XCRUN = """#!/bin/bash
case "$1:$2" in
    simctl:list) echo '{}' ;;
    simctl:shutdown) echo "shutdown $3" ;;
    xcresulttool:get)
        if [[ "$MOCK_RESULT" == tool-error ]]; then
            echo 'synthetic tool stderr' >&2
            exit 64
        fi
        cat "$MOCK_INVENTORY"
        ;;
    *) exit 99 ;;
esac
"""


def failure_tree(identifiers):
    suites = {}
    for identifier in identifiers:
        _, suite, _ = identifier.split("/")
        suites.setdefault(suite, []).append(
            {
                "nodeType": "Test Case",
                "result": "Failed",
                "nodeIdentifier": identifier.split("/", 1)[1] + "()",
                "nodeIdentifierURL": "test://com.apple.xcode/Suwop/" + identifier,
                "children": [{"nodeType": "Failure Message", "name": ASSERTION}],
            }
        )
    bundle = {
        "nodeType": "UI test bundle",
        "name": "SuwopVRTUI",
        "children": [
            {"nodeType": "Test Suite", "name": suite, "children": children}
            for suite, children in suites.items()
        ],
    }
    return {"testNodes": [{"nodeType": "Test Plan", "children": [bundle]}]}


class CompareFailureTests(unittest.TestCase):
    def run_failure(self, root, scenario, payload):
        commands = root / "bin"
        commands.mkdir()
        (commands / "xcrun").write_text(XCRUN)
        (commands / "xcrun").chmod(0o755)
        (root / "shims").write_text(SHIMS)
        (root / "tests.json").write_text(payload)
        scripts = root / "scripts"
        scripts.mkdir()
        (scripts / "vrt.sh").write_bytes((vrt.ROOT / "scripts/vrt.sh").read_bytes())
        result = subprocess.run(  # noqa: S603 - fixed shell and isolated fake tool fixture
            ["/bin/bash", str(scripts / "vrt.sh"), "--ci-lane", SCOPE],
            cwd=root,
            env={
                **os.environ,
                "PATH": str(commands) + os.pathsep + os.environ["PATH"],
                "BASH_ENV": str(root / "shims"),
                "MOCK_PYTHON": sys.executable,
                "MOCK_SCRIPTS": str(vrt.ROOT / "scripts"),
                "MOCK_ENUMERATION": str(ENUMERATION),
                "MOCK_INVENTORY": str(root / "tests.json"),
                "MOCK_RESULT": scenario,
                "SUWOP_SIMULATOR_PRODUCTS": str(root / "prebuilt"),
            },
            capture_output=True,
            text=True,
            timeout=15,
        )
        (artifacts,) = (root / "DerivedData/VRTArtifacts").iterdir()
        self.assertEqual(result.returncode, 1, result.stderr)  # Existing failed CI lane status.
        self.assertIn("original compare log", result.stdout)
        self.assertEqual((artifacts / "compare.log").read_text(), "original compare log\n")
        stages = (artifacts / "stages.tsv").read_text().splitlines()
        self.assertRegex(stages[-1], r"^compare\t\d+\t65$")
        self.assertFalse(lanes.read(artifacts / "lane-report.json")["lane_passed"])
        self.assertEqual((artifacts / "shutdown.log").read_text(), "shutdown MOCK-VRT-DEVICE\n")
        self.assertFalse((root / "DerivedData/VRT.lock").exists())
        return result.stdout + result.stderr, artifacts

    def test_compare_failure_prints_only_bounded_case_identifiers_and_keeps_raw_result(self):
        registered = enumerate_inventory(lanes.read(ENUMERATION))
        identifiers = lanes.selection(registered, SCOPE)[:10]
        self.assertEqual(len(identifiers), 10)
        payload = json.dumps(failure_tree(identifiers))
        with tempfile.TemporaryDirectory() as temp:
            output, artifacts = self.run_failure(Path(temp), "valid", payload)
            lines = output.splitlines()
            first = lines.index(CASE_HEADER) + 1
            self.assertEqual(lines[first : first + 8], identifiers[:8])
            self.assertEqual(lines[first + 8], "VRT: Additional failed XCTest identifiers omitted.")
            self.assertNotIn(identifiers[8], output)
            self.assertNotIn(ASSERTION, output)
            self.assertEqual((artifacts / "test-inventory.log").read_text(), payload)

    def test_missing_malformed_unregistered_or_unreadable_result_keeps_compare_failure(self):
        unregistered = json.dumps(failure_tree(["SuwopVRTUI/UnknownTests/testSynthetic"]))
        for scenario, payload in (
            ("missing", CORRUPT),
            ("malformed", CORRUPT),
            ("unregistered", unregistered),
            ("tool-error", CORRUPT),
        ):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temp:
                output, artifacts = self.run_failure(Path(temp), scenario, payload)
                self.assertEqual(output.count(UNAVAILABLE), 1)
                for detail in (CASE_HEADER, CORRUPT, "testSynthetic", "synthetic tool stderr"):
                    self.assertNotIn(detail, output)
                if scenario == "tool-error":
                    self.assertEqual(
                        (artifacts / "test-inventory.stderr.log").read_text(),
                        "synthetic tool stderr\n",
                    )
