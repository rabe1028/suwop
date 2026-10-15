"""Compare the first 20 translated queries against the same full 100-image corpus."""

import json
from pathlib import Path

root = Path(__file__).parent / "results"
ids = {item["id"] for item in json.loads((root / "japanese-manifest.json").read_text())}
summary = {"query_count": len(ids), "corpus_size": 100, "dimensions": {}}
for dims in (256, 512):
    images = json.loads((root / f"d{dims}" / "vectors.json").read_text())
    translated = json.loads((root / f"japanese{dims}" / "translated-vectors.json").read_text())
    actual = json.loads((root / f"japanese{dims}" / "index.json").read_text())
    returned = {item["id"]: item["returned"] for item in actual["results"]}
    rows = []
    for query in translated:
        exact = sorted(
            images,
            key=lambda photo: (
                -sum(a * b for a, b in zip(query["query"], photo["image"], strict=True))
            ),
        )
        rows.append(
            {
                "id": query["id"],
                "exact_rank": next(
                    i + 1 for i, item in enumerate(exact) if item["id"] == query["id"]
                ),
                "lance_top10": returned[query["id"]],
                "exact_top10": [item["id"] for item in exact[:10]],
            }
        )
    metrics = {}
    english = json.loads((root / f"d{dims}" / "index.json").read_text())
    english = [item for item in english["results"] if item["id"] in ids]
    for k in (1, 5, 10):
        metrics[f"japanese_exact_recall_at_{k}"] = sum(
            item["exact_rank"] <= k for item in rows
        ) / len(rows)
        metrics[f"japanese_lance_recall_at_{k}"] = sum(
            item["id"] in item["lance_top10"][:k] for item in rows
        ) / len(rows)
        metrics[f"same_queries_english_lance_recall_at_{k}"] = sum(
            item["id"] in item["returned"][:k] for item in english
        ) / len(english)
    summary["dimensions"][str(dims)] = {"metrics": metrics, "queries": rows}
summary["limitations"] = [
    "First 20 images in the deterministic 100-photo corpus; manually translated by the assistant.",
    "Translations are not independently reviewed Japanese relevance judgments.",
    "Source caption 581482 contains ambiguous 'metal cloth'; "
    "the translation preserves it literally.",
    "Small diagnostic sample, not a certified multilingual or personal-library benchmark.",
]
(root / "japanese-comparison.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
