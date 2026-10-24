#!/usr/bin/env python3
"""Convert the EmbeddingGemma 2 tokenizer.json into a compact binary for suwop-core.

Usage: generate-gemma-tokenizer.py <tokenizer.json> <output.bin>

Binary format (all integers little-endian):
    magic        4 bytes  b"SWGT"
    version      u32      1
    source_sha   32 bytes SHA-256 of the source tokenizer.json
    vocab_count  u32
    merge_count  u32
    vocab        vocab_count x (u16 byte length, UTF-8 bytes), in token id order
    merges       merge_count x (u32 left id, u32 right id), in rank order

The merge result id is the vocab id of the concatenation of both token strings; this script
validates that it exists, and the Rust loader recomputes it the same way.
"""

import hashlib
import json
import struct
import sys
from pathlib import Path

MAGIC = b"SWGT"
VERSION = 1


def convert(source: bytes) -> bytes:
    data = json.loads(source)
    model = data["model"]
    if model["type"] != "BPE" or not model["byte_fallback"] or model["ignore_merges"]:
        raise SystemExit("unsupported model configuration")
    vocab = model["vocab"]
    count = len(vocab)
    tokens: list[str | None] = [None] * count
    for token, token_id in vocab.items():
        if token_id >= count or tokens[token_id] is not None:
            raise SystemExit(f"vocab ids are not dense and unique at {token_id}")
        tokens[token_id] = token
    out = bytearray(MAGIC)
    out += struct.pack("<I", VERSION)
    out += hashlib.sha256(source).digest()
    merges = model["merges"]
    out += struct.pack("<II", count, len(merges))
    for token in tokens:
        raw = token.encode("utf-8") if token is not None else b""
        out += struct.pack("<H", len(raw)) + raw
    seen: set[tuple[int, int]] = set()
    for left, right in merges:
        if left not in vocab or right not in vocab or left + right not in vocab:
            raise SystemExit(f"merge {left!r} + {right!r} has a missing token")
        pair = (vocab[left], vocab[right])
        if pair in seen:
            raise SystemExit(f"duplicate merge {left!r} + {right!r}")
        seen.add(pair)
        out += struct.pack("<II", *pair)
    for byte in range(256):
        if f"<0x{byte:02X}>" not in vocab:
            raise SystemExit(f"missing byte fallback token {byte:#04x}")
    return bytes(out)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    source = Path(sys.argv[1]).read_bytes()
    Path(sys.argv[2]).write_bytes(convert(source))


if __name__ == "__main__":
    main()
