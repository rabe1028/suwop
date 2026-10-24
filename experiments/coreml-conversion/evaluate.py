"""Check Core ML parity against float32 transformers, or embed a COCO manifest.

parity:  evaluate.py parity <models-dir> <precision> <manifest> [count]
embed:   evaluate.py embed <models-dir> <precision> <manifest> <raw.json>
The embed output matches the probe's raw.json, so quantization.py can score it.
"""

import json
import sys
import time

import numpy as np
from convert import snapshot
from pipeline import Pipeline

PREFIX = "task: search query | text: "


def parity(pipeline, fixtures):
    for f in fixtures:
        image_reference = pipeline.st.encode({"image": f["file"]}, normalize_embeddings=True)
        text_reference = pipeline.st.encode(PREFIX + f["query"], normalize_embeddings=True)
        image, text = pipeline.image(f["file"]), pipeline.text(PREFIX + f["query"])
        print(
            f["id"],
            "image cosine",
            round(float(image @ image_reference), 5),
            "text cosine",
            round(float(text @ text_reference), 5),
            "finite",
            bool(np.isfinite(image).all() and np.isfinite(text).all()),
        )


def embed(pipeline, fixtures, output):
    records, started = [], time.time()
    for f in fixtures:
        queries = {"app_en": pipeline.text(PREFIX + f["query"]).tolist()}
        if f.get("queryJa"):
            queries["app_ja"] = pipeline.text(PREFIX + f["queryJa"]).tolist()
        records.append(
            {"id": f["id"], "image": pipeline.image(f["file"]).tolist(), "queries": queries}
        )
    with open(output, "w") as handle:
        json.dump(records, handle)
    print("seconds", round(time.time() - started, 1))


def main():
    phase, directory, precision, manifest = sys.argv[1:5]
    with open(manifest) as handle:
        fixtures = json.load(handle)
    pipeline = Pipeline(snapshot(), directory, precision)
    if phase == "parity":
        parity(pipeline, fixtures[: int(sys.argv[5]) if len(sys.argv) > 5 else 3])
    else:
        embed(pipeline, fixtures, sys.argv[5])


if __name__ == "__main__":
    main()
