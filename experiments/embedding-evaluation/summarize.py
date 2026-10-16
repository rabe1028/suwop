"""Compare the same 100 caption/photo pairs and retain measured resource costs."""

import json
import re
from pathlib import Path

root = Path(__file__).parent / "results"
summary = {}
for dims in (256, 512):
    directory = root / f"d{dims}"
    vectors = json.loads((directory / "vectors.json").read_text())
    index = json.loads((directory / "index.json").read_text())
    inference = json.loads((directory / "inference.json").read_text())
    exact = []
    for query in vectors:
        ranked = sorted(
            vectors,
            key=lambda image: (
                -sum(a * b for a, b in zip(query["query"], image["image"], strict=True))
            ),
        )
        exact.append([item["id"] for item in ranked[:10]])
    metrics = {}
    for k in (1, 5, 10):
        metrics[f"exact_recall_at_{k}"] = sum(
            item["id"] in hits[:k] for item, hits in zip(vectors, exact, strict=True)
        ) / len(vectors)
        metrics[f"lance_recall_at_{k}"] = sum(
            item["id"] in item["returned"][:k] for item in index["results"]
        ) / len(vectors)
    metrics["ann_agreement_at_10"] = sum(
        len(set(hit) & set(item["returned"])) / 10
        for hit, item in zip(exact, index["results"], strict=True)
    ) / len(vectors)
    components = {
        "sqlite": 0,
        "sqlite_wal": 0,
        "lance_data": 0,
        "lance_index": 0,
        "lance_manifest": 0,
    }
    for path in (directory / "catalog").rglob("*"):
        if not path.is_file():
            continue
        size = path.stat().st_size
        if path.name == "catalog.sqlite3":
            components["sqlite"] += size
        elif path.name.startswith("catalog.sqlite3-"):
            components["sqlite_wal"] += size
        elif "_indices" in path.parts:
            components["lance_index"] += size
        elif "data" in path.parts:
            components["lance_data"] += size
        elif "analysis" in path.parts:
            components["lance_manifest"] += size
    memory = {}
    for phase, name in [("inference", "embedding"), ("index", "index")]:
        text = (directory / f"{name}.time").read_text()
        memory[f"{phase}_max_rss_bytes"] = int(
            re.search(r"(\d+)\s+maximum resident set size", text)[1]
        )
        memory[f"{phase}_peak_footprint_bytes"] = int(
            re.search(r"(\d+)\s+peak memory footprint", text)[1]
        )
    summary[str(dims)] = {
        "count": len(vectors),
        "query_language": "English COCO captions",
        "quality": metrics,
        "components_bytes": components,
        "raw_vectors_bytes": len(vectors) * dims * 4,
        "inference_seconds": inference["seconds"],
        "index_and_search_seconds": index["seconds"],
        **memory,
    }
summary["shared_model_bytes"] = 387710976
summary["limitations"] = [
    "100 deterministic public COCO images, one known corresponding caption per image; "
    "not user-library or Japanese acceptance.",
    "Exact and ANN ranking are separate; a caption can also fit another photo, "
    "but the ground truth has one positive.",
    "CPU 2 threads, 70 vision tokens, 128 text tokens, 448-pixel previews, "
    "same native C adapter as app.",
    "Independent fresh processes per phase/dimension; other builds active, "
    "timings are not isolated benchmarks.",
    "RSS and physical footprint differ. Memory budgets are admission/checkpoint limits, "
    "not hard allocator ceilings.",
]
(root / "comparison.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
