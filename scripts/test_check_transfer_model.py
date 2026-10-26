"""Ensure checker failures cannot masquerade as model-checking evidence."""

import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "transfer_model", Path(__file__).with_name("check-transfer-model.py")
)
MODEL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODEL)


class ModelVerdictTests(unittest.TestCase):
    def test_timeout_terminates_the_checker_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            pid_file = directory / "pid"
            code = (
                "import os, time; from pathlib import Path; "
                f"Path({str(pid_file)!r}).write_text(str(os.getpid())); time.sleep(30)"
            )
            with (
                (directory / "output").open("w") as output,
                self.assertRaises(subprocess.TimeoutExpired),
            ):
                MODEL.run_checker([sys.executable, "-c", code], directory, output, timeout=2)
            self.assertTrue(pid_file.exists())
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pid_file.read_text()), 0)

    def test_timeout_is_reported_as_a_tool_failure(self):
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(
                MODEL, "run_checker", side_effect=subprocess.TimeoutExpired(["quint"], 600)
            ),
        ):
            result = MODEL.check("step", "safety", Path(temporary))
        self.assertEqual(result["verdict"], "tool_failure")
        self.assertIn("timed out", result["failure"])
        self.assertIsNone(result["states"])

    def test_final_summary_overrides_intermediate_queue_progress(self):
        def completed(_command, _directory, output):
            output.write(
                "10 states generated, 8 distinct states found, 2 states left on queue.\n"
                "Model checking completed. No error has been found.\n"
                "20 states generated, 12 distinct states found, 0 states left on queue.\n"
                "[ok] No violation found\n"
            )
            return 0

        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(MODEL, "run_checker", side_effect=completed),
        ):
            result = MODEL.check("step", "safety", Path(temporary))
        self.assertEqual(result["verdict"], "passed")
        self.assertEqual(result["states"], [20, 12, 0])

    def test_control_names_and_properties_exist_in_the_model(self):
        source = MODEL.MODEL.read_text()
        safety = re.search(r"val safety = all \{([^}]+)\}", source).group(1)
        for step, invariant in MODEL.CONTROLS:
            with self.subTest(step=step):
                self.assertRegex(source, rf"action {step} =")
                self.assertRegex(source, rf"val {invariant} =")
                self.assertRegex(safety, rf"\b{invariant}\b")

    def test_overlap_control_and_positive_witness_are_distinct(self):
        source = MODEL.OVERLAP_MODEL.read_text()
        self.assertIn("action unsafeOverlapStep =", source)
        safety = re.search(r"val safety = all \{([^}]+)\}", source).group(1)
        self.assertIn("noOverlappingDeletion", safety)
        self.assertNotIn("independentScopesNeverBothSubmitted", safety)
        self.assertIn("val independentScopesNeverBothSubmitted =", source)

    def test_model_phase_domain_matches_the_application(self):
        domain = (MODEL.ROOT / "crates/suwop-core/src/domain.rs").read_text()
        variants = re.search(r"pub enum TransferPhase \{([^}]+)\}", domain).group(1)
        actual = set(re.findall(r"^\s*(\w+),", variants, re.MULTILINE))
        phase_set = re.search(
            r"Set\(([^\n]+)\)\.contains\(s\.phase\)",
            MODEL.MODEL.read_text().split("val typeOK =", 1)[1],
        ).group(1)
        modeled = set(re.findall(r'"(\w+)"', phase_set))
        self.assertEqual(modeled, actual)

    def test_metadata_control_and_positive_witness_are_distinct(self):
        source = MODEL.METADATA_MODEL.read_text()
        self.assertIn("action unsafeFirstSourceStep =", source)
        self.assertIn("val everyOriginalPreserved =", source)
        self.assertIn("val differingSourcesNeverAuthorized =", source)

    def test_tool_failure_is_not_a_counterexample(self):
        for output in (
            "error: parsing failed",
            "java.lang.UnsupportedClassVersionError",
            "error: found a counterexample",
            "[violation] Found an issue\nState 1: <Initial predicate>",
        ):
            with self.subTest(output=output):
                self.assertEqual(MODEL.classify(1, output), "tool_failure")

    def test_only_a_real_invariant_trace_is_a_counterexample(self):
        output = (
            "Error: Invariant q_inv is violated.\n"
            "State 1: <Initial predicate>\n[violation] Found an issue"
        )
        self.assertEqual(MODEL.classify(1, output), "counterexample")
        self.assertEqual(MODEL.classify(0, output), "tool_failure")

    def test_simulation_or_partial_search_is_not_an_exhaustive_pass(self):
        for output in (
            "[ok] No violation found",
            "Model checking completed. No error has been found.\n[ok] No violation found",
        ):
            with self.subTest(output=output):
                self.assertEqual(MODEL.classify(0, output), "tool_failure")
        complete = (
            "Model checking completed. No error has been found.\n"
            "331 states found, 0 states left on queue.\n[ok] No violation found"
        )
        self.assertEqual(MODEL.classify(0, complete), "passed")
        self.assertEqual(MODEL.classify(1, complete), "tool_failure")
        for queued in ("10", "100", "1,000"):
            with self.subTest(queued=queued):
                self.assertEqual(
                    MODEL.classify(0, complete.replace("0 states left", f"{queued} states left")),
                    "tool_failure",
                )


if __name__ == "__main__":
    unittest.main()
