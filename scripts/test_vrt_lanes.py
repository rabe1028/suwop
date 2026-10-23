"""Real Xcode JSON fixtures and fail-closed partial-lane/union counterexamples."""

import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import vrt
import vrt_lanes as lanes
import vrt_test_inventory as inventory

FIXTURES = Path(__file__).parent / "fixtures/vrt26"


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.tests = json.loads((FIXTURES / "tests.json").read_text())
        self.summary = json.loads((FIXTURES / "summary.json").read_text())

    def parsed(self):
        return inventory.executed_inventory(self.tests, self.summary, vrt.CONFIG)

    def test_real_completed_bundle_inventory_keeps_all_ids_and_runtime_warnings(self):
        result = self.parsed()
        self.assertEqual(
            {key: len(value) for key, value in result.items()}, {"SuwopVRT": 168, "SuwopVRTUI": 61}
        )
        self.assertIn(
            "SuwopVRTUI/EditorUITests/testSliderUndoRedoFilterAndConfirmedDraft",
            result["SuwopVRTUI"],
        )

    def test_skipped_failed_unknown_and_duplicate_case_never_pass(self):
        bundle = self.tests["testNodes"][0]["children"][0]
        case = bundle["children"][0]["children"][0]
        for status in ("Skipped", "Failed", "Expected Failure", "Not Run", "Unknown"):
            with self.subTest(status=status):
                case["result"] = status
                with self.assertRaises(ValueError):
                    self.parsed()
        case["result"] = "Passed"
        bundle["children"][0]["children"].append(copy.deepcopy(case))
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            self.parsed()

    def test_repetition_unknown_schema_missing_device_and_wrong_runtime_fail(self):
        original = copy.deepcopy(self.tests)
        for mutate in (
            lambda: self.tests["testNodes"][0]["children"][0].update(nodeType="Repetition"),
            lambda: self.tests.update(devices=[]),
            lambda: self.tests["devices"][0].update(osVersion="changed"),
        ):
            self.tests = copy.deepcopy(original)
            mutate()
            with self.assertRaises(ValueError):
                self.parsed()

    def test_summary_skip_zero_count_and_incomplete_time_are_not_completion(self):
        original = copy.deepcopy(self.summary)
        for field, value in (
            ("skippedTests", 1),
            ("totalTestCount", 0),
            ("finishTime", 0),
            ("result", "Failed"),
        ):
            self.summary = {**original, field: value}
            with self.assertRaises(ValueError):
                self.parsed()

    def test_normalized_inventory_requires_both_bundles_nonempty_and_unique_ids(self):
        groups = self.parsed()
        inventory.registered_inventory({"schema_version": 1, "bundles": groups})
        for groups in ({}, {"SuwopVRT": []}, {"SuwopVRT": ["x"], "SuwopVRTUI": ["x"]}):
            with self.assertRaises(ValueError):
                inventory.registered_inventory({"schema_version": 1, "bundles": groups})

    def test_real_unfiltered_enumeration_matches_complete_actual_bundle_ids(self):
        raw = json.loads((FIXTURES / "enumeration.json").read_text())
        self.assertEqual(inventory.enumerate_inventory(raw), self.parsed())

    def test_enumeration_errors_disabled_duplicate_parameterized_and_partial_plan_fail(self):
        original = json.loads((FIXTURES / "enumeration.json").read_text())
        for mutation in (
            "errors",
            "disabled",
            "duplicate",
            "parameterized",
            "bundle",
            "empty",
            "plan",
            "multiple",
            "schema",
        ):
            raw = copy.deepcopy(original)
            plan = raw["values"][0]
            if mutation == "errors":
                raw["errors"] = ["Enumeration failed"]
            elif mutation == "disabled":
                plan["disabledTests"] = plan["enabledTests"][:1]
            elif mutation == "duplicate":
                plan["enabledTests"].extend(plan["enabledTests"][:1])
            elif mutation in {"parameterized", "bundle"}:
                plan["enabledTests"][0]["identifier"] = (
                    "SuwopVRT/Class/testMethod(argument:)"
                    if mutation == "parameterized"
                    else "OtherBundle/Class/testMethod()"
                )
            elif mutation == "empty":
                plan["enabledTests"] = [
                    e for e in plan["enabledTests"] if e["identifier"].startswith("SuwopVRT/")
                ]
            elif mutation == "plan":
                plan["testPlan"] = "OtherPlan"
            elif mutation == "multiple":
                raw["values"].append(copy.deepcopy(plan))
            else:
                raw["unknown"] = True
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                inventory.enumerate_inventory(raw)


class LaneTests(unittest.TestCase):
    def setUp(self):
        self.tests = json.loads((FIXTURES / "tests.json").read_text())
        self.summary = json.loads((FIXTURES / "summary.json").read_text())
        self.registered = inventory.executed_inventory(self.tests, self.summary, vrt.CONFIG)
        self.bound = {
            "head": "a" * 40,
            "source": "b" * 64,
            "run_id": "123",
            "attempt": "1",
            "environment": vrt.CONFIG,
            "profile_sha256": "c" * 64,
            "comparator_sha256": "d" * 64,
            "baselines": dict.fromkeys((n + ".png" for n in vrt.SCREENS), "e" * 64),
        }

    def report(self, scope):
        bundle = lanes.SCOPES[scope]
        return {
            "schema_version": 1,
            "scope": scope,
            "full_suite_passed": False,
            "record": False,
            "lane_passed": True,
            "identity": copy.deepcopy(self.bound),
            "stages": [[name, "1", "0"] for name in sorted(lanes.STAGES)],
            "evidence": {
                "registered": copy.deepcopy(self.registered),
                "executed": {bundle: lanes.selection(self.registered, scope)},
                "screens": sorted(vrt.SCREENS if scope == "host-snapshots" else []),
            },
        }

    def restricted(self, bundle, selected):
        """Raw results containing exactly the selected cases of one bundle."""
        tests, summary = copy.deepcopy(self.tests), copy.deepcopy(self.summary)

        def keep(node):
            if node.get("nodeType") == "Test Case":
                parts = node["nodeIdentifierURL"].split("/")
                return "/".join(parts[-3:]) in selected
            node["children"] = [child for child in node.get("children", []) if keep(child)]
            return bool(node["children"])

        tests["testNodes"][0]["children"] = [
            n for n in tests["testNodes"][0]["children"] if n["name"] == bundle and keep(n)
        ]
        return tests, summary

    def test_ui_shards_are_a_deterministic_balanced_exact_partition(self):
        registered = self.registered
        shards = [lanes.selection(registered, s) for s in lanes.SCOPES if s != "host-snapshots"]
        self.assertEqual(len(shards), lanes.UI_SHARDS)
        self.assertEqual(sorted(t for shard in shards for t in shard), registered["SuwopVRTUI"])
        self.assertTrue(all(shards))
        self.assertEqual(
            shards, [lanes.selection(registered, f"ui-{i + 1}") for i in range(lanes.UI_SHARDS)]
        )
        seconds = lanes.durations()
        loads = [sum(seconds[test] for test in shard) for shard in shards]
        self.assertLessEqual(max(loads) - min(loads), max(seconds.values()))
        host = lanes.selection(registered, "host-snapshots")
        self.assertEqual(host, registered["SuwopVRT"])
        with self.assertRaises(ValueError):
            lanes.selection(registered, "ui")

    def test_unmeasured_new_ui_test_is_still_selected_exactly_once(self):
        registered = copy.deepcopy(self.registered)
        registered["SuwopVRTUI"] = sorted([*registered["SuwopVRTUI"], "SuwopVRTUI/New/testNew"])
        shards = [lanes.selection(registered, s) for s in lanes.SCOPES if s != "host-snapshots"]
        self.assertEqual(sorted(t for shard in shards for t in shard), registered["SuwopVRTUI"])

    def test_ui_test_moved_between_shards_breaks_the_union(self):
        reports = self.reports()
        moved = reports["ui-1"]["evidence"]["executed"]["SuwopVRTUI"].pop()
        reports["ui-2"]["evidence"]["executed"]["SuwopVRTUI"].append(moved)
        reports["ui-2"]["evidence"]["executed"]["SuwopVRTUI"].sort()
        with self.assertRaisesRegex(ValueError, "Wrong lane IDs"):
            self.aggregate(list(reports.values()))

    def aggregate(self, reports, matrix="success"):
        return lanes.aggregate(reports, "a" * 40, "123", "1", matrix)

    def reports(self):
        return {scope: self.report(scope) for scope in lanes.SCOPES}

    def test_exact_partial_lanes_form_union_only_with_successful_photokit_matrix(self):
        reports = list(self.reports().values())
        self.assertTrue(self.aggregate(reports)["passed"])
        self.assertTrue(all(report["full_suite_passed"] is False for report in reports))
        for status in ("failure", "cancelled", "skipped", ""):
            with self.assertRaises(ValueError):
                self.aggregate(reports, status)

    def test_missing_duplicate_unknown_and_legacy_full_pass_are_rejected(self):
        lanes_ = self.reports()
        host, ui = lanes_["host-snapshots"], lanes_["ui-1"]
        shards = [lanes_[scope] for scope in lanes.SCOPES if scope != "host-snapshots"]
        for reports in (
            [host],
            [host, host],
            [host, *shards[:-1]],
            [host, *shards, ui],
            [host, *shards[:-1], ui],
            [host, *shards[:-1], {"passed": True}],
            [],
        ):
            with self.assertRaises(ValueError):
                self.aggregate(reports)

    def test_stale_head_run_attempt_and_source_environment_baseline_drift_fail(self):
        for field in self.bound:
            reports = self.reports()
            reports["ui-2"]["identity"][field] = "changed"
            with self.subTest(field=field), self.assertRaises((ValueError, TypeError)):
                self.aggregate(list(reports.values()))

    def test_wrong_ids_with_equal_counts_dropped_new_tests_and_ui_screen_claim_fail(self):
        for mutation in ("id", "registered", "screens", "record", "partial", "status", "stage"):
            reports = self.reports()
            host, ui = reports["host-snapshots"], reports["ui-1"]
            if mutation == "id":
                ui["evidence"]["executed"]["SuwopVRTUI"][0] += "wrong"
            elif mutation == "registered":
                ui["evidence"]["registered"]["SuwopVRT"].append("SuwopVRT/New/test")
            elif mutation == "screens":
                ui["evidence"]["screens"] = host["evidence"]["screens"]
            elif mutation == "stage":
                ui["stages"].pop()
            else:
                ui[
                    {"record": "record", "partial": "full_suite_passed", "status": "lane_passed"}[
                        mutation
                    ]
                ] = mutation != "status"
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.aggregate(list(reports.values()))

    def test_duplicate_failed_and_missing_stage_are_rejected(self):
        stages = self.report("ui-1")["stages"]
        for values in (stages[:-1], stages + stages[:1], [["compare", "1", "65"]]):
            with self.assertRaises(ValueError):
                lanes.validate_stages(values, final=True)

    def test_actual_cli_revalidates_raw_artifact_layout_and_current_checkout(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            environment = {**os.environ, "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}
            environment["GITHUB_SHA"] = lanes.verify.capture(["git", "rev-parse", "HEAD"], vrt.ROOT)
            with patch.dict(os.environ, environment, clear=True):
                self.bound = lanes.identity(vrt.ROOT)
            for scope, bundle in lanes.SCOPES.items():
                artifacts = folder / scope / "DerivedData/VRTArtifacts/completed"
                artifacts.mkdir(parents=True)
                tests, summary = self.restricted(bundle, lanes.selection(self.registered, scope))
                count = len(lanes.selection(self.registered, scope))
                summary.update(passedTests=count, totalTestCount=count)
                summary["devicesAndConfigurations"][0]["passedTests"] = count
                report = self.report(scope)
                for name in report["evidence"]["screens"]:
                    (artifacts / (name + "-actual.png")).touch()
                for name, value in {
                    "lane-report.json": report,
                    "before.json": self.bound,
                    "registered-tests.json": {"schema_version": 1, "bundles": self.registered},
                    "test-inventory.log": tests,
                    "test-summary.log": summary,
                }.items():
                    lanes.write(artifacts / name, value)
                (artifacts / "shutdown.log").write_text("owned shutdown completed\n")
                (artifacts / "stages.tsv").write_text(
                    "".join("\t".join(row) + "\n" for row in report["stages"])
                )
            command = [
                sys.executable,
                "-B",
                str(vrt.ROOT / "scripts/vrt_lanes.py"),
                "aggregate",
                str(folder),
                self.bound["head"],
                "123",
                "1",
                "success",
            ]
            result = subprocess.run(  # noqa: S603 - fixed local Python/helper, temporary fixture paths
                command, cwd=vrt.ROOT, env=environment, capture_output=True
            )
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertTrue(lanes.read(folder / "aggregate.json")["passed"])
            # A plausible report cannot conceal stale raw result identity or a missing lane.
            raw = folder / "ui-1/DerivedData/VRTArtifacts/completed/before.json"
            lanes.write(raw, {**self.bound, "attempt": "previous"})
            result = subprocess.run(  # noqa: S603 - fixed local Python/helper, temporary fixture paths
                command, cwd=vrt.ROOT, env=environment, capture_output=True
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"changed during lane", result.stderr)
            self.assertFalse((folder / "aggregate.json").exists())

    def test_raw_result_not_screens_alone_must_prove_selected_bundle_pass(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            bundle = "SuwopVRT"
            tests = copy.deepcopy(self.tests)
            tests["testNodes"][0]["children"] = [
                n for n in tests["testNodes"][0]["children"] if n["name"] == bundle
            ]
            summary = copy.deepcopy(self.summary)
            count = len(self.registered[bundle])
            summary.update(passedTests=count, totalTestCount=count)
            summary["devicesAndConfigurations"][0]["passedTests"] = count
            for name in vrt.SCREENS:
                (folder / (name + "-actual.png")).touch()
            lanes.write(
                folder / "registered-tests.json", {"schema_version": 1, "bundles": self.registered}
            )
            lanes.write(folder / "test-inventory.log", tests)
            lanes.write(folder / "test-summary.log", summary)
            self.assertEqual(
                len(
                    lanes.validate_lane(folder, "host-snapshots", self.bound, self.bound)["screens"]
                ),
                50,
            )
            tests["testNodes"][0]["children"][0]["children"][0]["children"][0]["result"] = "Failed"
            lanes.write(folder / "test-inventory.log", tests)
            with self.assertRaises(ValueError):
                lanes.validate_lane(folder, "host-snapshots", self.bound, self.bound)


if __name__ == "__main__":
    unittest.main()
