"""Exercise evidence validity, failure output and bounded registry retries."""

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import verify


class VerificationTests(unittest.TestCase):
    def setUp(self):
        # Hooks export Git-local variables; do not let those point at the real index.
        local_vars = verify.capture(
            ["git", "rev-parse", "--local-env-vars"], Path.cwd()
        ).splitlines()
        clean_env = {key: value for key, value in os.environ.items() if key not in local_vars}
        environment = patch.dict(os.environ, clean_env, clear=True)
        environment.start()
        self.addCleanup(environment.stop)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        (self.root / ".gitignore").write_text(".tools/\n")
        (self.root / "source").write_text("before")
        self.git("add", ".")
        self.git("-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture")

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)  # noqa: S603, S607

    def run_check(self, script):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = verify.run_check(self.root, "test", [sys.executable, "-c", script])
        report = next((self.root / ".tools/verification").glob("*/result.json"))
        return code, json.loads(report.read_text()), output.getvalue()

    def test_large_success_log_is_preserved_but_not_printed(self):
        code, report, output = self.run_check("print('large log ' * 10000)")
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "passed")
        self.assertGreater(Path(report["log"]).stat().st_size, 90000)
        self.assertLess(len(output), 4000)

    def test_failure_retains_exit_code_and_bounded_tail(self):
        code, report, output = self.run_check("print('x' * 20000); raise SystemExit(7)")
        self.assertEqual(code, 7)
        self.assertEqual(report["status"], "failed")
        self.assertLess(len(output), 10000)

    def test_source_change_cannot_be_reported_as_success(self):
        code, report, _ = self.run_check(
            "from pathlib import Path; Path('source').write_text('after')"
        )
        self.assertEqual(code, 3)
        self.assertEqual(report["status"], "source_changed")

    def test_untracked_and_deleted_files_change_fingerprint(self):
        before = verify.fingerprint(self.root)
        (self.root / "new source").write_text("new")
        self.assertNotEqual(before, verify.fingerprint(self.root))
        (self.root / "new source").unlink()
        self.assertEqual(before, verify.fingerprint(self.root))
        (self.root / "source").unlink()
        self.assertNotEqual(before, verify.fingerprint(self.root))

    def test_missing_command_fails_with_evidence(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(verify.run_check(self.root, "missing", ["/no/such/check"]), 127)


class RegistryRetryTests(unittest.TestCase):
    def run_pull(self, failures, message):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            state = root / "count"
            mock = root / "compose"
            mock.write_text(
                '#!/bin/bash\nn=0\n[[ ! -f "$STATE" ]] || n=$(cat "$STATE")\n'
                'echo $((n+1)) > "$STATE"\n'
                'if [[ "$n" -lt "$FAILURES" ]]; then echo "$MESSAGE"; exit 9; fi\n'
            )
            mock.chmod(0o755)
            sleep = root / "sleep"
            sleep.write_text("#!/bin/bash\nexit 0\n")
            sleep.chmod(0o755)
            result = subprocess.run(  # noqa: S603
                ["bash", str(Path(__file__).with_name("pull-test-images.sh")), str(mock)],  # noqa: S607
                env={
                    **os.environ,
                    "STATE": str(state),
                    "FAILURES": str(failures),
                    "MESSAGE": message,
                    "PATH": str(root) + os.pathsep + os.environ["PATH"],
                },
                capture_output=True,
            )
            return result.returncode, int(state.read_text())

    def test_throttling_recovers_before_tests(self):
        self.assertEqual(self.run_pull(2, "toomanyrequests"), (0, 3))

    def test_persistent_throttling_is_bounded(self):
        self.assertEqual(self.run_pull(10, "429 Too Many Requests"), (9, 3))

    def test_other_failures_are_not_retried(self):
        self.assertEqual(self.run_pull(10, "unauthorized"), (9, 1))

    def test_digest_digits_are_not_a_rate_limit(self):
        self.assertEqual(self.run_pull(10, "manifest sha256:ab429cd not found"), (9, 1))


class CISummaryTests(unittest.TestCase):
    def summary(self, status, conclusion, expected="a" * 40):
        data = {
            "headSha": "a" * 40,
            "status": status,
            "conclusion": conclusion,
            "jobs": [{"databaseId": 1, "name": "vrt", "status": status, "conclusion": conclusion}],
        }
        with (
            patch.object(verify, "capture", return_value=json.dumps(data)),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            return verify.ci_summary(Path.cwd(), "123", expected)

    def test_success_requires_completed_matching_head(self):
        self.assertEqual(self.summary("completed", "success"), 0)
        self.assertEqual(self.summary("completed", "success", "b" * 40), 3)

    def test_pending_failed_and_cancelled_are_not_success(self):
        self.assertEqual(self.summary("in_progress", ""), 2)
        self.assertEqual(self.summary("completed", "failure"), 1)
        self.assertEqual(self.summary("completed", "cancelled"), 1)


if __name__ == "__main__":
    unittest.main()
