"""Bind the generated Gallery runs to their source, products and rendered evidence."""

import hashlib
import json
import math
import os
import platform
import shutil
import sys
from pathlib import Path

from verify import capture, fingerprint, write_report
from vrt import CONFIG, ROOT

ATTACHMENTS = {
    "first-gallery": ".png",
    "first-preview": ".png",
    "search": ".png",
    "sort": ".png",
    "ui-measurements": ".json",
}
RUST_TARGET = "aarch64-apple-ios-sim"
TEST_METHOD = {
    10000: "testTenThousandGeneratedPhotos",
    100000: "testHundredThousandGeneratedPhotos",
}


def read(path):
    return json.loads(path.read_text())


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def simulator_state(identifier, inventory):
    devices = [
        device
        for runtime in inventory["devices"].values()
        for device in runtime
        if device["udid"] == identifier
    ]
    if len(devices) != 1:
        raise ValueError("Expected exactly one Simulator matching the run ID")
    print(devices[0]["state"])


def begin(directory):
    inventory = read(directory / "runtimes.json")["runtimes"]
    runtime = next((item for item in inventory if item["identifier"] == CONFIG["runtime"]), {})
    is_pinned = (
        runtime.get("isAvailable")
        and runtime.get("version") == CONFIG["runtime_version"]
        and runtime.get("buildversion") == CONFIG["runtime_build"]
    )
    if not is_pinned:
        raise ValueError("Pinned iOS Simulator runtime is unavailable")
    write_report(
        directory / "environment.json",
        {
            "head": capture(["/usr/bin/git", "rev-parse", "HEAD"], ROOT),
            "source_sha256": fingerprint(ROOT),
            "machine": capture(["/usr/sbin/sysctl", "-n", "hw.model"], ROOT),
            "cpu": capture(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], ROOT),
            "host_os": capture(["/usr/bin/sw_vers"], ROOT).splitlines(),
            "host_architecture": platform.machine(),
            "host_memory_bytes": int(capture(["/usr/sbin/sysctl", "-n", "hw.memsize"], ROOT)),
            "simulator_runtime": CONFIG["runtime"],
            "simulator_version": runtime["version"],
            "simulator_build": runtime["buildversion"],
            "simulator_device_type": CONFIG["device"],
            "xcode": (directory / "xcode.txt").read_text().splitlines(),
            "rustc": capture(["rustc", "-vV"], ROOT).splitlines(),
            "rust_profile_overrides": {
                key: value
                for key, value in os.environ.items()
                if key.startswith("CARGO_PROFILE_RELEASE_")
            },
        },
    )


def test_cases(nodes):
    for node in nodes:
        if node["nodeType"] == "Test Case":
            yield node
        else:
            yield from test_cases(node.get("children", []))


def verify_xctest(directory, count, simulator):
    summary = read(directory / "summary.log")
    tests = read(directory / "tests.log")
    devices = tests["devices"]
    configurations = summary["devicesAndConfigurations"]
    if (
        len(devices) != 1
        or devices[0]["deviceId"] != simulator
        or devices[0]["osBuildNumber"] != CONFIG["runtime_build"]
        or len(configurations) != 1
        or configurations[0]["device"] != devices[0]
    ):
        raise ValueError(f"{count}: XCTest ran on a different simulator")
    if (
        summary["result"] != "Passed"
        or summary["totalTestCount"] != 1
        or summary["finishTime"] <= summary["startTime"]
        or summary["testFailures"]
        or any(
            result["passedTests"] != 1
            or any(result[key] != 0 for key in ("failedTests", "skippedTests", "expectedFailures"))
            for result in (summary, configurations[0])
        )
    ):
        raise ValueError(f"{count}: expected one completed XCTest pass")
    identifier = f"GalleryPerformanceUITests/{TEST_METHOD[count]}"
    url = f"test://com.apple.xcode/Suwop/SuwopGalleryPerformanceUI/{identifier}"
    cases = list(test_cases(tests["testNodes"]))
    if (
        len(cases) != 1
        or cases[0]["nodeIdentifier"] != identifier + "()"
        or cases[0]["nodeIdentifierURL"] != url
        or cases[0]["result"] != "Passed"
    ):
        raise ValueError(f"{count}: did not execute {identifier}")
    return identifier + "()", url


def export_evidence(directory, identifier, test_url, simulator):
    attachments = directory / "attachments"
    manifest = read(attachments / "manifest.json")
    if (
        len(manifest) != 1
        or manifest[0]["testIdentifier"] != identifier
        or manifest[0]["testIdentifierURL"] != test_url
    ):
        raise ValueError(f"{directory.name}: attachments belong to a different test")
    for name, suffix in ATTACHMENTS.items():
        candidate = [
            item["exportedFileName"]
            for item in manifest[0]["attachments"]
            if (
                item["suggestedHumanReadableName"].startswith(name + "_")
                and item["deviceId"] == simulator
                and not item["isAssociatedWithFailure"]
            )
        ]
        if len(candidate) != 1:
            raise ValueError(f"{directory.name}: missing or ambiguous {name} evidence")
        source = attachments / candidate[0]
        if suffix == ".png":
            with source.open("rb") as stream:
                if stream.read(8) != b"\x89PNG\r\n\x1a\n":
                    raise ValueError(f"{directory.name}: {name} attachment is not a PNG")
        shutil.copyfile(source, directory / (name + suffix))


def publication_after_action(events, start, rendered):
    start_us, end_us = start * 1_000_000, rendered * 1_000_000
    publications = [
        event["ts"] + event["dur"]
        for event in events
        if event["name"] == "publish" and start_us <= event["ts"] <= end_us
    ]
    if len(publications) != 1 or publications[0] > end_us:
        raise ValueError("Expected one completed publication between input and visible result")
    return round((publications[0] - start_us) / 1000, 2)


def times(app, ui, events):
    def ms(start, end):
        elapsed = (end - start) * 1000
        if not math.isfinite(elapsed) or elapsed < 0:
            raise ValueError("Invalid run timeline")
        return round(elapsed, 2)

    return {
        "fixture_generation": ms(app["fixtureStart"], app["fixtureEnd"]),
        "launch_to_first_gallery_raster": ms(ui["launch"], ui["firstRaster"]),
        "scenario_start_to_first_publication": ms(app["scenarioStart"], app["firstPublished"]),
        "scenario_start_to_first_gallery_raster": ms(app["scenarioStart"], ui["firstRaster"]),
        "scenario_start_to_full_publication": ms(app["scenarioStart"], app["fullPublished"]),
        "scenario_start_to_catalog_settled": ms(app["scenarioStart"], app["catalogSettled"]),
        "scenario_start_to_full_grid_verified": ms(app["scenarioStart"], ui["fullGrid"]),
        "open_to_preview_raster": ms(ui["openPreview"], ui["previewRaster"]),
        "search_input_to_publication": publication_after_action(
            events, ui["searchInput"], ui["searchRaster"]
        ),
        "search_input_to_result_raster": ms(ui["searchInput"], ui["searchRaster"]),
        "sort_selection_to_publication": publication_after_action(
            events, ui["sortSelection"], ui["sortRaster"]
        ),
        "sort_selection_to_result_raster": ms(ui["sortSelection"], ui["sortRaster"]),
        "scenario_elapsed": ms(app["scenarioStart"], app["finished"]),
    }


def scenario(directory):
    count = int(directory.name)
    simulator = (directory.parent / "simulator.txt").read_text().strip()
    test, test_url = verify_xctest(directory, count, simulator)
    export_evidence(directory, test, test_url, simulator)
    app = read(directory / "app.json")
    ui = read(directory / "ui-measurements.json")
    trace = read(directory / "trace.json")
    summary = read(directory / "trace-summary.json")
    phases = summary["after"]["phases"]
    required = {
        "displayCallbackInterval",
        "galleryPerformanceEnd",
        "mainActorDelay",
        "previewRequest",
        "publish",
        "snapshotBridge",
        "snapshotDecode",
        "snapshotPrepare",
        "thumbnailRequest",
    }
    terminal_events = [
        event["ts"] for event in trace["traceEvents"] if event["name"] == "galleryPerformanceEnd"
    ]
    if (
        app["requestedPhotos"] != count
        or app["firstPublishedPhotos"] not in (32, count)
        or app["peakResidentBytes"] <= 0
        or not (ui["launch"] <= app["fixtureStart"] <= app["fixtureEnd"] <= app["scenarioStart"])
        or not (
            app["firstPublished"] <= app["fullPublished"] <= app["catalogSettled"] <= ui["fullGrid"]
        )
        or not (app["firstPublished"] <= ui["firstRaster"] <= ui["fullGrid"] <= ui["openPreview"])
        or not (
            ui["previewRaster"] <= ui["searchInput"] <= ui["searchRaster"] <= ui["sortSelection"]
        )
        or not (ui["sortRaster"] <= app["finished"])
        or {event["pid"] for event in trace["traceEvents"]} != {app["processID"]}
        or terminal_events != [app["finished"] * 1_000_000]
        or not required.issubset(phases)
        or summary["failures"]
    ):
        raise ValueError(
            f"{count}: incomplete or inconsistent trace, process identity, or UI evidence"
        )
    return {
        "photos": count,
        "app_process_id": app["processID"],
        "app_os": app["operatingSystem"],
        "test": test,
        "first_published_photos": app["firstPublishedPhotos"],
        "elapsed_ms": times(app, ui, trace["traceEvents"]),
        "app_peak_resident_bytes": app["peakResidentBytes"],
        "main_actor_delay": phases["mainActorDelay"],
        "display_callback_intervals": phases["displayCallbackInterval"],
        "display_callback_probe_capped": app["frameProbeCapped"],
        "screenshots": [
            f"{count}/{name}.png" for name, suffix in ATTACHMENTS.items() if suffix == ".png"
        ],
        "trace_summary": f"{count}/trace-summary.json",
    }


def finish(directory, sizes):
    environment = read(directory / "environment.json")
    if environment["source_sha256"] != fingerprint(ROOT):
        raise ValueError("Source changed during the run")
    settings = next(
        item["buildSettings"]
        for item in read(directory / "build-settings.json")
        if item["target"] == "SuwopGalleryPerformanceHost"
    )
    executable = Path(settings["TARGET_BUILD_DIR"]) / settings["EXECUTABLE_PATH"]
    scenarios = [read(directory / size / "case-report.json") for size in sizes]
    if len({item["app_process_id"] for item in scenarios}) != len(scenarios):
        raise ValueError("The two catalog sizes need independent app processes")
    write_report(
        directory / "report.json",
        {
            "environment": environment,
            "simulator_id": (directory / "simulator.txt").read_text().strip(),
            "swift_configuration": settings["CONFIGURATION"],
            "swift_optimization_level": settings["SWIFT_OPTIMIZATION_LEVEL"],
            "app_executable_sha256": sha256(executable),
            "rust_profile": "release",
            "rust_target": RUST_TARGET,
            "rust_archive_sha256": sha256(ROOT / f"target/{RUST_TARGET}/release/libsuwop_ffi.a"),
            "scenarios": scenarios,
        },
    )


if __name__ == "__main__":
    try:
        action, path, *arguments = sys.argv[1:]
        if action == "simulator-state" and not arguments:
            simulator_state(path, json.load(sys.stdin))
        elif action == "begin" and not arguments:
            begin(Path(path))
        elif action == "check" and not arguments:
            directory = Path(path)
            write_report(directory / "case-report.json", scenario(directory))
        elif action == "finish" and arguments:
            finish(Path(path), arguments)
        else:
            raise ValueError(
                "Usage: gallery_performance.py simulator-state UDID | begin DIR | check DIR |"
                " finish DIR COUNT [COUNT]"
            )
    except (KeyError, OSError, ValueError) as error:
        sys.exit(str(error))
