"""Run all ten native Live acceptance cases through one external UI runner, without retries."""

import argparse
import datetime
import json
import os
import plistlib
import shutil
import subprocess
import time
import uuid
from pathlib import Path

import private_live_mac_process as process
import private_live_mac_results as results
import verify

ROOT = Path(__file__).resolve().parents[1]
HOST_ID = process.HOST_ID
FOCUS_ID = "jp.rabe1028.suwop.private-live.host"
RUNNER_ID = "jp.rabe1028.suwop.private-live.ui-probe.tests.xctrunner"
UI_SCHEME = "SuwopPrivateLiveUIProbe"
ENV_KEY = "SUWOP_LIVE_UI_PROBE_OUT"


def require(value, message):
    process.require(value, message)


def same_os(actual, expected):
    return (
        actual.get("pid") == expected.get("pid")
        and actual.get("bundleID") == expected.get("bundleID")
        and actual.get("executable") == expected.get("executable")
        and type(actual.get("launched")) in (int, float)
        and abs(actual["launched"] - expected["launched"]) <= 0.001
    )


def captured_identity(directory, executable, bundle=HOST_ID):
    """Accept only immutable driver+host records matching a prior unique launch intent."""
    intent = process.load(directory / "launch-intent.json")
    values = []
    for name in ("owned-launch-identity.json", "host-identity.json"):
        path = directory / name
        if not path.exists():
            continue
        require(not path.is_symlink() and path.stat().st_size < 16384, "Invalid identity file")
        value = process.load(path)
        require(
            value.get("nonce") == intent.get("nonce")
            and value.get("executable") == str(executable.resolve())
            and value.get("bundleID") == bundle
            and type(value.get("pid")) is int
            and value["pid"] > 1
            and type(value.get("launched")) in (int, float)
            and value["launched"] >= intent["launchedAfter"],
            "Foreign launch identity",
        )
        values.append({key: value[key] for key in ("pid", "bundleID", "executable", "launched")})
    require(
        values and all(same_os(value, values[0]) for value in values),
        "Missing/conflicting identity",
    )
    return values[0]


def stop_owned(output, expected, requested):
    """Public OS API rechecks identity atomically before each normal/forced termination."""
    rows = process.query(output, "before", requested, expected, bundle=expected["bundleID"])
    require(all(same_os(row, expected) for row in rows), "Foreign owner; no termination authority")
    if not rows:
        # Reused PID must not be mistaken for our absent app.
        try:
            os.kill(expected["pid"], 0)
        except ProcessLookupError:
            return
        raise ValueError("Owned PID remains without verified application identity")
    for action in ("terminate", "forceTerminate"):
        process.query(output, action, requested, expected, action, expected["bundleID"])
        until = time.monotonic() + 5
        index = 0
        while time.monotonic() < until:
            index += 1
            rows = process.query(
                output, f"{action}-wait-{index}", requested, expected, bundle=expected["bundleID"]
            )
            require(
                all(same_os(row, expected) for row in rows),
                "Identity changed; no further termination",
            )
            if not rows:
                try:
                    os.kill(expected["pid"], 0)
                except ProcessLookupError:
                    return
            time.sleep(0.05)
    raise ValueError("Owned app did not terminate")


def cleanup_application(output, directories, executable, bundle, started, label):
    expected_hosts = []
    errors = []
    for directory in directories:
        try:
            require(directory.is_dir() and not directory.is_symlink(), "Invalid case output")
            expected = captured_identity(directory, executable, bundle)
            require(expected["launched"] >= started, "Case identity predates this run")
            expected_hosts.append(expected)
        except Exception as error:
            errors.append(label + " case identity: " + str(error))
    try:
        rows = process.query(output, label + "-final", [], bundle=bundle)
        require(len(rows) <= 1, "Ambiguous current " + label)
        if rows:
            matches = [value for value in expected_hosts if same_os(rows[0], value)]
            require(len(matches) == 1, "Current host lacks one exact immutable launch receipt")
            child = output / (label + "-cleanup")
            child.mkdir()
            stop_owned(child, matches[0], [])
        require(
            process.query(output, label + "-absent", [], bundle=bundle) == [], label + " remains"
        )
    except Exception as error:
        errors.append(label + " cleanup: " + str(error))
    return errors


def cleanup(output, container, host_executable, runner_executable, started, focus_executable=None):
    # Bad/absent old receipts cannot prevent independent owned host/focus/runner cleanup.
    cases = sorted(container.glob("case-*"))
    errors = cleanup_application(output, cases, host_executable, HOST_ID, started, "host")
    if focus_executable is not None:
        focus = [directory / "focus" for directory in cases if (directory / "focus").exists()]
        errors += cleanup_application(output, focus, focus_executable, FOCUS_ID, started, "focus")
    try:
        rows = process.query(output, "runner-final", [], bundle=RUNNER_ID)
        require(len(rows) <= 1, "Ambiguous runner")
        if rows:
            expected = rows[0]
            require(
                expected["executable"] == str(runner_executable.resolve())
                and type(expected["launched"]) in (int, float)
                and expected["launched"] >= started,
                "Unknown runner; no cleanup authority",
            )
            process.save(output / "runner-os-identity.json", expected)
            child = output / "runner-cleanup"
            child.mkdir()
            stop_owned(child, expected, [])
        require(
            process.query(output, "runner-absent", [], bundle=RUNNER_ID) == [], "Runner remains"
        )
    except Exception as error:
        errors.append("runner cleanup: " + str(error))
    require(not errors, "; ".join(errors))


def run_command(output, label, command, requested, timeout):
    """Run one owned group with recorded signals and a five-second capacity guard."""
    child = None
    try:
        require(not requested, "Signal before command spawn")
        with (output / f"{label}.log").open("xb") as log:
            child = subprocess.Popen(  # noqa: S603 - fixed argv vectors, no shell or user commands
                command,
                cwd=ROOT,
                env=process.ENV,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            deadline = time.monotonic() + timeout
            next_capacity = 0
            while child.poll() is None:
                require(not requested, "Command interrupted")
                now = time.monotonic()
                require(now < deadline, "Command deadline exceeded")
                if now >= next_capacity:
                    free = shutil.disk_usage(output).free
                    with (output / "capacity.jsonl").open("a") as stream:
                        stream.write(json.dumps({"label": label, "freeBytes": free}) + "\n")
                    require(free >= 4 * 1024**3, "Capacity below four GiB stop floor")
                    next_capacity = now + 5
                time.sleep(0.05)
        require(
            child.returncode == 0, f"{label} failed with exit {child.returncode}; see complete log"
        )
    finally:
        if child is not None and (child.poll() is None or process.group_alive(child.pid)):
            process.drain(child)


def build(output, requested):
    run_command(output, "xcodegen", ["xcodegen", "generate"], requested, 60)
    command = [
        "xcodebuild",
        "-clonedSourcePackagesDirPath",
        str(ROOT / "DerivedData/SourcePackages"),
        "-project",
        "Suwop.xcodeproj",
        "-scheme",
        UI_SCHEME,
        "-destination",
        "platform=macOS,arch=arm64",
        "-derivedDataPath",
        "DerivedData/PrivateLiveUIProbeSigned",
        "-parallel-testing-enabled",
        "NO",
        "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGN_IDENTITY=-",
        "build-for-testing",
    ]
    run_command(output, "build", command, requested, 600)

    process.save(
        ROOT / "DerivedData/PrivateLiveMac/normal-acceptance-build.json",
        {
            "source": verify.fingerprint(ROOT),
            "inputs": compiled_inputs(),
        },
    )


def products_for(scheme, derived):
    products = ROOT / "DerivedData" / derived / "Build/Products"
    candidates = list(products.glob(scheme + "_macosx*-arm64.xctestrun"))
    require(len(candidates) == 1, "Ambiguous current xctestrun")
    return products, candidates[0]


def compiled_inputs():
    ui, ui_run = products_for(UI_SCHEME, "PrivateLiveUIProbeSigned")
    return {
        "uiHost": process.tree(ui / "Debug/SuwopPrivateLiveUIProbeHost.app"),
        "uiRunner": process.tree(ui / "Debug/SuwopPrivateLiveUIProbeTests-Runner.app"),
        "uiRun": process.digest(ui_run),
        "focusHost": process.tree(ui / "Debug/SuwopPrivateLiveMacHost.app"),
    }


def durable_evidence_base(home):
    """Runner-owned persistent sandbox data; XCTest may purge Data/tmp on successful exit."""
    require(
        home.is_dir() and not home.is_symlink() and home.resolve() == home,
        "Unknown user home for evidence container",
    )
    current = home
    for component in (
        "Library",
        "Containers",
        RUNNER_ID,
        "Data",
        "Library",
        "Application Support",
        "SuwopLiveAcceptance",
    ):
        current = current / component
        if current.exists() or current.is_symlink():
            require(
                current.is_dir()
                and not current.is_symlink()
                and current.stat().st_uid == os.getuid(),
                "Unsafe evidence container component",
            )
        else:
            current.mkdir(mode=0o700)
    return current


def prepare_ui(output):
    products, template = products_for(UI_SCHEME, "PrivateLiveUIProbeSigned")
    value = plistlib.loads(template.read_bytes())
    require(
        set(value) == {results.UI_BUNDLE, "__xctestrun_metadata__"}, "Unknown xctestrun targets"
    )
    target = value[results.UI_BUNDLE]
    metadata = value["__xctestrun_metadata__"]
    require(
        metadata.get("FormatVersion") == 1 and target.get("IsUITestBundle") is True,
        "Unknown UI xctestrun schema",
    )
    persistent = durable_evidence_base(Path.home())
    container = persistent / ("suwop-live-mac-" + uuid.uuid4().hex)
    container.mkdir(mode=0o700)
    host = products / "Debug/SuwopPrivateLiveUIProbeHost.app"
    runner = products / "Debug/SuwopPrivateLiveUIProbeTests-Runner.app"
    executable = host / "Contents/MacOS/SuwopPrivateLiveUIProbeHost"
    target.setdefault("EnvironmentVariables", {})[ENV_KEY] = str(container)
    target["EnvironmentVariables"]["SUWOP_LIVE_UI_PROBE_HOST_EXECUTABLE"] = str(
        executable.resolve()
    )
    focus = products / "Debug/SuwopPrivateLiveMacHost.app"
    target["EnvironmentVariables"]["SUWOP_LIVE_UI_PROBE_FOCUS_APP"] = str(focus.resolve())
    target["OnlyTestIdentifiers"] = [
        f"{results.UI_SUITE}/{name}" for name in sorted(results.UI_METHODS)
    ]
    target["TestTimeoutsEnabled"] = True
    target["DefaultTestExecutionTimeAllowance"] = 60
    target["MaximumTestExecutionTimeAllowance"] = 60
    prepared = products / ("SuwopPrivateLiveMacExternal-" + uuid.uuid4().hex + ".xctestrun")
    prepared.write_bytes(plistlib.dumps(value))
    for index, component in enumerate(
        (host, runner, runner / "Contents/PlugIns" / f"{results.UI_BUNDLE}.xctest", focus)
    ):
        process.tool(
            output,
            f"signature-{index}",
            ["codesign", "--verify", "--strict", "--verbose=2", str(component)],
            [],
            10,
        )
    process.save(
        output / "preparation.json",
        {
            "container": str(container),
            "xctestrun": str(prepared),
            "xctestrunSHA256": process.digest(prepared),
            "hostTree": process.tree(host),
            "runnerTree": process.tree(runner),
        },
    )
    return prepared, container, host, runner, focus


def export_results(output, result, label, requested):
    for kind in ("summary", "tests"):
        process.tool(
            output,
            f"{label}-{kind}",
            [
                "xcrun",
                "xcresulttool",
                "get",
                "test-results",
                kind,
                "--path",
                str(result),
                "--compact",
            ],
            requested,
            20,
        )
    return process.load(output / f"{label}-summary.log"), process.load(
        output / f"{label}-tests.log"
    )


def runtime(output, requested):
    pinned = process.load(ROOT / "DerivedData/PrivateLiveMac/normal-acceptance-build.json")
    require(
        pinned == {"source": verify.fingerprint(ROOT), "inputs": compiled_inputs()},
        "Current source and compiled normal acceptance must match the completed build receipt",
    )
    require(
        not process.console(output, "console-before", requested)["locked"],
        "Console locked; no UI admission",
    )
    require(
        process.query(output, "existing-hosts", requested, bundle=HOST_ID) == [],
        "Existing host; no adoption",
    )
    require(
        process.query(output, "existing-runners", requested, bundle=RUNNER_ID) == [],
        "Existing runner; no adoption",
    )
    require(
        process.query(output, "existing-focus", requested, bundle=FOCUS_ID) == [],
        "Existing neutral focus app; no adoption",
    )
    prepared, container, host, runner, focus = prepare_ui(output)
    before = {
        "host": process.tree(host),
        "runner": process.tree(runner),
        "xctestrun": process.digest(prepared),
        "focus": process.tree(focus),
    }
    ui_result = output / "ui.xcresult"
    command = [
        "xcodebuild",
        "-xctestrun",
        str(prepared),
        "-destination",
        "platform=macOS,arch=arm64",
        "-resultBundlePath",
        str(ui_result),
        "-parallel-testing-enabled",
        "NO",
        "-test-timeouts-enabled",
        "YES",
        "-default-test-execution-time-allowance",
        "60",
        "-maximum-test-execution-time-allowance",
        "60",
    ]
    command.extend(
        f"-only-testing:{results.UI_BUNDLE}/{results.UI_SUITE}/{name}"
        for name in sorted(results.UI_METHODS)
    )
    command.append("test-without-building")
    started = time.time()
    errors = []
    try:
        run_command(output, "ui", command, requested, 300)
    except BaseException as error:
        errors.append(f"{type(error).__name__}: {error}")
    finally:
        try:
            cleanup(
                output,
                container,
                host / "Contents/MacOS/SuwopPrivateLiveUIProbeHost",
                runner / "Contents/MacOS/SuwopPrivateLiveUIProbeTests-Runner",
                started,
                focus / "Contents/MacOS/SuwopPrivateLiveMacHost",
            )
        except BaseException as error:
            errors.append("owned cleanup: " + str(error))
        # Preserve actual frames/protocols outside the sandbox on either result. No hardlinks.
        evidence = output / "compositor-evidence"
        evidence_before = process.tree(container)
        shutil.copytree(container, evidence, symlinks=True)
        evidence_after = process.tree(evidence)
        process.save(
            output / "evidence-copy.json",
            {
                "source": str(container),
                "destination": str(evidence),
                "before": evidence_before,
                "after": evidence_after,
                "verified": evidence_before == evidence_after,
            },
        )
        if evidence_before != evidence_after:
            errors.append("External evidence copy differs")
        after = {
            "host": process.tree(host),
            "runner": process.tree(runner),
            "xctestrun": process.digest(prepared),
            "focus": process.tree(focus),
        }
        process.save(output / "ui-inputs-before-after.json", {"before": before, "after": after})
        if before != after:
            errors.append("Compiled UI inputs changed")
    require(not errors, "; ".join(errors))
    ui_summary, ui_tests = export_results(output, ui_result, "ui", requested)
    accepted = results.audit(ui_summary, ui_tests)
    process.save(output / "exact-ten-audit.json", {"accepted": True, "identifiers": accepted})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--build-only", action="store_true")
    mode.add_argument("--without-building", action="store_true")
    args = parser.parse_args()
    stamp = datetime.datetime.now(datetime.UTC).strftime("%Y%m%dT%H%M%SZ")
    output = ROOT / "DerivedData/PrivateLiveMac/TestResults" / (f"Run-{stamp}-" + uuid.uuid4().hex)
    output.mkdir(parents=True)
    record = {
        "mode": "build-only" if args.build_only else "normal-ten",
        "accepted": False,
        "sourceBefore": verify.fingerprint(ROOT),
        "output": str(output),
    }
    print(json.dumps(record), flush=True)
    with process.signals() as requested:
        try:
            require(
                shutil.disk_usage(output).free >= 5 * 1024**3, "Warm admission requires five GiB"
            )
            if not args.without_building:
                build(output, requested)
            if not args.build_only:
                runtime(output, requested)
            record["accepted"] = True
        except BaseException as error:
            record["error"] = f"{type(error).__name__}: {error}"
        finally:
            record["sourceAfter"] = verify.fingerprint(ROOT)
            if record["sourceAfter"] != record["sourceBefore"]:
                record["accepted"] = False
                record["sourceChanged"] = True
            process.save(output / "result.json", record)
    print(json.dumps(record), flush=True)
    return 0 if record["accepted"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
