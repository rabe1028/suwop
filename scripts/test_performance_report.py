"""Latency reports must not interpret missing or truncated measurements as passes."""

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import performance_report


class PerformanceReportTests(unittest.TestCase):
    def report(self, events, *args, dropped=0):
        with tempfile.TemporaryDirectory() as directory:
            trace = Path(directory) / "trace.json"
            trace.write_text(json.dumps({"traceEvents": events, "droppedEvents": dropped}))
            with (
                patch("sys.argv", ["performance_report", str(trace), *args]),
                contextlib.redirect_stdout(io.StringIO()) as output,
            ):
                failed = performance_report.main()
            return failed, json.loads(output.getvalue())

    def test_latency_percentiles_and_regression_gate(self):
        events = [
            {"name": "mainActorDelay", "ph": "X", "dur": duration}
            for duration in [1_000, 2_000, 300_000]
        ]
        failed, report = self.report(events, "--max-ui-delay-p95-ms", "100")
        self.assertTrue(failed)
        self.assertEqual(report["after"]["phases"]["mainActorDelay"]["p95_ms"], 300)

    def test_missing_preview_and_truncated_trace_fail(self):
        self.assertTrue(self.report([], "--max-preview-p95-ms", "1000")[0])
        self.assertTrue(self.report([], dropped=1)[0])

    def test_maximum_gate_catches_a_rare_freeze_hidden_by_p95(self):
        events = [{"name": "mainActorDelay", "ph": "X", "dur": 10_000}] * 100
        events.append({"name": "mainActorDelay", "ph": "X", "dur": 3_900_000})
        self.assertFalse(self.report(events, "--max-ui-delay-p95-ms", "100")[0])
        self.assertTrue(self.report(events, "--max-ui-delay-ms", "1000")[0])
        self.assertTrue(self.report([], "--max-ui-delay-ms", "1000")[0])

    def test_decode_gate_requires_decode_samples(self):
        self.assertTrue(self.report([], "--max-snapshot-decode-p95-ms", "4000")[0])
        events = [{"name": "snapshotDecode", "ph": "X", "dur": 4_800_000}]
        self.assertTrue(self.report(events, "--max-snapshot-decode-p95-ms", "4000")[0])

    def test_valid_sample_passes(self):
        events = [{"name": "previewImage", "ph": "X", "dur": 10_000}]
        self.assertFalse(self.report(events, "--max-preview-p95-ms", "1000")[0])

    def test_load_alone_does_not_satisfy_end_to_end_preview_gate(self):
        events = [{"name": "previewImage", "ph": "X", "dur": 10_000}]
        self.assertTrue(self.report(events, "--max-preview-request-p95-ms", "1000")[0])
        events.append({"name": "previewRequest", "ph": "X", "dur": 2_000_000})
        self.assertTrue(self.report(events, "--max-preview-request-p95-ms", "1000")[0])

    def test_snapshot_component_alone_does_not_satisfy_runtime_gate(self):
        events = [{"name": "snapshotDecode", "ph": "X", "dur": 10_000}]
        self.assertTrue(self.report(events, "--max-snapshot-runtime-p95-ms", "1000")[0])
        events.append({"name": "snapshotRuntime", "ph": "X", "dur": 2_000_000})
        self.assertTrue(self.report(events, "--max-snapshot-runtime-p95-ms", "1000")[0])
        self.assertFalse(self.report(events, "--max-snapshot-runtime-p95-ms", "3000")[0])
