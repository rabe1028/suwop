"""Stage simulator test products once; bind and reuse them on other simulator runners."""

import json
import plistlib
import shutil
import sys
from pathlib import Path

import verify
import vrt

KINDS = {"vrt": "DerivedData/VRT", "photokit": "DerivedData/PhotoKit"}
PLATFORM = "Debug-iphonesimulator"
# Static archives, objects and module interfaces are already linked into the bundles.
BUILD_ONLY = ("*.a", "*.o", "*.swiftmodule", "include")
VRT_ENVIRONMENT = ("SUWOP_VRT_ARTIFACTS", "SUWOP_VRT_BASELINES", "SUWOP_VRT_RECORD")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def identity():
    return {
        "schema_version": 1,
        "head": verify.capture(["git", "rev-parse", "HEAD"], vrt.ROOT),
        "source": verify.fingerprint(vrt.ROOT),
        "environment": vrt.CONFIG,
    }


def xctestrun(folder):
    runs = sorted(folder.glob("*.xctestrun"))
    require(len(runs) == 1, f"Expected one xctestrun in {folder}")
    return runs[0]


def stage(output):
    """Copy only what test-without-building needs and bind it to this checkout."""
    require(not output.exists() or not any(output.iterdir()), "Product output must be empty")
    for kind, derived in KINDS.items():
        products = vrt.ROOT / derived / "Build/Products"
        target = output / kind
        target.mkdir(parents=True)
        shutil.copy2(xctestrun(products), target)
        shutil.copytree(
            products / PLATFORM,
            target / PLATFORM,
            symlinks=True,
            ignore=shutil.ignore_patterns(*BUILD_ONLY),
        )
    (output / "manifest.json").write_text(json.dumps(identity(), indent=2) + "\n")


def bound(products, kind):
    manifest = json.loads((products / "manifest.json").read_text())
    require(manifest == identity(), "Products were built from another source or environment")
    require(kind in KINDS, "Unknown product kind")
    return products / kind


def prepare_vrt(products, artifacts):
    """Point the prebuilt VRT run at this lane's baselines and artifacts; never record."""
    path = xctestrun(bound(products, "vrt"))
    run = plistlib.loads(path.read_bytes())
    targets = [value for key, value in run.items() if not key.startswith("__")]
    require(targets, "xctestrun has no test targets")
    values = {
        "SUWOP_VRT_ARTIFACTS": str(artifacts),
        "SUWOP_VRT_BASELINES": str(vrt.BASELINES),
        "SUWOP_VRT_RECORD": "0",
    }
    for target in targets:
        environment = target.get("EnvironmentVariables", {})
        require(set(VRT_ENVIRONMENT) <= set(environment), "xctestrun lacks the VRT environment")
        environment.update(values)
    path.write_bytes(plistlib.dumps(run))
    return path


def prepare_photokit(products):
    folder = bound(products, "photokit")
    app = folder / PLATFORM / "SuwopPhotoKitHost.app"
    require(app.is_dir(), "Missing PhotoKit host app")
    return xctestrun(folder), app


def main():
    operation, *args = sys.argv[1:]
    if operation == "stage":
        stage(Path(args[0]))
    elif operation == "prepare-vrt":
        print(prepare_vrt(Path(args[0]), Path(args[1])))
    elif operation == "prepare-photokit":
        print("\n".join(str(path) for path in prepare_photokit(Path(args[0]))))
    else:
        raise ValueError("Usage: simulator_products.py stage|prepare-vrt|prepare-photokit")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException) as error:
        sys.exit(str(error))
