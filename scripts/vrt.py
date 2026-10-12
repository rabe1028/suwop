"""Validate the pinned VRT environment and screenshot manifest, without process execution."""

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = json.loads((ROOT / "VRT/environment.json").read_text())
BASELINES = ROOT / "VRT/Baselines"
SCREENS = {
    "gallery-empty",
    "gallery-empty-dark",
    "gallery-empty-large-text",
    "gallery",
    "gallery-dark",
    "selection",
    "viewer",
    "photo-info",
    "albums",
    "connection",
    "transfers",
    "trash-empty",
    "trash-cached",
    "trash-pending",
    "editor",
    "editor-large-text",
    "editor-large-text-bottom",
    "editor-adjusted",
    "edit-copy",
    "edit-copy-dark",
    "edit-copy-large-text",
    "edit-paste-pending",
    "edit-paste-pending-large-text",
}


def hashes():
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in BASELINES.glob("*.png")}


def device():
    inventory = json.load(sys.stdin)
    runtime = next((r for r in inventory["runtimes"] if r["identifier"] == CONFIG["runtime"]), None)
    if (
        not runtime
        or not runtime["isAvailable"]
        or runtime["version"] != CONFIG["runtime_version"]
        or runtime["buildversion"] != CONFIG["runtime_build"]
    ):
        raise SystemExit("Pinned iOS runtime missing or changed. No comparison was run.")
    name = "Suwop VRT " + hashlib.sha256(str(ROOT).encode()).hexdigest()[:12]
    owned = [d for d in inventory["devices"].get(CONFIG["runtime"], []) if d["name"] == name]
    if len(owned) > 1:
        raise SystemExit("Duplicate VRT simulators; resolve before running.")
    if owned and (
        not owned[0]["isAvailable"] or owned[0]["deviceTypeIdentifier"] != CONFIG["device"]
    ):
        raise SystemExit("Owned simulator no longer matches the pinned device.")
    print(owned[0]["udid"] if owned else "")


def finish(artifacts, record, passed, udid):
    stages = []
    for line in (artifacts / "stages.tsv").read_text().splitlines():
        stage, elapsed, code = line.split("\t")
        stages.append({"stage": stage, "seconds": int(elapsed), "exit_code": int(code)})
    report = {
        "environment": CONFIG,
        "simulator": udid,
        "record": record == "1",
        "stages": stages,
        "passed": passed == "1",
        "baseline_sha256": hashes(),
    }
    (artifacts / "report.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    args = sys.argv[1:]
    operation = args[0]
    if operation == "config":
        print(CONFIG[args[1]])
    elif operation == "name":
        print("Suwop VRT " + hashlib.sha256(str(ROOT).encode()).hexdigest()[:12])
    elif operation == "device":
        device()
    elif operation == "baseline-check":
        if set(hashes()) != {name + ".png" for name in SCREENS}:
            raise SystemExit("Missing or unexpected baselines. Review and record explicitly.")
    elif operation == "hashes":
        print(json.dumps(hashes(), sort_keys=True))
    elif operation == "coverage":
        actual = {p.name.removesuffix("-actual.png") for p in Path(args[1]).glob("*-actual.png")}
        if actual != SCREENS:
            raise SystemExit(f"Incomplete screenshot coverage: {actual ^ SCREENS}")
    elif operation == "report":
        finish(Path(args[1]), *args[2:])
    else:
        raise SystemExit("Unknown VRT manifest operation")
