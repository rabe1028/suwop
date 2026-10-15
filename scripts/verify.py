#!/usr/bin/env python3
"""Run checks with complete disk logs and compact, source-bound JSON evidence."""

import argparse
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def capture(argv, cwd):
    return subprocess.check_output(argv, cwd=cwd).decode().strip()  # noqa: S603


def fingerprint(root):
    names = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],  # noqa: S607
        cwd=root,
    ).split(b"\0")
    digest = hashlib.sha256()
    for name in sorted(set(names) - {b""}):
        path = root / os.fsdecode(name)
        digest.update(name + b"\0")
        if path.is_symlink():
            digest.update(b"link:" + os.fsencode(os.readlink(path)))
        elif path.is_file():
            digest.update(str(path.stat().st_mode).encode())
            with path.open("rb") as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(chunk)
        else:
            digest.update(b"missing")
        digest.update(b"\0")
    return digest.hexdigest()


def write_report(path, report):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def run_check(root, label, command):
    directory = root / ".tools" / "verification"
    directory.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix=label + "-", dir=directory))
    report_path = output / "result.json"
    before = fingerprint(root)
    report = {
        "status": "running",
        "cwd": str(root),
        "head": capture(["git", "rev-parse", "HEAD"], root),
        "source_before": before,
        "command": command,
        "environment": {
            key: os.environ[key]
            for key in (
                "DEVELOPER_DIR",
                "CARGO_BUILD_JOBS",
                "CARGO_INCREMENTAL",
                "CARGO_PROFILE_DEV_DEBUG",
                "CARGO_PROFILE_TEST_DEBUG",
                "SUWOP_CLEAN_CHECK",
            )
            if key in os.environ
        },
        "log": str(output / "output.log"),
        "report": str(report_path),
    }
    write_report(report_path, report)
    print(json.dumps({"status": "running", "report": str(report_path)}), flush=True)
    started = time.monotonic()
    with (output / "output.log").open("wb") as log:
        try:
            process = subprocess.Popen(  # noqa: S603
                command, cwd=root, stdout=log, stderr=subprocess.STDOUT, start_new_session=True
            )
        except OSError as error:
            log.write(str(error).encode())
            code = 127
        else:
            try:
                code = process.wait()
            except KeyboardInterrupt:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                code = 130
    after = fingerprint(root)
    status = "passed" if code == 0 and before == after else "failed" if code else "source_changed"
    report.update(
        status=status,
        exit_code=code,
        source_after=after,
        elapsed_seconds=round(time.monotonic() - started, 2),
    )
    write_report(report_path, report)
    print(json.dumps(report, ensure_ascii=False))
    if status != "passed":
        # Bound both bytes and lines; the complete raw output stays on disk.
        with (output / "output.log").open("rb") as log:
            log.seek(max(0, log.seek(0, 2) - 6000))
            print(log.read().decode(errors="replace").splitlines()[-30:])
    return code if code > 0 else 128 - code if code < 0 else 0 if before == after else 3


def ci_summary(root, run_id, expected_head):
    data = json.loads(
        capture(
            [
                "gh",
                "run",
                "view",
                run_id,
                "--json",
                "databaseId,headSha,status,conclusion,jobs,url",
            ],
            root,
        )
    )
    result = {key: value for key, value in data.items() if key != "jobs"}
    result["jobs"] = [
        {key: job[key] for key in ("databaseId", "name", "status", "conclusion")}
        for job in data["jobs"]
    ]
    result["head_matches"] = data["headSha"] == expected_head
    print(json.dumps(result, ensure_ascii=False))
    if not result["head_matches"]:
        return 3
    if data["status"] != "completed":
        return 2
    return 0 if data["conclusion"] == "success" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="mode", required=True)
    run = commands.add_parser("run")
    run.add_argument("--label", required=True)
    run.add_argument("command", nargs=argparse.REMAINDER)
    ci = commands.add_parser("ci")
    ci.add_argument("run_id")
    ci.add_argument("--expected-head", required=True)
    args = parser.parse_args()
    root = Path(capture(["git", "rev-parse", "--show-toplevel"], Path.cwd()))
    if args.mode == "ci":
        if not args.run_id.isdecimal() or not re.fullmatch(r"[a-f0-9]{40}", args.expected_head):
            parser.error("ci requires a numeric run ID and full expected commit SHA")
        return ci_summary(root, args.run_id, args.expected_head)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not re.fullmatch(r"[a-zA-Z0-9_-]+", args.label) or not command:
        parser.error("run requires a simple label and a command after --")
    return run_check(root, args.label, command)


if __name__ == "__main__":
    sys.exit(main())
