"""Exhaustively check the finite transfer model and its counterexample controls."""

import contextlib
import hashlib
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODEL = ROOT / "formal/transfer_lifecycle.qnt"
OVERLAP_MODEL = ROOT / "formal/overlapping_moves.qnt"
CONFIG = ROOT / "formal/tlc.json"
QUINT_VERSION = "0.33.0"
APALACHE_VERSION = "0.62.1"
CONTROLS = (
    ("unsafePersistStep", "durableBeforeDeletion"),
    ("unsafeCopyStep", "noCopyDeletion"),
    ("unsafeRetryStep", "noDeletionRetry"),
    ("unsafeVerificationStep", "copiedRequiresOriginals"),
    ("unsafeAuthorityStep", "authorizedBeforeDeletion"),
    ("unsafeRollbackStep", "noDeletionRetry"),
    ("unsafeWriteStep", "durableBeforeWrite"),
    ("unsafeAttributionStep", "copiedRequiresOriginals"),
)


def interrupted(_signum, _frame):
    raise KeyboardInterrupt


def run_checker(command: list[str], directory: Path, output, *, timeout: float = 600) -> int:
    # All argv values are pinned constants or paths owned by this checkout.
    process = subprocess.Popen(  # noqa: S603
        command,
        cwd=directory,
        stdout=output,
        stderr=subprocess.STDOUT,
        env={**os.environ, "NO_COLOR": "1"},
        start_new_session=True,
    )
    try:
        return process.wait(timeout=timeout)
    except BaseException:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        with contextlib.suppress(subprocess.TimeoutExpired):
            process.wait(timeout=10)
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        raise


def classify(exit_code: int, output: str) -> str:
    """A parser/Java/network failure is never an expected counterexample."""
    if (
        exit_code == 0
        and "Model checking completed. No error has been found." in output
        and re.search(r"(?<![\d,])0 states left on queue\b", output)
        and "[ok] No violation found" in output
    ):
        return "passed"
    if (
        exit_code != 0
        and re.search(r"Invariant \S+ is violated", output)
        and "State 1:" in output
        and "[violation] Found an issue" in output
    ):
        return "counterexample"
    return "tool_failure"


def free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def check(step: str, invariant: str, directory: Path, model: Path = MODEL) -> dict:
    command = [
        shutil.which("mise") or "/missing-mise",
        "exec",
        "--",
        "quint",
        "verify",
        "--backend",
        "tlc",
        "--apalache-version",
        APALACHE_VERSION,
        "--server-endpoint",
        f"127.0.0.1:{free_port()}",
        "--tlc-config",
        str(CONFIG),
        "--invariant",
        invariant,
        "--step",
        step,
        "--verbosity",
        "3",
        str(model),
    ]
    log = directory / f"{model.stem}-{step}-{invariant}.log"
    failure = None
    with log.open("w") as output:
        try:
            exit_code = run_checker(command, directory, output)
        except (subprocess.TimeoutExpired, OSError) as error:
            exit_code = -1
            failure = str(error)
    output = log.read_text()
    summaries = list(
        re.finditer(
            r"([\d,]+) states generated, ([\d,]+) distinct states found, "
            r"([\d,]+) states left on queue",
            output,
        )
    )
    counts = summaries[-1] if summaries else None
    verdict = "tool_failure" if failure else classify(exit_code, output)
    if verdict == "passed" and (not counts or int(counts.group(3).replace(",", "")) != 0):
        verdict = "tool_failure"
    return {
        "step": step,
        "model": str(model),
        "command": command,
        "invariant": invariant,
        "failure": failure,
        "exit_code": exit_code,
        "verdict": verdict,
        "states": [int(value.replace(",", "")) for value in counts.groups()] if counts else None,
        "log": str(log),
    }


def main() -> int:
    parent = ROOT / ".tools/formal-verification"
    parent.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="transfer-", dir=parent))
    version = subprocess.check_output(  # noqa: S603 - fixed tool/version probe
        [shutil.which("mise") or "/missing-mise", "exec", "--", "quint", "--version"],
        cwd=ROOT,
        text=True,
    ).strip()
    if version != QUINT_VERSION:
        raise SystemExit(f"Expected Quint {QUINT_VERSION}; got {version}")

    def fingerprint() -> str:
        return hashlib.sha256(
            MODEL.read_bytes() + OVERLAP_MODEL.read_bytes() + CONFIG.read_bytes()
        ).hexdigest()

    before = fingerprint()
    cases = [
        (MODEL, "step", "safety", "passed", "safety"),
        *((MODEL, step, invariant, "counterexample", "control") for step, invariant in CONTROLS),
        (OVERLAP_MODEL, "step", "safety", "passed", "safety"),
        (OVERLAP_MODEL, "unsafeOverlapStep", "noOverlappingDeletion", "counterexample", "control"),
        (
            OVERLAP_MODEL,
            "step",
            "independentScopesNeverBothSubmitted",
            "counterexample",
            "positive_witness",
        ),
    ]
    results = []
    for model, step, invariant, expected, kind in cases:
        result = check(step, invariant, directory, model)
        result.update(expected=expected, kind=kind)
        results.append(result)
        if expected == "passed" and result["verdict"] != "passed":
            # Do not repeat tool failures through controls with no valid safe model.
            break
    passed = (
        len(results) == len(cases)
        and all(result["verdict"] == result["expected"] for result in results)
        and before == fingerprint()
    )
    report = {
        "passed": passed,
        "scope": "finite exhaustive TLC safety check; not service or native acceptance",
        "quint": version,
        "apalache": APALACHE_VERSION,
        "model_fingerprint": before,
        "results": results,
    }
    path = directory / "result.json"
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(
        json.dumps(
            {
                "passed": passed,
                "result": str(path),
                "models": {
                    Path(result["model"]).name: result["states"]
                    for result in results
                    if result["kind"] == "safety"
                },
            }
        )
    )
    return 0 if passed else 1


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(main())
