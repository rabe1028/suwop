"""Seed and measure a newly created synthetic fixture; never opens original media."""

import hashlib
import json
import math
import re
import sqlite3
import struct
import sys
from pathlib import Path

phase, directory, argument = sys.argv[1:]
directory = Path(directory).resolve()
database_uri = (directory / "catalog.sqlite3").as_uri()


def vectors(ids):
    for (job_id,) in ids:
        seed = struct.pack("<QQ", 20261014, job_id)
        values = struct.unpack("<512I", hashlib.shake_256(seed).digest(512 * 4))
        vector = [value / (2**31) - 1 for value in values]
        length = math.sqrt(sum(value * value for value in vector))
        yield struct.pack("<512f", *(value / length for value in vector)), job_id


if phase == "seed":
    rows = int(argument)
    # Bulk fixture seeding excludes producer allocations from the fresh process's RSS.
    with sqlite3.connect(database_uri + "?mode=rw", uri=True) as connection:
        states = connection.execute("SELECT state FROM generations").fetchall()
        models = connection.execute("SELECT json FROM models").fetchall()
        if states != [("paused",)] or len(models) != 1:
            raise SystemExit("Expected one paused fixture generation")
        if json.loads(models[0][0])["name"] != "synthetic":
            raise SystemExit("This tool only seeds synthetic fixtures")
        identifiers = connection.execute(
            "SELECT id FROM jobs WHERE state='awaiting' ORDER BY id"
        ).fetchall()
        if len(identifiers) != rows or not 10 <= rows <= 20000:
            raise SystemExit("Unexpected fixture row count")
        connection.executemany(
            "INSERT INTO embedding_vectors(vector,job) VALUES(?,?)", vectors(identifiers)
        )
        connection.execute("UPDATE jobs SET state='queued' WHERE state='awaiting'")
        connection.commit()
        connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
elif phase == "summarize":
    binary = Path(argument).resolve()
    report = json.loads((directory / "report.json").read_text())
    components = {"lance_data": 0, "lance_indices": 0, "lance_metadata": 0}
    for path in (directory / "analysis").rglob("*"):
        if path.is_file():
            category = "lance_metadata"
            if "_indices" in path.parts:
                category = "lance_indices"
            elif "data" in path.parts:
                category = "lance_data"
            components[category] += path.stat().st_size
    with sqlite3.connect(database_uri + "?mode=rw", uri=True) as connection:
        page_size = connection.execute("PRAGMA page_size").fetchone()[0]
        free_pages = connection.execute("PRAGMA freelist_count").fetchone()[0]
        shards = connection.execute("SELECT count(*) FROM shards WHERE state='ready'").fetchone()[0]
        rows = connection.execute("SELECT count(*) FROM jobs").fetchone()[0]
        layout = [
            {
                "table": name,
                "allocated_bytes": allocated,
                "payload_bytes": payload,
                "unused_bytes": unused,
            }
            for name, allocated, payload, unused in connection.execute(
                "SELECT name,sum(pgsize),sum(payload),sum(unused) FROM dbstat "
                "GROUP BY name ORDER BY sum(pgsize) DESC"
            )
        ]
    if report["status"]["indexed"] != rows:
        raise SystemExit("Not all vectors were indexed")
    components["catalog_allocated"] = (directory / "catalog.sqlite3").stat().st_size
    components["catalog_reusable_freelist"] = free_pages * page_size
    report.update(
        {
            "implementation": "schema 2; separate temporary vector payloads; incremental vacuum",
            "sqlite_pages": layout,
            "max_rss_bytes": int(
                re.search(
                    r"(\d+)\s+maximum resident set size",
                    (directory / "time.txt").read_text(),
                )[1]
            ),
            "components_bytes": components,
            "shards": shards,
            "generator": "SHAKE256 of little-endian u64 seed and job ID; uniform f32; L2",
            "random_seed": 20261014,
            "dimensions": 512,
            "inference": "none; normalized synthetic random vectors",
            "producer": "fixture bulk-seeded into paused SQLite outbox",
            "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        }
    )
    (directory / "measurements.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
else:
    raise SystemExit("Expected seed|summarize DIRECTORY ROWS|BINARY")
