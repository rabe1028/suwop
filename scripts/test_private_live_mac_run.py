"""Owned cleanup counterexamples; mocks are management tests, not native acceptance."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import private_live_mac_run as run


def identity(pid, bundle, executable):
    return {
        "pid": pid,
        "bundleID": bundle,
        "executable": str(executable.resolve()),
        "launched": 100.0,
    }


class OwnedMacCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.out = self.root / "outside"
        self.out.mkdir()
        self.container = self.root / "container"
        self.container.mkdir()
        self.host = self.root / "host"
        self.runner = self.root / "runner"

    def receipt(self, name, value):
        directory = self.container / ("case-" + name)
        directory.mkdir()
        original = {**value, "nonce": name}
        for filename in ("owned-launch-identity.json", "host-identity.json"):
            (directory / filename).write_text(json.dumps(original))
        (directory / "launch-intent.json").write_text(
            json.dumps({"nonce": name, "launchedAfter": 99.0})
        )
        return directory

    def test_completed_case_does_not_block_later_known_live_case_cleanup(self):
        old = identity(1001, run.HOST_ID, self.host)
        current = identity(1002, run.HOST_ID, self.host)
        self.receipt("old", old)
        self.receipt("new", current)

        def query(_out, label, _requested, **_kwargs):
            return [current] if label == "host-final" else []

        with (
            patch.object(run.process, "query", side_effect=query),
            patch.object(run, "stop_owned") as stop,
        ):
            run.cleanup(self.out, self.container, self.host, self.runner, 99.0)
        self.assertEqual(stop.call_count, 1)
        self.assertEqual(stop.call_args.args[1], current)

    def test_missing_case_identity_still_drains_independently_owned_runner(self):
        (self.container / "case-failed-before-launch").mkdir()
        runner = identity(2001, run.RUNNER_ID, self.runner)

        def query(_out, label, _requested, **_kwargs):
            return [runner] if label == "runner-final" else []

        with (
            patch.object(run.process, "query", side_effect=query),
            patch.object(run, "stop_owned") as stop,
            self.assertRaisesRegex(ValueError, "case identity"),
        ):
            run.cleanup(self.out, self.container, self.host, self.runner, 99.0)
        self.assertEqual(stop.call_args.args[1], runner)

    def test_unknown_host_is_not_adopted_but_known_runner_is_stopped(self):
        unknown = identity(3001, run.HOST_ID, self.host)
        runner = identity(3002, run.RUNNER_ID, self.runner)

        def query(_out, label, _requested, **_kwargs):
            return {"host-final": [unknown], "runner-final": [runner]}.get(label, [])

        with (
            patch.object(run.process, "query", side_effect=query),
            patch.object(run, "stop_owned") as stop,
            self.assertRaisesRegex(ValueError, "immutable launch receipt"),
        ):
            run.cleanup(self.out, self.container, self.host, self.runner, 99.0)
        self.assertEqual(stop.call_count, 1)
        self.assertEqual(stop.call_args.args[1], runner)

    def test_conflicting_host_receipts_cannot_authorize_termination(self):
        current = identity(4001, run.HOST_ID, self.host)
        directory = self.receipt("conflict", current)
        changed = {**current, "nonce": "wrong"}
        (directory / "host-identity.json").write_text(json.dumps(changed))

        def query(_out, label, _requested, **_kwargs):
            return [current] if label == "host-final" else []

        with (
            patch.object(run.process, "query", side_effect=query),
            patch.object(run, "stop_owned") as stop,
            self.assertRaises(ValueError),
        ):
            run.cleanup(self.out, self.container, self.host, self.runner, 99.0)
        stop.assert_not_called()

    def test_stale_runner_executable_or_launch_time_has_no_cleanup_authority(self):
        for changed in ({"executable": "/foreign"}, {"launched": 1.0}):
            with self.subTest(changed=changed):
                runner = {**identity(5001, run.RUNNER_ID, self.runner), **changed}

                def query(_out, label, _requested, expected=runner, **_kwargs):
                    return [expected] if label == "runner-final" else []

                with (
                    patch.object(run.process, "query", side_effect=query),
                    patch.object(run, "stop_owned") as stop,
                    self.assertRaisesRegex(ValueError, "Unknown runner"),
                ):
                    run.cleanup(self.out, self.container, self.host, self.runner, 99.0)
                stop.assert_not_called()

    def test_host_query_timeout_still_drains_the_exact_runner(self):
        runner = identity(6001, run.RUNNER_ID, self.runner)

        def query(_out, label, _requested, **_kwargs):
            if label == "host-final":
                raise subprocess.TimeoutExpired("owned-helper", 5)
            return [runner] if label == "runner-final" else []

        with (
            patch.object(run.process, "query", side_effect=query),
            patch.object(run, "stop_owned") as stop,
            self.assertRaisesRegex(ValueError, "host cleanup"),
        ):
            run.cleanup(self.out, self.container, self.host, self.runner, 99.0)
        self.assertEqual(stop.call_count, 1)
        self.assertEqual(stop.call_args.args[1], runner)

    def test_bad_primary_identity_does_not_block_exact_focus_and_runner_cleanup(self):
        case = self.container / "case-window-events"
        case.mkdir()
        focus_dir = case / "focus"
        focus_dir.mkdir()
        executable = self.root / "focus-executable"
        focus = identity(7001, run.FOCUS_ID, executable)
        value = {**focus, "nonce": "focus-nonce"}
        for name in ("owned-launch-identity.json", "host-identity.json"):
            (focus_dir / name).write_text(json.dumps(value))
        (focus_dir / "launch-intent.json").write_text(
            json.dumps({"nonce": "focus-nonce", "launchedAfter": 99.0})
        )
        runner = identity(7002, run.RUNNER_ID, self.runner)

        def query(_out, label, _requested, **_kwargs):
            return {"focus-final": [focus], "runner-final": [runner]}.get(label, [])

        with (
            patch.object(run.process, "query", side_effect=query),
            patch.object(run, "stop_owned") as stop,
            self.assertRaisesRegex(ValueError, "host case identity"),
        ):
            run.cleanup(self.out, self.container, self.host, self.runner, 99.0, executable)
        self.assertEqual([call.args[1] for call in stop.call_args_list], [focus, runner])

    def test_unknown_focus_is_never_adopted_or_terminated(self):
        executable = self.root / "focus-executable"
        focus = identity(8001, run.FOCUS_ID, executable)

        def query(_out, label, _requested, **_kwargs):
            return [focus] if label == "focus-final" else []

        with (
            patch.object(run.process, "query", side_effect=query),
            patch.object(run, "stop_owned") as stop,
            self.assertRaisesRegex(ValueError, "immutable launch receipt"),
        ):
            run.cleanup(self.out, self.container, self.host, self.runner, 99.0, executable)
        stop.assert_not_called()

    def test_evidence_uses_persistent_runner_container_not_purgeable_tmp(self):
        base = run.durable_evidence_base(self.root)
        expected = (
            self.root
            / "Library/Containers"
            / run.RUNNER_ID
            / "Data/Library/Application Support/SuwopLiveAcceptance"
        )
        self.assertEqual(base, expected)
        self.assertNotIn("tmp", base.relative_to(self.root).parts)
        self.assertEqual(base.stat().st_uid, run.os.getuid())
        self.assertEqual(base.stat().st_mode & 0o777, 0o700)

    def test_evidence_parent_symlink_is_rejected_before_writing_foreign_tree(self):
        foreign = self.root / "foreign"
        foreign.mkdir()
        (self.root / "Library").symlink_to(foreign, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "Unsafe evidence container"):
            run.durable_evidence_base(self.root)
        self.assertEqual(list(foreign.iterdir()), [])
