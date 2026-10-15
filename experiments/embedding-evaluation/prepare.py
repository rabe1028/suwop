"""Download a deterministic COCO validation subset, retaining source IDs and hashes."""

import concurrent.futures
import hashlib
import http.client
import json
import random
import re
import zipfile
from pathlib import Path

root = Path(__file__).parent / "results"
with zipfile.ZipFile(root / "annotations.zip") as archive:
    captions = json.loads(archive.read("annotations/captions_val2017.json"))
# Deterministic fixture sampling, not security randomness.
images = random.Random(20261015).sample(sorted(captions["images"], key=lambda x: x["id"]), 100)  # noqa: S311
by_id = {}
for annotation in sorted(captions["annotations"], key=lambda x: x["id"]):
    by_id.setdefault(annotation["image_id"], annotation["caption"])
(root / "images").mkdir(exist_ok=True)


def fetch(item):
    filename = item["file_name"]
    if not re.fullmatch(r"[0-9]{12}\.jpg", filename):
        raise ValueError("Unexpected COCO filename")
    url = "http://images.cocodataset.org/val2017/" + filename
    target = root / "images" / filename
    if not target.exists():
        # Fixed origin and validated path; metadata cannot select a URL scheme or redirect host.
        connection = http.client.HTTPConnection("images.cocodataset.org", timeout=60)
        try:
            connection.request("GET", "/val2017/" + filename)
            response = connection.getresponse()
            if response.status != 200:
                raise ValueError(f"COCO download returned {response.status}")
            data = response.read(16 * 1024 * 1024 + 1)
        finally:
            connection.close()
        if len(data) > 16 * 1024 * 1024:
            raise ValueError("Unexpected image size")
        target.write_bytes(data)
    return {
        "id": str(item["id"]),
        "file": str(target.resolve()),
        "query": by_id[item["id"]],
        "source": url,
        "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
    }


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
    records = list(executor.map(fetch, images))
(root / "manifest.json").write_text(json.dumps(records, indent=2) + "\n")
print(f"{len(records)} images and {len(records)} caption-to-image queries")
