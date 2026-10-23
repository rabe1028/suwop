"""Source-bound partial VRT lane reports; only their exact union is complete CI VRT."""

import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import verify
import vrt
from vrt_test_inventory import (
    enumerate_inventory,
    executed_inventory,
    registered_inventory,
    require,
)

UI_SHARDS = 3
SCOPES = {
    "host-snapshots": "SuwopVRT",
    **{f"ui-{index}": "SuwopVRTUI" for index in range(1, UI_SHARDS + 1)},
}
DURATIONS = vrt.ROOT / "VRT/ui-test-durations.json"
STAGES = {
    "begin",
    "slim",
    "verify-profile",
    "memory",
    "products",
    "enumerate",
    "inventory",
    "select",
    "compare",
    "test-inventory",
    "test-summary",
    "lane-validation",
}


def read(path):
    return json.loads(path.read_text())


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def identity(root):
    head = verify.capture(["git", "rev-parse", "HEAD"], root)
    expected = os.environ.get("GITHUB_SHA", head)
    require(head == expected, "Checkout does not match requested CI head")
    return {
        "head": head,
        "source": verify.fingerprint(root),
        "run_id": os.environ.get("GITHUB_RUN_ID", "local"),
        "attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "local"),
        "environment": vrt.CONFIG,
        "profile_sha256": hashlib.sha256((root / "VRT/simslim.json").read_bytes()).hexdigest(),
        "comparator_sha256": hashlib.sha256(
            (root / "VRT/Tests/SnapshotComparison.swift").read_bytes()
        ).hexdigest(),
        "baselines": vrt.hashes(),
    }


def durations():
    data = read(DURATIONS)
    require(data.get("schema_version") == 1, "Unknown UI duration schema")
    seconds = data["seconds"]
    require(
        seconds and all(isinstance(v, int) and v > 0 for v in seconds.values()),
        "Invalid UI durations",
    )
    return seconds


def selection(registered, scope):
    """Deterministic longest-first UI shards; the host lane selects its whole bundle."""
    require(scope in SCOPES, "Unknown lane")
    tests = registered[SCOPES[scope]]
    if scope == "host-snapshots":
        return tests
    seconds = durations()
    # Unmeasured new tests count as a typical test until durations are refreshed.
    default = sorted(seconds.values())[len(seconds) // 2]
    loads = [0] * UI_SHARDS
    shards = [[] for _ in range(UI_SHARDS)]
    for test in sorted(tests, key=lambda test: (-seconds.get(test, default), test)):
        index = min(range(UI_SHARDS), key=lambda index: (loads[index], index))
        loads[index] += seconds.get(test, default)
        shards[index].append(test)
    selected = sorted(shards[int(scope.removeprefix("ui-")) - 1])
    require(selected, "Empty UI shard")
    return selected


def only_testing(registered, scope):
    if scope == "host-snapshots":
        return [SCOPES[scope]]
    return selection(registered, scope)


def validate_stages(values, *, final):
    names = [value[0] for value in values]
    expected = STAGES if final else STAGES - {"lane-validation"}
    require(len(names) == len(set(names)) and set(names) == expected, "Missing/duplicate stages")
    require(all(len(value) == 3 and value[2] == "0" for value in values), "A stage failed")
    return values


def stages(artifacts, *, final):
    values = [line.split("\t") for line in (artifacts / "stages.tsv").read_text().splitlines()]
    return validate_stages(values, final=final)


def validate_lane(artifacts, scope, before, after):
    require(scope in SCOPES, "Unknown lane")
    require(before == after, "Source/environment/baselines changed during lane")
    require(
        set(before["baselines"]) == {name + ".png" for name in vrt.SCREENS}, "Baseline set changed"
    )
    registered = registered_inventory(read(artifacts / "registered-tests.json"))
    actual = executed_inventory(
        read(artifacts / "test-inventory.log"), read(artifacts / "test-summary.log"), vrt.CONFIG
    )
    require(
        actual == {SCOPES[scope]: selection(registered, scope)},
        "Executed IDs differ from the complete lane selection",
    )
    captures = {p.name.removesuffix("-actual.png") for p in artifacts.glob("*-actual.png")}
    require(
        captures == (vrt.SCREENS if scope == "host-snapshots" else set()), "Wrong screen coverage"
    )
    require(not list(artifacts.glob("*-diff.png")), "Snapshot differences exist")
    return {"registered": registered, "executed": actual, "screens": sorted(captures)}


def complete(root, artifacts, scope, status, passed):
    result = {
        "schema_version": 1,
        "scope": scope,
        "full_suite_passed": False,
        "record": False,
        "lane_passed": False,
    }
    try:
        require(status == "0" and passed == "1", "Lane did not finish successfully")
        before = read(artifacts / "before.json")
        result["identity"] = before
        result["evidence"] = validate_lane(artifacts, scope, before, identity(root))
        result["stages"] = stages(artifacts, final=True)
        # Shell includes owned-device shutdown in status before calling this function.
        require((artifacts / "shutdown.log").exists(), "Missing owned shutdown evidence")
        result["lane_passed"] = True
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        result["error"] = str(error)
    write(artifacts / "lane-report.json", result)
    return 0 if result["lane_passed"] else 1


def aggregate(reports, head, run_id, attempt, matrix_result):
    require(matrix_result == "success", "Screenshot/UI/PhotoKit matrix did not succeed")
    require(len(reports) == len(SCOPES), "Missing/duplicate VRT lanes")
    by_scope = {}
    for report in reports:
        scope = report.get("scope")
        require(scope in SCOPES and scope not in by_scope, "Unknown/duplicate lane")
        require(
            report.get("schema_version") == 1
            and report.get("lane_passed") is True
            and report.get("full_suite_passed") is False
            and report.get("record") is False,
            "Not a successful explicitly partial lane",
        )
        validate_stages(report.get("stages", []), final=True)
        bound = report["identity"]
        require(
            (bound["head"], bound["run_id"], bound["attempt"]) == (head, run_id, attempt),
            "Stale head/run/attempt",
        )
        require(
            set(bound["baselines"]) == {name + ".png" for name in vrt.SCREENS},
            "Baseline set differs",
        )
        evidence = report["evidence"]
        registered = registered_inventory({"schema_version": 1, "bundles": evidence["registered"]})
        require(
            evidence["executed"] == {SCOPES[scope]: selection(registered, scope)}, "Wrong lane IDs"
        )
        require(
            evidence["screens"] == sorted(vrt.SCREENS if scope == "host-snapshots" else []),
            "Wrong aggregate screenshot coverage",
        )
        by_scope[scope] = report
    host = by_scope["host-snapshots"]
    executed_ui = []
    for scope, report in by_scope.items():
        require(
            host["identity"] == report["identity"],
            "Lane source/environment/baseline identity differs",
        )
        require(
            host["evidence"]["registered"] == report["evidence"]["registered"],
            "Full registered inventories differ",
        )
        if scope != "host-snapshots":
            executed_ui += report["evidence"]["executed"]["SuwopVRTUI"]
    require(
        sorted(executed_ui) == host["evidence"]["registered"]["SuwopVRTUI"],
        "UI shards are not an exact partition of the registered UI bundle",
    )
    return {
        "schema_version": 1,
        "scope": "complete-ci-vrt",
        "passed": True,
        "record": False,
        "identity": host["identity"],
        "registered": host["evidence"]["registered"],
        "screens": host["evidence"]["screens"],
        "photokit": "Required separately by successful simulator matrix; native gate unchanged",
        "required_matrix_result": matrix_result,
    }


def main():
    operation, *args = sys.argv[1:]
    root = vrt.ROOT
    if operation == "begin":
        write(Path(args[0]) / "before.json", identity(root))
    elif operation == "inventory":
        write(
            Path(args[1]),
            {"schema_version": 1, "bundles": enumerate_inventory(read(Path(args[0])))},
        )
    elif operation == "durations":
        # Refresh shard balance from completed lanes' compare.log files.
        seconds = {}
        for log in args:
            for match in re.finditer(
                r"Test Case '-\[SuwopVRTUI\.(\w+) (\w+)\]' passed \(([0-9.]+) seconds\)",
                Path(log).read_text(),
            ):
                seconds[f"SuwopVRTUI/{match[1]}/{match[2]}"] = max(1, round(float(match[3])))
        require(seconds, "No passed UI test durations")
        write(DURATIONS, {"schema_version": 1, "seconds": dict(sorted(seconds.items()))})
    elif operation == "select":
        artifacts, scope = Path(args[0]), args[1]
        registered = registered_inventory(read(artifacts / "registered-tests.json"))
        (artifacts / "only-testing.txt").write_text(
            "".join(f"{item}\n" for item in only_testing(registered, scope))
        )
    elif operation == "validate":
        artifacts, scope = Path(args[0]), args[1]
        stages(artifacts, final=False)
        write(
            artifacts / "validation.json",
            validate_lane(artifacts, scope, read(artifacts / "before.json"), identity(root)),
        )
    elif operation == "report":
        return complete(root, Path(args[0]), *args[1:])
    elif operation == "aggregate":
        directory, head, run_id, attempt, matrix_result = args
        (Path(directory) / "aggregate.json").unlink(missing_ok=True)
        reports = []
        for path in Path(directory).rglob("lane-report.json"):
            report = read(path)
            artifacts = path.parent
            require(
                report.get("identity") == identity(root), "Artifact differs from aggregate checkout"
            )
            evidence = validate_lane(
                artifacts, report["scope"], read(artifacts / "before.json"), report["identity"]
            )
            require(evidence == report.get("evidence"), "Report differs from raw completed result")
            require(stages(artifacts, final=True) == report.get("stages"), "Reported stages differ")
            require((artifacts / "shutdown.log").exists(), "Missing shutdown evidence")
            reports.append(report)
        write(
            Path(directory) / "aggregate.json",
            aggregate(reports, head, run_id, attempt, matrix_result),
        )
    else:
        raise ValueError("Unknown VRT lane operation")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
