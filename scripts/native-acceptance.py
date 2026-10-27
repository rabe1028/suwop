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
    "metadata-save",
    "metadata-restart",
    "metadata-restore",
    "metadata-description-restart",
    "metadata-final-restart",
    "collections",
    "current-media",
    "import-formats",
    "import-create",
    "import-restart",
    "import-lost",
    "import-lost-restart",
    "trash-cancel",
    "trash-native-cancel",
    "trash",
    "trash-lost",
    "trash-inspect",
    "visibility-hide",
    "visibility-hidden",
    "visibility-restore",
    "product-visibility-hide",
    "product-visibility-hidden",
    "product-visibility-inspect",
    "product-visibility-restore",
}
VISIBILITY_RESULTS = {"unhide-readback", "photos-handoff-required"}


def completed_phases(artifacts):
    log = artifacts / "native.log"
    if not log.exists():
        return Counter()
    return Counter(
        line.removeprefix("PHOTOKIT_PASS ").strip()
        for line in log.read_text().splitlines()
        if line.startswith("PHOTOKIT_PASS ")
    )


def visibility_evidence(artifacts):
    log = artifacts / "native.log"
    if not log.exists():
        return Counter(), Counter()
    lines = log.read_text().splitlines()
    hide = Counter(
        line.removeprefix("PHOTOKIT_VISIBILITY_HIDE ").strip()
        for line in lines
        if line.startswith("PHOTOKIT_VISIBILITY_HIDE ")
    )
    restoration = Counter(
        line.removeprefix("PHOTOKIT_VISIBILITY ").strip()
        for line in lines
        if line.startswith("PHOTOKIT_VISIBILITY ")
    )
    return hide, restoration


def product_visibility_evidence(artifacts):
    log = artifacts / "native.log"
    if not log.exists():
        return Counter(), Counter()
    lines = log.read_text().splitlines()
    hide = Counter(
        line.removeprefix("PHOTOKIT_PRODUCT_VISIBILITY_HIDE ").strip()
        for line in lines
        if line.startswith("PHOTOKIT_PRODUCT_VISIBILITY_HIDE ")
    )
    restoration = Counter(
        line.removeprefix("PHOTOKIT_PRODUCT_VISIBILITY ").strip()
        for line in lines
        if line.startswith("PHOTOKIT_PRODUCT_VISIBILITY ")
    )
    return hide, restoration


def complete_evidence(artifacts):
    hide, restoration = visibility_evidence(artifacts)
    product_hide, product_restoration = product_visibility_evidence(artifacts)
    return (
        completed_phases(artifacts) == Counter(dict.fromkeys(PHASES, 1))
        and hide == Counter({"applied": 1})
        and sum(restoration.values()) == 1
        and set(restoration).issubset(VISIBILITY_RESULTS)
        and product_hide == Counter({"applied": 1})
        and sum(product_restoration.values()) == 1
        and set(product_restoration).issubset(VISIBILITY_RESULTS)
    )


def report(artifacts, status, simulator):
    stages = []
    for line in (artifacts / "stages.tsv").read_text().splitlines():
        stage, elapsed, code = line.split("\t")
        stages.append({"stage": stage, "seconds": int(elapsed), "exit_code": int(code)})
    phases = completed_phases(artifacts)
    hide, restoration = visibility_evidence(artifacts)
    product_hide, product_restoration = product_visibility_evidence(artifacts)
    result = {
        "test_type": "native-photokit",
        "environment": json.loads((ROOT / "VRT/environment.json").read_text()),
        "profile": json.loads((ROOT / "NativeAcceptance/simslim.json").read_text()),
        "simulator": simulator,
        "stages": stages,
        "completed_phases": phases,
        "passed": status == "0" and complete_evidence(artifacts),
        "visibility": {
            "hide_native_outcomes": hide,
            "restoration_results": restoration,
            "native_unhide_verified": restoration == Counter({"unhide-readback": 1}),
            "hidden_original_reverified": restoration == Counter({"unhide-readback": 1}),
            "photos_handoff_required": restoration == Counter({"photos-handoff-required": 1}),
            "product_hide_ui_verified": False,
        },
        "product_visibility": {
            "hide_native_outcomes": product_hide,
            "restoration_results": product_restoration,
            "product_hide_workflow_verified": status == "0" and complete_evidence(artifacts),
            "product_native_unhide_verified": product_restoration
            == Counter({"unhide-readback": 1}),
            "hidden_original_reverified": product_restoration == Counter({"unhide-readback": 1}),
            "photos_handoff_required": product_restoration
            == Counter({"photos-handoff-required": 1}),
            "product_hide_ui_verified": False,
            "confirmation": "host-injected app confirmation; real native changes",
        },
        "scope": "generated JPEG fixtures on the owned simulator; no device or iCloud claim",
    }
    (artifacts / "report.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    operation, directory, *args = sys.argv[1:]
    artifacts = Path(directory)
    if operation == "coverage":
        actual = completed_phases(artifacts)
        if not complete_evidence(artifacts):
            hide, restoration = visibility_evidence(artifacts)
            raise SystemExit(
                f"Incomplete or repeated native evidence: phases={dict(actual)}, "
                f"hide={dict(hide)}, restoration={dict(restoration)}"
            )
    elif operation == "report":
        report(artifacts, *args)
    else:
        raise SystemExit("Unknown native evidence operation")
