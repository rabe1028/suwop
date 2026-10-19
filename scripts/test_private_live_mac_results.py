"""Counterexamples for macOS Live auditing; synthetic results are not playback evidence."""

import contextlib
import copy
import io
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import private_live_mac_results as results


def completed():
    # Shape observed in the real Xcode16 macOS xcresult export, with synthetic successful statuses.
    device = {"architecture": "arm64", "platform": "macOS", "deviceId": "synthetic-mac"}
    stats = {"passedTests": 10, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}
    summary = {
        **stats,
        "result": "Passed",
        "startTime": 1,
        "finishTime": 2,
        "totalTestCount": 10,
        "testFailures": [],
        "devicesAndConfigurations": [{**stats, "device": device}],
    }
    base = f"test://com.apple.xcode/Suwop/{results.BUNDLE}"
    cases = [
        {
            "name": method + "()",
            "nodeType": "Test Case",
            "result": "Passed",
            "nodeIdentifier": f"{results.SUITE}/{method}()",
            "nodeIdentifierURL": f"{base}/{results.SUITE}/{method}",
        }
        for method in sorted(results.METHODS)
    ]
    suite = {
        "name": results.SUITE,
        "nodeType": "Test Suite",
        "nodeIdentifierURL": f"{base}/{results.SUITE}",
        "result": "Passed",
        "children": cases,
    }
    bundle = {
        "name": results.BUNDLE,
        "nodeType": "UI test bundle",
        "nodeIdentifierURL": base,
        "result": "Passed",
        "children": [suite],
    }
    tests = {
        "devices": [device],
        "testNodes": [
            {
                "name": "SuwopPrivateLiveUIProbe",
                "nodeType": "Test Plan",
                "result": "Passed",
                "children": [bundle],
            }
        ],
    }
    return summary, tests, cases


PROBE_GUARD = "#if os(macOS) && SUWOP_LIVE_COMPOSITOR_PROBE"
PROBE_METHOD = "testOwnedCompositorScreenshotObservesActualProtectedLiveMotion"


def surface_source():
    return (
        Path(__file__).resolve().parents[1]
        / "NativeAcceptance/PrivateLiveTests/PrivateLiveSurfaceTests.swift"
    ).read_text()


def normal_source_methods(source):
    # Accept only this single trailing experiment. Runtime audit still requires all ten normal IDs.
    if source.count(PROBE_GUARD) != 1:
        raise ValueError("Expected one exact compositor probe guard")
    normal, probe = source.split(PROBE_GUARD + "\n")
    block = re.fullmatch(
        r"    extension PrivateLiveSurfaceTests \{(?P<body>[\s\S]+)\n    \}\n#endif\n?",
        probe,
    )
    if block is None or re.search(r"^\s*#", block["body"], re.MULTILINE):
        raise ValueError("Probe must be one final independent conditional extension")
    # This deliberately narrow fixture check rejects additional top-level declarations.
    unquoted = re.sub(r'"(?:\\.|[^"\\])*"', '""', block["body"])
    depth = 1
    for character in unquoted:
        depth += (character == "{") - (character == "}")
        if depth < 1:
            raise ValueError("Probe extension ended before its final delimiter")
    if depth != 1 or re.findall(r"func (test[A-Za-z0-9_]+)\(", probe) != [PROBE_METHOD]:
        raise ValueError("Unknown, missing or duplicate experimental test")
    return re.findall(r"func (test[A-Za-z0-9_]+)\(", normal)


class PrivateLiveMacResultTests(unittest.TestCase):
    def test_all_exact_source_methods_match_audited_inventory(self):
        declared = normal_source_methods(surface_source())
        self.assertEqual(len(declared), 10)
        self.assertEqual(set(declared), results.METHODS)
        summary, tests, _ = completed()
        identifiers = results.audit(summary, tests)
        self.assertEqual(len(identifiers), 10)
        self.assertTrue(all(item.startswith(results.BUNDLE + "/") for item in identifiers))

    def test_external_ui_inventory_exactly_preserves_all_ten_native_scenarios(self):
        root = Path(__file__).resolve().parents[1]
        ui = (
            root
            / "NativeAcceptance/PrivateLiveUIProbeTests/PrivateLiveIndependentCompositorTests.swift"
        ).read_text()
        declared = re.findall(r"func (test[A-Za-z0-9_]+)\(", ui)
        self.assertEqual(len(declared), 10)
        self.assertEqual(set(declared), results.METHODS)
        wire = (
            root / "NativeAcceptance/PrivateLiveUIProbeShared/PrivateLiveAcceptanceCase.swift"
        ).read_text()
        cases = re.findall(r'case ([a-zA-Z]+) = "(test[A-Za-z0-9_]+)"', wire)
        self.assertEqual(len(cases), 10)
        self.assertEqual({method for _, method in cases}, results.METHODS)
        for case, method in cases:
            if case in {"fullPlayback", "activeReplay"}:
                self.assertIn("PrivateLiveUIProbeSession(test: ." + case + ")", ui)
            else:
                self.assertIn(
                    "func "
                    + method
                    + "() async throws {\n        try await nativeScenario(."
                    + case
                    + ")",
                    ui,
                )
        self.assertNotIn("XCTSkip", ui)

    def test_only_exact_final_guarded_probe_can_be_separated(self):
        source = surface_source()
        for changed in (
            source.replace(PROBE_GUARD, "#if os(macOS)"),
            source.replace(PROBE_GUARD, PROBE_GUARD + "\n" + PROBE_GUARD),
            source.removesuffix("#endif\n"),
            source + "// trailing declaration\n",
            source.replace("    extension PrivateLiveSurfaceTests {", "    extension OtherTests {"),
            source.replace(PROBE_METHOD, "testUnrelated"),
            source.replace(PROBE_GUARD, PROBE_GUARD + "\n#if UNKNOWN"),
            source.replace("\n    }\n#endif", "\n    }\n    extension OtherTests {}\n#endif"),
            source.replace(PROBE_METHOD, PROBE_METHOD + "() {}\n        func testExtra"),
        ):
            with self.subTest(tail=changed[-160:]), self.assertRaises(ValueError):
                normal_source_methods(changed)

    def test_normal_methods_are_never_excluded_by_name_or_other_guards(self):
        source = surface_source()
        normal, probe = source.split(PROBE_GUARD)
        for extra in (
            f"func {PROBE_METHOD}() {{}}\n",
            "#if UNKNOWN\nfunc testUnrelated() {}\n#endif\n",
        ):
            declared = normal_source_methods(normal + extra + PROBE_GUARD + probe)
            self.assertEqual(len(declared), 11)
            self.assertNotEqual(set(declared), results.METHODS)

    def test_same_count_with_substituted_missing_or_duplicate_case_fails(self):
        for mode in ("unknown", "duplicate", "missing", "extra"):
            with self.subTest(mode=mode):
                summary, tests, cases = completed()
                if mode == "unknown":
                    cases[0]["name"] = "testUnrelated()"
                elif mode == "duplicate":
                    cases[0] = copy.deepcopy(cases[1])
                elif mode == "missing":
                    cases.pop()
                else:
                    cases.append(copy.deepcopy(cases[0]))
                with self.assertRaises(ValueError):
                    results.audit(summary, tests)

    def test_summary_pass_cannot_hide_case_failure_skip_or_missing_result(self):
        for status in ("Failed", "Skipped", "Not Run", "Expected Failure", None):
            with self.subTest(status=status):
                summary, tests, cases = completed()
                cases[0]["result"] = status
                with self.assertRaises(ValueError):
                    results.audit(summary, tests)

    def test_wrong_url_bundle_parameterization_or_repetition_is_rejected(self):
        for mode in ("url", "parameter", "bundle", "repetition", "failure-child"):
            with self.subTest(mode=mode):
                summary, tests, cases = completed()
                if mode == "url":
                    cases[0]["nodeIdentifierURL"] += "/other"
                elif mode == "parameter":
                    cases[0]["nodeIdentifier"] += "(argument:)"
                elif mode == "bundle":
                    tests["testNodes"][0]["children"][0]["name"] = "ForeignBundle"
                else:
                    cases[0]["children"] = [
                        {"nodeType": "Repetition" if mode == "repetition" else "Failure Message"}
                    ]
                with self.assertRaises(ValueError):
                    results.audit(summary, tests)

    def test_runtime_warning_is_allowed_only_as_terminal_case_child(self):
        summary, tests, cases = completed()
        warning = {"nodeType": "Runtime Warning", "name": "Synthetic warning"}
        cases[0]["children"] = [warning]
        self.assertEqual(len(results.audit(summary, tests)), 10)
        warning["children"] = [{"nodeType": "Test Case"}]
        with self.assertRaises(ValueError):
            results.audit(summary, tests)

    def test_summary_device_time_and_each_counter_are_cross_checked(self):
        for mode in ("device", "time", "total", "passed", "failed", "skip", "expected", "bool"):
            with self.subTest(mode=mode):
                summary, tests, _ = completed()
                if mode == "device":
                    summary["devicesAndConfigurations"][0]["device"] = {"platform": "iOS Simulator"}
                elif mode == "time":
                    summary["finishTime"] = summary["startTime"]
                elif mode == "total":
                    summary["totalTestCount"] = 9
                else:
                    key = {
                        "passed": "passedTests",
                        "failed": "failedTests",
                        "skip": "skippedTests",
                        "expected": "expectedFailures",
                        "bool": "failedTests",
                    }[mode]
                    summary["devicesAndConfigurations"][0][key] = False if mode == "bool" else 1
                with self.assertRaises(ValueError):
                    results.audit(summary, tests)

    def test_cli_preserves_raw_hashes_ids_and_failed_audit_receipt(self):
        summary, tests, cases = completed()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary_path, tests_path, output = (
                root / name for name in ("summary", "tests", "audit")
            )
            summary_path.write_text(json.dumps(summary))
            tests_path.write_text(json.dumps(tests))
            argv = ["audit", str(summary_path), str(tests_path), str(output)]
            with patch.object(sys, "argv", argv), contextlib.redirect_stdout(io.StringIO()):
                results.main()
            accepted = json.loads(output.read_text())
            self.assertTrue(accepted["accepted"])
            self.assertEqual(len(accepted["identifiers"]), 10)
            cases[0]["result"] = "Failed"
            tests_path.write_text(json.dumps(tests))
            with patch.object(sys, "argv", argv), self.assertRaises(SystemExit):
                results.main()
            rejected = json.loads(output.read_text())
            self.assertFalse(rejected["accepted"])
            self.assertEqual(accepted["summary_sha256"], rejected["summary_sha256"])
            self.assertNotEqual(accepted["tests_sha256"], rejected["tests_sha256"])
