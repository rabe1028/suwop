"""Reject incomplete, stale, or modified CI libraries before packaging."""

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import apple_slices


class AppleSlicesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for target in apple_slices.TARGETS:
            folder = self.root / target
            folder.mkdir()
            (folder / "libsuwop_ffi.a").write_bytes(target.encode())
            apple_slices.stamp(self.root, target, "current")

    def test_complete_current_set_is_accepted(self):
        apple_slices.verify(self.root, "current")

    def test_missing_target_is_rejected(self):
        (self.root / apple_slices.TARGETS[-1] / "libsuwop_ffi.a").unlink()
        with self.assertRaisesRegex(ValueError, "Missing release"):
            apple_slices.verify(self.root, "current")

    def test_modified_library_is_rejected(self):
        (self.root / apple_slices.TARGETS[0] / "libsuwop_ffi.a").write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "does not match"):
            apple_slices.verify(self.root, "current")

    def test_stale_revision_and_wrong_target_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "does not match"):
            apple_slices.verify(self.root, "new-source")
        manifest = self.root / apple_slices.TARGETS[0] / "manifest.json"
        value = json.loads(manifest.read_text())
        value["target"] = apple_slices.TARGETS[1]
        manifest.write_text(json.dumps(value))
        with self.assertRaisesRegex(ValueError, "does not match"):
            apple_slices.verify(self.root, "current")

    def test_dirty_checkout_is_rejected(self):
        with (
            patch("apple_slices.subprocess.check_output", return_value=" M Cargo.lock"),
            self.assertRaisesRegex(ValueError, "clean source"),
        ):
            apple_slices.revision()

    def test_clean_checkout_and_target_allowlist(self):
        with patch("apple_slices.subprocess.check_output", side_effect=["", "commit\n"]):
            self.assertEqual(apple_slices.revision(), "commit")
        with self.assertRaisesRegex(ValueError, "Unsupported"):
            apple_slices.stamp(self.root, "../unknown", "current")


if __name__ == "__main__":
    unittest.main()
