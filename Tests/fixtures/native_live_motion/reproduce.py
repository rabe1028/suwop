#!/usr/bin/env -S uv run --no-project python
"""Compile/generate/independently verify into fresh artifacts; never write Photos."""

import argparse
import json
import os
import shutil
import signal
import subprocess
import tempfile
import time
from pathlib import Path


def signal_group(group, requested):
    try:
        os.killpg(group, requested)
        return True
    except ProcessLookupError:
        return False


def group_present(group):
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False


def wait_group_absent(process, seconds):
    deadline = time.monotonic() + seconds
    while True:
        process.poll()  # Reap the leader; its exit alone does not prove descendant drainage.
        if not group_present(process.pid):
            return True
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(0.02, remaining))


def terminate_group(process):
    observation = {"termSent": signal_group(process.pid, signal.SIGTERM)}
    drained = wait_group_absent(process, 3)
    observation["killSent"] = False
    if not drained:
        # Signal the group even when the already-reaped leader exited after TERM.
        observation["killSent"] = signal_group(process.pid, signal.SIGKILL)
        drained = wait_group_absent(process, 3)
    observation.update({"groupAbsent": drained, "leaderReturnCode": process.poll()})
    return observation


def run_step(command, label, output, deadline):
    """Finite execution budget plus at most six seconds of group termination."""
    timeout = min(60, deadline - time.monotonic())
    if timeout <= 0:
        raise RuntimeError("Overall 180-second execution budget expired")
    started = time.monotonic()
    termination = None
    with (
        (output / f"{label}.log").open("wb") as log,
        (output / f"{label}-stderr.log").open("wb") as errors,
    ):
        # Call sites supply only fixed xcodebuild/xcrun or this run's freshly compiled tools.
        # User paths are individual argv elements; no shell or user-selected executable.
        process = subprocess.Popen(  # noqa: S603
            command, stdout=log, stderr=errors, start_new_session=True
        )
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            code = 124
            try:
                termination = terminate_group(process)
            except OSError as error:
                termination = {"groupAbsent": False, "terminationError": str(error)}
    result = {
        "label": label,
        "command": command,
        "exitCode": code,
        "elapsedSeconds": time.monotonic() - started,
        "termination": termination,
    }
    # Timeout results are retained even if the leader exited early or group drainage failed.
    (output / f"{label}-result.json").write_text(json.dumps(result, indent=2) + "\n")
    if code:
        raise RuntimeError(f"{label} failed with {code}; inspect {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="New nonexistent output directory")
    parser.add_argument("--verify-only", type=Path, help="Existing pair directory; do not generate")
    args = parser.parse_args()
    output = args.output
    if output is None:
        output = Path(tempfile.mkdtemp(prefix="suwop-native-live-motion-"))
    else:
        output = output.expanduser().resolve()
        output.mkdir(parents=False, exist_ok=False)
    print(output, flush=True)
    source = Path(__file__).resolve().parent
    snapshot = output / "sources"
    snapshot.mkdir()
    for name in ["Generate.swift", "Pattern.swift", "Verify.swift", "reproduce.py", "README.md"]:
        shutil.copy2(source / name, snapshot / name)
    deadline = time.monotonic() + 180
    try:
        run_step(["xcodebuild", "-version"], "xcode-version", output, deadline)
        run_step(["xcrun", "swiftc", "--version"], "swift-version", output, deadline)
        flags = [
            "xcrun",
            "swiftc",
            "-swift-version",
            "6",
            "-strict-concurrency=complete",
            "-warnings-as-errors",
            "-parse-as-library",
        ]
        verifier = output / "verify"
        run_step(
            [*flags, str(snapshot / "Verify.swift"), "-o", str(verifier)],
            "compile-verifier",
            output,
            deadline,
        )
        media = args.verify_only.expanduser().resolve() if args.verify_only else output / "media"
        if args.verify_only is None:
            generator = output / "generate"
            run_step(
                [
                    *flags,
                    str(snapshot / "Generate.swift"),
                    str(snapshot / "Pattern.swift"),
                    "-o",
                    str(generator),
                ],
                "compile-generator",
                output,
                deadline,
            )
            run_step([str(generator), str(media)], "generate", output, deadline)
        run_step([str(verifier), str(media)], "verify", output, deadline)
        # Only the independently verified actual files produce a runtime manifest.
        verification = json.loads((output / "verify.log").read_text())
        (output / "fixture-validation.json").write_text(json.dumps(verification, indent=2) + "\n")
        (output / "result.json").write_text(
            json.dumps(
                {
                    "passed": True,
                    "fixtureOnly": True,
                    "mediaDirectory": str(media),
                    "scope": "No PHLivePhotoView or physical-device motion acceptance",
                },
                indent=2,
            )
            + "\n"
        )
    except Exception as error:
        (output / "result.json").write_text(
            json.dumps({"passed": False, "error": str(error)}, indent=2) + "\n"
        )
        raise


if __name__ == "__main__":
    main()
