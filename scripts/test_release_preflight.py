import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from release_preflight import inspect_bundle


class ReleasePreflightTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.app = self.root / "Generated.app"
        self.app.mkdir()
        self.info = {
            "CFBundleIdentifier": "jp.test.generated",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "2",
            "CFBundleExecutable": "Generated",
            "DTPlatformName": "iphonesimulator",
            "NSPhotoLibraryUsageDescription": "Generated test library",
            "NSPhotoLibraryAddUsageDescription": "Generated test import",
        }
        self.write_info()
        (self.app / "Generated").write_bytes(b"generated-executable")
        (self.app / "Generated").chmod(0o755)

    def write_info(self):
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))

    def test_valid_bundle_hash_is_deterministic_and_never_claims_distribution(self):
        first = inspect_bundle(self.app)
        copied = self.root / "Copied.app"
        shutil.copytree(self.app, copied)
        second = inspect_bundle(copied)
        self.assertTrue(first["checks_passed"])
        self.assertFalse(first["distribution_ready"])
        self.assertEqual(first["bundle_sha256"], second["bundle_sha256"])
        (copied / "Generated").write_bytes(b"changed")
        self.assertNotEqual(first["bundle_sha256"], inspect_bundle(copied)["bundle_sha256"])

    def test_missing_usage_and_resource_fail(self):
        del self.info["NSPhotoLibraryUsageDescription"]
        self.write_info()
        result = inspect_bundle(self.app, ["missing-resource"])
        self.assertFalse(result["checks_passed"])
        self.assertEqual(len(result["errors"]), 2)

    def test_executable_traversal_and_external_symlink_fail(self):
        self.info["CFBundleExecutable"] = "../outside"
        self.write_info()
        self.assertFalse(inspect_bundle(self.app)["checks_passed"])
        self.info["CFBundleExecutable"] = "Generated"
        self.write_info()
        (self.app / "Generated").unlink()
        (self.root / "outside").write_bytes(b"outside")
        (self.app / "Generated").symlink_to(self.root / "outside")
        self.assertFalse(inspect_bundle(self.app)["checks_passed"])

    def test_arbitrary_external_bundle_symlink_and_resource_traversal_fail(self):
        (self.app / "escaped-resource").symlink_to(self.root / "not-in-app")
        self.assertFalse(inspect_bundle(self.app)["checks_passed"])
        (self.app / "escaped-resource").unlink()
        self.assertFalse(inspect_bundle(self.app, ["../outside"])["checks_passed"])

    def test_missing_executable_mode_or_platform_fail(self):
        (self.app / "Generated").chmod(0o644)
        del self.info["DTPlatformName"]
        self.write_info()
        result = inspect_bundle(self.app)
        self.assertFalse(result["checks_passed"])
        self.assertEqual(len(result["errors"]), 2)

    def test_macos_layout(self):
        contents = self.app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (self.app / "Generated").rename(contents / "MacOS/Generated")
        self.info["DTPlatformName"] = "macosx"
        (self.app / "Info.plist").unlink()
        (contents / "Info.plist").write_bytes(plistlib.dumps(self.info))
        self.assertTrue(inspect_bundle(self.app)["checks_passed"])

    @patch("release_preflight.shutil.which", return_value="/test/codesign")
    @patch("release_preflight.subprocess.run")
    def test_optional_signature_is_read_only_and_ad_hoc_is_not_distribution(self, run, _which):
        run.side_effect = [
            subprocess.CompletedProcess([], 0, b"", b""),
            subprocess.CompletedProcess([], 0, b"", b"Signature=adhoc\n"),
        ]
        result = inspect_bundle(self.app, check_signature=True)
        self.assertEqual(result["signature"], {"state": "ad-hoc", "verified": True})
        self.assertTrue(result["checks_passed"])
        self.assertFalse(result["distribution_ready"])
        self.assertEqual(run.call_args_list[0].args[0][1:4], ["--verify", "--deep", "--strict"])
        self.assertEqual(run.call_args_list[1].args[0][1:3], ["--display", "--verbose=2"])

    @patch("release_preflight.shutil.which", return_value=None)
    def test_requested_missing_signature_tool_does_not_pass(self, _which):
        self.assertFalse(inspect_bundle(self.app, check_signature=True)["checks_passed"])


if __name__ == "__main__":
    unittest.main()
