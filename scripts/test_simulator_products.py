"""Prebuilt simulator products: runtime-only staging, source binding and lane environment."""

import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import simulator_products as products

IDENTITY = {"schema_version": 1, "head": "a" * 40, "source": "b" * 64, "environment": {}}


def built(root, kind, environment):
    folder = root / products.KINDS[kind] / "Build/Products"
    platform = folder / products.PLATFORM
    for path in (
        "Host.app/Host",
        "SuwopPhotoKitHost.app/SuwopPhotoKitHost",
        "Runner.app/Runner",
        "Lib.framework/Lib",
        "PackageFrameworks/P.framework/P",
        "libsuwop_ffi.a",
        "SuwopShell.o",
        "SuwopShell.swiftmodule/arm64.swiftmodule",
        "include/suwop.h",
    ):
        (platform / path).parent.mkdir(parents=True, exist_ok=True)
        (platform / path).write_text(path)
    (platform / "Host.app/Host").chmod(0o755)
    run = {
        "__xctestrun_metadata__": {"FormatVersion": 1},
        "Tests": {"EnvironmentVariables": dict(environment), "TestHostPath": "__TESTROOT__/x"},
        "UITests": {"EnvironmentVariables": dict(environment)},
    }
    (folder / f"Suwop_{kind}.xctestrun").write_bytes(plistlib.dumps(run))


class ProductTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.output = self.root / "products"
        unbound = dict.fromkeys(products.VRT_ENVIRONMENT, "unbound")
        built(self.root, "vrt", {**unbound, "TZ": "UTC"})
        built(self.root, "photokit", {})
        patches = (
            patch.object(products.vrt, "ROOT", self.root),
            patch.object(products.vrt, "BASELINES", self.root / "VRT/Baselines"),
            patch.object(products, "identity", lambda: dict(IDENTITY)),
        )
        for active in patches:
            active.start()
            self.addCleanup(active.stop)

    def tearDown(self):
        self.temp.cleanup()

    def test_stage_keeps_runtime_bundles_and_drops_build_only_outputs(self):
        products.stage(self.output)
        staged = {
            p.relative_to(self.output / "vrt").as_posix() for p in (self.output / "vrt").rglob("*")
        }
        self.assertIn("Debug-iphonesimulator/Host.app/Host", staged)
        self.assertIn("Debug-iphonesimulator/PackageFrameworks/P.framework/P", staged)
        self.assertIn("Suwop_vrt.xctestrun", staged)
        self.assertFalse(any(Path(p).suffix in {".a", ".o", ".swiftmodule"} for p in staged))
        self.assertFalse(any(p.startswith("Debug-iphonesimulator/include") for p in staged))
        host = self.output / "vrt/Debug-iphonesimulator/Host.app/Host"
        self.assertTrue(host.stat().st_mode & 0o100)
        with self.assertRaisesRegex(ValueError, "empty"):
            products.stage(self.output)

    def test_vrt_lane_environment_replaces_build_values_and_never_records(self):
        products.stage(self.output)
        artifacts = self.root / "artifacts"
        run = plistlib.loads(products.prepare_vrt(self.output, artifacts).read_bytes())
        for target in ("Tests", "UITests"):
            environment = run[target]["EnvironmentVariables"]
            self.assertEqual(environment["SUWOP_VRT_ARTIFACTS"], str(artifacts))
            self.assertEqual(environment["SUWOP_VRT_BASELINES"], str(self.root / "VRT/Baselines"))
            self.assertEqual(environment["SUWOP_VRT_RECORD"], "0")
        self.assertEqual(run["Tests"]["EnvironmentVariables"]["TZ"], "UTC")
        self.assertEqual(run["Tests"]["TestHostPath"], "__TESTROOT__/x")

    def test_products_from_another_source_or_without_vrt_environment_are_rejected(self):
        products.stage(self.output)
        with patch.object(products, "identity", lambda: {**IDENTITY, "head": "c" * 40}):
            with self.assertRaisesRegex(ValueError, "another source"):
                products.prepare_vrt(self.output, self.root / "artifacts")
            with self.assertRaisesRegex(ValueError, "another source"):
                products.prepare_photokit(self.output)
        path = products.xctestrun(self.output / "vrt")
        run = plistlib.loads(path.read_bytes())
        del run["UITests"]["EnvironmentVariables"]["SUWOP_VRT_ARTIFACTS"]
        path.write_bytes(plistlib.dumps(run))
        with self.assertRaisesRegex(ValueError, "lacks the VRT environment"):
            products.prepare_vrt(self.output, self.root / "artifacts")

    def test_photokit_products_name_the_installed_host_app(self):
        products.stage(self.output)
        run, app = products.prepare_photokit(self.output)
        self.assertEqual(run.name, "Suwop_photokit.xctestrun")
        self.assertEqual(app.name, "SuwopPhotoKitHost.app")


if __name__ == "__main__":
    unittest.main()
