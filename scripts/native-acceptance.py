"""Check all native restart phases and keep PhotoKit evidence separate from VRT."""

import json
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PHASES = {
    "seed",
    "saved",
    "paste-lost",
    "resolve",
    "pasted",
    "revert",
    "original",
    "trash-cancel",
    "trash-native-cancel",
    "trash",
    "trash-lost",
    "trash-inspect",
}


def completed_phases(artifacts):
    log = artifacts / "native.log"
    if not log.exists():
        return Counter()
    return Counter(
        line.removeprefix("PHOTOKIT_PASS ").strip()
        for line in log.read_text().splitlines()
        if line.startswith("PHOTOKIT_PASS ")
    )


def report(artifacts, status, simulator):
    stages = []
    for line in (artifacts / "stages.tsv").read_text().splitlines():
        stage, elapsed, code = line.split("\t")
        stages.append({"stage": stage, "seconds": int(elapsed), "exit_code": int(code)})
    phases = completed_phases(artifacts)
    result = {
        "test_type": "native-photokit",
        "environment": json.loads((ROOT / "VRT/environment.json").read_text()),
        "profile": json.loads((ROOT / "NativeAcceptance/simslim.json").read_text()),
        "simulator": simulator,
        "stages": stages,
        "completed_phases": phases,
        "passed": status == "0" and phases == Counter(dict.fromkeys(PHASES, 1)),
        "scope": "generated JPEG fixtures on the owned simulator; no device or iCloud claim",
    }
    (artifacts / "report.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    operation, directory, *args = sys.argv[1:]
    artifacts = Path(directory)
    if operation == "coverage":
        actual = completed_phases(artifacts)
        if actual != Counter(dict.fromkeys(PHASES, 1)):
            raise SystemExit(f"Incomplete or repeated native phases: {dict(actual)}")
    elif operation == "report":
        report(artifacts, *args)
    else:
        raise SystemExit("Unknown native evidence operation")
