"""Per-step CPU, memory, disk and network use from .github/actions/ci-metrics samples.

    uv run --no-project python scripts/ci_metrics.py RUN_ID [--attempt N] [--json OUT]

Downloads the run attempt's ci-metrics artifacts and job step timings with gh,
then attributes every sample to the step that was running. All times are UTC
epoch seconds: Linux samples record epoch directly, macOS top frames are local
wall time converted with the runner's recorded UTC offset.
"""

import argparse
import json
import re
import subprocess
import tempfile
from collections import defaultdict
from datetime import UTC, datetime, timedelta, timezone
from itertools import pairwise
from pathlib import Path

HEADER = "  min  cpu%  p95 cores iow%  memGiB swap  rdMB/s wrMB/s netMB/s  busiest (%core)"
UNITS = {"B": 1, "K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}


def gh(*args):
    return subprocess.run(  # noqa: S603 - fixed gh subcommands, run IDs from argparse
        ["gh", *args],  # noqa: S607
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def epoch(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def size(text):
    match = re.fullmatch(r"([0-9.]+)([BKMGT]?)", text)
    return float(match[1]) * UNITS[match[2] or "B"]


def system(folder):
    return dict(line.split("=", 1) for line in (folder / "system.txt").read_text().splitlines())


def linux_samples(folder, info):
    """Interval samples: (end time, seconds, cpu busy, iowait, mem used, swap, disk r/w, net)."""
    rows = [line.split(",") for line in (folder / "samples.csv").read_text().splitlines()[1:]]
    rows = [[float(value) for value in row] for row in rows if len(row) == 16]
    total_memory = int(info["mem_bytes"])
    samples = []
    for previous, current in pairwise(rows):
        delta = [b - a for a, b in zip(previous, current, strict=True)]
        jiffies = sum(delta[1:9])
        if jiffies <= 0 or delta[0] <= 0:
            continue
        idle, iowait = delta[4], delta[5]
        samples.append(
            {
                "time": current[0],
                "seconds": delta[0],
                "cpu": 100 * (jiffies - idle - iowait) / jiffies,
                "iowait": 100 * iowait / jiffies,
                "mem": total_memory - current[9] * 1024,
                "swap": current[10] * 1024,
                "disk_read": delta[11] / delta[0],
                "disk_write": delta[12] / delta[0],
                "net_rx": delta[13] / delta[0],
            }
        )
    return samples


def linux_processes(folder):
    """(time, command, %cpu) from 10-second top frames."""
    path = folder / "top.log"
    if not path.exists():
        return []
    result, stamp = [], None
    for line in path.read_text(errors="replace").splitlines():
        if line.startswith("@"):
            stamp = float(line[1:]) + 10
            continue
        fields = line.split(None, 11)
        if stamp and len(fields) == 12 and fields[0].isdigit():
            result.append((stamp, command(fields[11]), float(fields[8])))
    return result


def command(text):
    """A readable process name: executable basename plus the first argument for runners."""
    words = text.split()
    if not words:
        return "?"
    name = Path(words[0]).name
    if name in {"bash", "sh", "python", "python3", "node", "env", "make"} and len(words) > 1:
        name += " " + Path(words[1]).name
    return name[:40]


def mac_frames(folder, info):
    """Interval samples and process rows from `top -l 0` frames."""
    offset = info.get("utc_offset", "+0000")
    zone = timezone(
        (-1 if offset[0] == "-" else 1) * timedelta(hours=int(offset[1:3]), minutes=int(offset[3:]))
    )
    total_memory = int(info["mem_bytes"])
    frames, frame = [], None
    for line in (folder / "top.log").read_text(errors="replace").splitlines():
        if re.fullmatch(r"\d{4}/\d\d/\d\d \d\d:\d\d:\d\d", line.strip()):
            frame = {"procs": []}
            frames.append(frame)
            stamp = datetime.strptime(line.strip(), "%Y/%m/%d %H:%M:%S").replace(tzinfo=zone)
            frame["time"] = stamp.timestamp()
        elif frame is None:
            continue
        elif match := re.match(r"CPU usage: ([0-9.]+)% user, ([0-9.]+)% sys", line):
            frame["cpu"] = float(match[1]) + float(match[2])
        elif match := re.match(r"PhysMem: (\S+) used .*?(\S+) unused", line):
            frame["mem"] = total_memory - size(match[2])
        elif match := re.search(r"(\d+)\(\d+\) swapouts", line):
            frame["swapouts"] = int(match[1])
        elif match := re.match(r"Disks: \d+/(\S+) read, \d+/(\S+) written", line):
            frame["disk"] = (size(match[1]), size(match[2]))
        elif match := re.match(r"Networks: packets: \d+/(\S+) in", line):
            frame["net"] = size(match[1])
        elif match := re.match(r"\s*\d+\s+(.+?)\s+([0-9.]+)\s+\S+\s+\S+\s*$", line):
            frame["procs"].append((match[1].strip()[:40], float(match[2])))
    samples, processes = [], []
    # top's first frame is not interval-based; later frames compare with the previous one.
    for previous, current in pairwise(frames):
        seconds = current["time"] - previous["time"]
        if seconds <= 0 or "cpu" not in current or "disk" not in current:
            continue
        samples.append(
            {
                "time": current["time"],
                "seconds": seconds,
                "cpu": current["cpu"],
                "iowait": 0.0,
                "mem": current.get("mem", 0),
                "swap": current.get("swapouts", 0) - previous.get("swapouts", 0),
                "disk_read": (current["disk"][0] - previous["disk"][0]) / seconds,
                "disk_write": (current["disk"][1] - previous["disk"][1]) / seconds,
                "net_rx": (current.get("net", 0) - previous.get("net", 0)) / seconds,
            }
        )
        processes += [(current["time"], name, cpu) for name, cpu in current["procs"]]
    return samples, processes


def summarize(samples, processes, start, end, cpus):
    inside = [s for s in samples if start < s["time"] <= end + 1]
    if not inside:
        return None
    weight = sum(s["seconds"] for s in inside)

    def mean(key):
        return sum(s[key] * s["seconds"] for s in inside) / weight

    by_name = defaultdict(float)
    frames = {t for t, _, _ in processes if start < t <= end + 1}
    for t, name, cpu in processes:
        if start < t <= end + 1:
            by_name[name] += cpu
    busiest = sorted(by_name.items(), key=lambda item: -item[1])[:3]
    return {
        "cpu_mean": mean("cpu"),
        "cpu_p95": sorted(s["cpu"] for s in inside)[int(0.95 * (len(inside) - 1))],
        "busy_cores": mean("cpu") * cpus / 100,
        "iowait_mean": mean("iowait"),
        "mem_peak": max(s["mem"] for s in inside),
        "swap": max(s["swap"] for s in inside),
        "disk_read": mean("disk_read"),
        "disk_write": mean("disk_write"),
        "net_rx": mean("net_rx"),
        # Mean per-frame %CPU, where 100 is one fully busy core.
        "processes": [(name, cpu / max(1, len(frames))) for name, cpu in busiest],
    }


def load(run, attempt, folder):
    jobs = json.loads(
        gh(
            "api",
            f"repos/{{owner}}/{{repo}}/actions/runs/{run}/attempts/{attempt}/jobs?per_page=100",
        )
    )["jobs"]
    gh("run", "download", str(run), "--pattern", f"ci-metrics-*-{attempt}", "--dir", str(folder))
    by_runner = {}
    for artifact in folder.iterdir():
        if (artifact / "system.txt").exists():
            by_runner[system(artifact)["runner"]] = artifact
    report = []
    for job in jobs:
        artifact = by_runner.get(job.get("runner_name"))
        if artifact is None or not job.get("completed_at"):
            continue
        info = system(artifact)
        cpus = int(info["cpus"])
        if info["os"] == "Darwin":
            samples, processes = mac_frames(artifact, info)
        else:
            samples, processes = linux_samples(artifact, info), linux_processes(artifact)
        steps = []
        for step in job["steps"]:
            if not step.get("started_at") or not step.get("completed_at"):
                continue
            start, end = epoch(step["started_at"]), epoch(step["completed_at"])
            summary = summarize(samples, processes, start, end, cpus)
            steps.append({"name": step["name"], "seconds": end - start, "metrics": summary})
        report.append(
            {
                "job": job["name"],
                "os": info["os"],
                "cpus": cpus,
                "memory": int(info["mem_bytes"]),
                "seconds": epoch(job["completed_at"]) - epoch(job["started_at"]),
                "queued": epoch(job["started_at"]) - epoch(job["created_at"]),
                "whole": summarize(samples, processes, 0, float("inf"), cpus),
                "steps": steps,
            }
        )
    return report


def mb(value):
    return f"{value / (1 << 20):6.1f}"


def render(report, minimum):
    for job in sorted(report, key=lambda job: -job["seconds"]):
        whole = job["whole"] or {}
        print(
            f"\n## {job['job']} — {job['seconds'] / 60:.1f}m (queued {job['queued'] / 60:.1f}m), "
            f"{job['os']} {job['cpus']} CPU / {job['memory'] / (1 << 30):.0f} GiB, "
            f"CPU mean {whole.get('cpu_mean', 0):.0f}%, "
            f"peak mem {whole.get('mem_peak', 0) / (1 << 30):.1f} GiB"
        )
        print(f"  {'step':44} {HEADER}")
        for step in job["steps"]:
            if step["seconds"] < minimum:
                continue
            m = step["metrics"]
            if m is None:
                print(f"  {step['name'][:44]:44} {step['seconds'] / 60:5.1f}  (no samples)")
                continue
            busiest = ", ".join(f"{name} {cpu:.0f}" for name, cpu in m["processes"])
            print(
                f"  {step['name'][:44]:44} {step['seconds'] / 60:5.1f} "
                f"{m['cpu_mean']:5.0f} {m['cpu_p95']:4.0f} "
                f"{m['busy_cores']:5.1f} {m['iowait_mean']:4.0f} {m['mem_peak'] / (1 << 30):7.1f} "
                f"{m['swap'] / (1 << 20) if job['os'] != 'Darwin' else m['swap']:5.0f} "
                f"{mb(m['disk_read'])} {mb(m['disk_write'])} {mb(m['net_rx'])}  {busiest}"
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("run", type=int)
    parser.add_argument("--attempt", type=int, default=1)
    parser.add_argument("--min-seconds", type=float, default=20)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as temp:
        report = load(args.run, args.attempt, Path(temp))
    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + "\n")
    render(report, args.min_seconds)
    print(
        f"\nGenerated {datetime.now(UTC):%Y-%m-%d %H:%M} UTC; "
        "swap column: MiB on Linux, swapouts on macOS."
    )


if __name__ == "__main__":
    main()
