#!/usr/bin/env -S uv run --no-project python
"""Summarize local Suwop traces, with optional user-visible latency gates."""

import argparse
import json
import math
from pathlib import Path


def summarize(path):
    document = json.loads(Path(path).read_text())
    phases = {}
    for event in document["traceEvents"]:
        if event.get("ph") == "X":
            phases.setdefault(event["name"], []).append(event["dur"] / 1000)
    result = {"dropped_events": document.get("droppedEvents", 0), "phases": {}}
    for name, values in sorted(phases.items()):
        ordered = sorted(values)
        result["phases"][name] = {
            "count": len(values),
            "p50_ms": ordered[math.ceil(len(values) * 0.50) - 1],
            "p95_ms": ordered[math.ceil(len(values) * 0.95) - 1],
            "max_ms": max(values),
            "over_100ms": sum(value > 100 for value in values),
        }
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace")
    parser.add_argument("--before")
    parser.add_argument("--max-ui-delay-p95-ms", type=float)
    parser.add_argument("--max-preview-p95-ms", type=float)
    parser.add_argument("--max-preview-request-p95-ms", type=float)
    args = parser.parse_args()
    after = summarize(args.trace)
    report = {"after": after}
    if args.before:
        report["before"] = summarize(args.before)
    failures = []
    for name, limit in [
        ("mainActorDelay", args.max_ui_delay_p95_ms),
        ("previewImage", args.max_preview_p95_ms),
        ("previewRequest", args.max_preview_request_p95_ms),
    ]:
        if limit is not None:
            observed = after["phases"].get(name)
            if observed is None or observed["p95_ms"] > limit:
                failures.append(f"{name}: missing samples or p95 exceeds {limit} ms")
    if after["dropped_events"]:
        failures.append("Trace was truncated; repeat with a shorter scenario")
    report["failures"] = failures
    print(json.dumps(report, indent=2))
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
