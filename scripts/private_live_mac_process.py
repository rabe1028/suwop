"""Bounded owned-process and console primitives for the macOS Live acceptance runner."""

import contextlib
import hashlib
import importlib.util
import json
import os
import plistlib
import signal
import stat
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOST_ID = "jp.rabe1028.suwop.private-live.ui-probe.host"
ENV = dict(os.environ)

# Only public NSWorkspace/NSRunningApplication. Output is restricted to this bundle or exact PID.
# Stop rechecks all immutable identity fields in the same JXA process as termination.
JXA = r"""
ObjC.import('AppKit');
function run(argv) {
    const command = argv[0];
    const requestedBundle = argv[2];
    const expected = argv[1] ? JSON.parse(argv[1]) : null;
    const list = $.NSWorkspace.sharedWorkspace.runningApplications;
    let matches = [];
    for (let i = 0; i < Number(list.count); i++) {
        const app = list.objectAtIndex(i);
        const pid = Number(app.processIdentifier);
        const bundleID = ObjC.unwrap(app.bundleIdentifier) || '';
        if (bundleID !== requestedBundle && (!expected || pid !== expected.pid)) continue;
        const executable = app.executableURL;
        const launched = app.launchDate;
        const identity = {pid: pid, bundleID: bundleID,
            executable: executable ? ObjC.unwrap(executable.URLByResolvingSymlinksInPath.path) : '',
            launched: launched ? Number(launched.timeIntervalSince1970) : null};
        matches.push({app: app, identity: identity});
    }
    if (command === 'query') return JSON.stringify(matches.map(row => row.identity));
    if (command !== 'terminate' && command !== 'forceTerminate') throw Error('Unknown action');
    if (!expected) throw Error('Missing immutable identity');
    const found = matches.filter(row => row.identity.pid === expected.pid);
    if (found.length === 0) return JSON.stringify({absentFromRunningApplications: true});
    if (found.length !== 1) throw Error('Ambiguous PID');
    const row = found[0], actual = row.identity;
    if (actual.bundleID !== expected.bundleID || actual.executable !== expected.executable ||
        !Number.isFinite(actual.launched) || Math.abs(actual.launched - expected.launched) > 0.001)
        throw Error('Host identity mismatch; no termination sent');
    const accepted = command === 'terminate'
        ? Boolean(row.app.terminate) : Boolean(row.app.forceTerminate);
    return JSON.stringify({matched: true, identity: actual, action: command, accepted: accepted});
}
"""


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def load(path):
    return json.loads(
        path.read_text(),
        object_pairs_hook=unique,
        parse_constant=lambda value: (_ for _ in ()).throw(ValueError(f"Nonfinite {value}")),
    )


def save(path, value):
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    temporary.replace(path)


def digest(path):
    require(path.is_file() and not path.is_symlink(), f"Expected regular file: {path}")
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


@contextlib.contextmanager
def signals():
    requested = []

    def record(number, _frame):
        if not requested:
            requested.append(number)

    previous = {number: signal.signal(number, record) for number in (signal.SIGTERM, signal.SIGINT)}
    try:
        yield requested
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def group_alive(pid):
    try:
        os.killpg(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    # Darwin can retain reparented zombies after all executable group members exited.
    rows = subprocess.check_output(
        ["/bin/ps", "-axo", "pgid=,stat="], text=True, timeout=3
    ).splitlines()
    return any(
        len(row.split()) == 2 and row.split()[0] == str(pid) and not row.split()[1].startswith("Z")
        for row in rows
    )


def group_signal(pid, number):
    try:
        os.killpg(pid, number)
    except ProcessLookupError:
        pass
    except PermissionError:
        require(not group_alive(pid), "Cannot signal live owned process group")


def drain(process):
    group_signal(process.pid, signal.SIGTERM)
    until = time.monotonic() + 5
    while time.monotonic() < until:
        process.poll()
        if not group_alive(process.pid):
            break
        time.sleep(0.05)
    killed = group_alive(process.pid)
    if killed:
        group_signal(process.pid, signal.SIGKILL)
    process.wait(timeout=5)
    until = time.monotonic() + 3
    while group_alive(process.pid) and time.monotonic() < until:
        time.sleep(0.05)
    require(not group_alive(process.pid), "Owned executable process group remains alive")
    return {"leaderExit": process.returncode, "sentKILL": killed, "executableGroupAbsent": True}


def tool(attempt, label, command, requested, timeout=5):
    """Bound helpers; record signals until the Popen handle is installed."""
    process = None
    try:
        require(not requested, "Termination requested before helper spawn")
        with (attempt / f"{label}.log").open("xb") as log:
            process = subprocess.Popen(  # noqa: S603 - fixed argv vectors, no shell or user commands
                command,
                cwd=ROOT,
                env=ENV,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            until = time.monotonic() + timeout
            while process.poll() is None and not requested and time.monotonic() < until:
                time.sleep(0.05)
            require(not requested and process.poll() is not None, f"{label} interrupted/timed out")
            require(process.returncode == 0, f"{label} failed; see raw log")
        return (attempt / f"{label}.log").read_bytes()
    finally:
        if process is not None and (process.poll() is None or group_alive(process.pid)):
            drain(process)


def query(attempt, label, requested, expected=None, action="query", bundle=None):
    raw = tool(
        attempt,
        label,
        [
            "/usr/bin/osascript",
            "-l",
            "JavaScript",
            "-e",
            JXA,
            action,
            json.dumps(expected, separators=(",", ":")) if expected else "",
            bundle or HOST_ID,
        ],
        requested,
    )
    return json.loads(raw, object_pairs_hook=unique)


def console(attempt, label, requested):
    raw = tool(attempt, label, ["/usr/sbin/ioreg", "-n", "Root", "-d", "1", "-a"], requested)
    values = plistlib.loads(raw)
    require(isinstance(values, dict), "Unknown console schema: expected observed Root dictionary")
    root = values
    locked = root.get("IOConsoleLocked")
    users = root.get("IOConsoleUsers")
    require(type(locked) is bool and isinstance(users, list), "Missing console lock facts")
    active = [
        row for row in users if isinstance(row, dict) and row.get("kCGSSessionOnConsoleKey") is True
    ]
    require(len(active) == 1, "Unknown active console session")
    session = active[0]
    if "CGSSessionScreenIsLocked" in session:
        session_locked = session["CGSSessionScreenIsLocked"]
        require(type(session_locked) is bool, "Unknown active console lock fact")
        locked = locked or session_locked
    uid = session.get("kCGSSessionUserIDKey")
    require(type(uid) is int and uid == os.getuid(), "Current user is not the console owner")
    result = {"locked": locked, "uid": uid, "onConsole": True}
    save(attempt / f"{label}.json", result)
    return result


def tree(path):
    require(path.is_dir() and not path.is_symlink(), f"Expected bundle directory: {path}")
    rows = {}
    for item in sorted(path.rglob("*")):
        name = str(item.relative_to(path))
        info = item.lstat()
        if stat.S_ISLNK(info.st_mode):
            rows[name] = {"mode": info.st_mode, "link": os.readlink(item)}
        elif stat.S_ISREG(info.st_mode):
            rows[name] = {"mode": info.st_mode, "bytes": info.st_size, "sha256": digest(item)}
        else:
            require(stat.S_ISDIR(info.st_mode), "Unexpected nonfile bundle content")
    return rows
