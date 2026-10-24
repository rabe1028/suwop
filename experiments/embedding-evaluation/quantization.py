"""Compare prefixes, Matryoshka dimensions and stored-vector precision offline.

Run: uv run --no-project --with numpy python quantization.py results/raw/raw.json
Image vectors are the stored side; queries stay float32, as in the app.
"""

import json
import sys
from pathlib import Path

import numpy as np

DIMENSIONS = (768, 512, 256, 128)
RESCORE = 100


def normalize(matrix):
    return matrix / np.linalg.norm(matrix, axis=1, keepdims=True)


def int8(images):
    scale = np.abs(images).max(axis=1, keepdims=True) / 127
    return np.round(images / scale).astype(np.int8), scale


def scores(images, queries, precision):
    if precision == "f32":
        return queries @ images.T
    if precision == "f16":
        return queries @ images.astype(np.float16).astype(np.float32).T
    codes, scale = int8(images)
    exact_int8 = queries @ (codes.astype(np.float32) * scale).T
    if precision == "int8":
        return exact_int8
    # Sign bits for both sides; higher agreement means smaller Hamming distance.
    agreement = np.sign(queries) @ np.sign(images).T
    if precision == "bit":
        return agreement
    # Binary prefilter, then int8 rescoring of the candidates only.
    candidates = np.argsort(-agreement, axis=1)[:, :RESCORE]
    rescored = np.full_like(exact_int8, -np.inf)
    rows = np.arange(len(queries))[:, None]
    rescored[rows, candidates] = exact_int8[rows, candidates]
    return rescored


def bytes_per_vector(dimensions, precision):
    return {
        "f32": dimensions * 4,
        "f16": dimensions * 2,
        "int8": dimensions + 4,
        "bit": dimensions // 8,
        "bit+int8": dimensions // 8 + dimensions + 4,
    }[precision]


def evaluate(records, name):
    # Every query searches the full gallery, including images without that query variant.
    present = [i for i, r in enumerate(records) if name in r["queries"]]
    images_full = np.array([r["image"] for r in records], dtype=np.float32)
    queries_full = np.array([records[i]["queries"][name] for i in present], dtype=np.float32)
    rows = []
    for dimensions in DIMENSIONS:
        images = normalize(images_full[:, :dimensions])
        queries = normalize(queries_full[:, :dimensions])
        reference = np.argsort(-scores(images, queries, "f32"), axis=1)[:, :10]
        for precision in ("f32", "f16", "int8", "bit", "bit+int8"):
            ranked = np.argsort(-scores(images, queries, precision), axis=1)[:, :10]
            target = np.array(present)[:, None]
            agreement = np.mean(
                [len(set(a) & set(b)) / 10 for a, b in zip(ranked, reference, strict=True)]
            )
            rows.append(
                {
                    "query": name,
                    "count": len(present),
                    "dimensions": dimensions,
                    "precision": precision,
                    "bytes": bytes_per_vector(dimensions, precision),
                    "top1": float(np.mean(ranked[:, :1] == target) * 1),
                    "top5": float(np.mean((ranked[:, :5] == target).any(axis=1))),
                    "top10": float(np.mean((ranked == target).any(axis=1))),
                    "top10AgreementWithF32": float(agreement),
                }
            )
    return rows


def main():
    records = json.loads(Path(sys.argv[1]).read_text())
    names = sorted({name for r in records for name in r["queries"]})
    rows = [row for name in names for row in evaluate(records, name)]
    output = Path(sys.argv[1]).with_name("quantization.json")
    output.write_text(json.dumps(rows, indent=2) + "\n")
    print("query    n    dim prec      bytes  top1  top5  top10 agree")
    for r in rows:
        print(
            f"{r['query']:8} {r['count']:4} {r['dimensions']:4} {r['precision']:9} {r['bytes']:5} "
            f"{r['top1']:.3f} {r['top5']:.3f} {r['top10']:.3f} {r['top10AgreementWithF32']:.3f}"
        )


if __name__ == "__main__":
    main()
