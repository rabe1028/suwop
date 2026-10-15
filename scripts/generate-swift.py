#!/usr/bin/env python3
"""Generate value-only Swift DTOs from Rust's JSON schema; fail on unknown schema kinds."""

import json
import sys
from pathlib import Path

DATES = {"createdAt", "capturedAt", "modifiedAt", "scannedAt"}
ORDER = {
    "AssetKey": ["provider", "scope", "assetID"],
    "AlbumKey": ["provider", "scope", "albumID"],
    "PhotoResource": ["id", "name", "role", "sha1", "bytes"],
    "StoredAsset": [
        "appleVisibility",
        "key",
        "name",
        "capturedAt",
        "modifiedAt",
        "revision",
        "resources",
        "isFavorite",
        "latitude",
        "longitude",
        "inventoryComplete",
        "isOffline",
        "deletionBlockers",
        "immichStack",
    ],
    "LibrarySnapshot": ["provider", "scope", "assets", "access", "scannedAt"],
    "TransferFile": ["resource", "path", "signature"],
    "TransferBundle": ["assets", "files"],
}


def swift_type(node, name=""):
    if node is True:
        return "JSONValue"
    if "$ref" in node:
        return node["$ref"].rsplit("/", 1)[-1]
    kind = node.get("type")
    if isinstance(kind, list):
        nonnull = [t for t in kind if t != "null"]
        return swift_type({**node, "type": nonnull[0]}, name) + "?"
    if "anyOf" in node:
        options = [n for n in node["anyOf"] if n.get("type") != "null"]
        if len(options) != 1:
            raise ValueError(f"Unsupported union: {node}")
        return swift_type(options[0], name) + "?"
    if name in DATES and kind == "number":
        return "Date"
    if kind == "array":
        return f"[{swift_type(node['items'])}]"
    if kind == "object":
        return f"[String: {swift_type(node['additionalProperties'])}]"
    if kind is None or node is True:
        return "JSONValue"
    return {"string": "String", "integer": "Int64", "number": "Double", "boolean": "Bool"}[kind]


def generate(schema):
    output = [
        "// Generated from Rust schema. Run make generate-types; do not edit.",
        "import Foundation",
        "",
    ]
    for name, node in sorted(schema["$defs"].items()):
        if "enum" in node:
            output += [f"public enum {name}: String, Codable, CaseIterable, Sendable {{"]
            output += [f"    case `{value}`" for value in node["enum"]]
            output += ["}", ""]
            continue
        if node.get("type") != "object" or "properties" not in node:
            raise ValueError(f"Unsupported named schema: {name}")
        props = node["properties"]
        order = ORDER.get(name, sorted(props))
        if set(order) != set(props):
            raise ValueError(f"Property order differs from schema: {name}")
        fields = [(field, swift_type(props[field], field)) for field in order]
        output += [f"public struct {name}: Codable, Sendable {{"]
        output += [f"    public var {field}: {kind}" for field, kind in fields]
        args = []
        for field, kind in fields:
            default = " = nil" if kind.endswith("?") else ""
            if field in {"appleVisibility", "immichStack"}:
                default = " = .unknown"
            if field in {"isFavorite", "isOffline"}:
                default = " = false"
            if field == "inventoryComplete":
                default = " = true"
            if kind.startswith("["):
                default = " = [:]" if ":" in kind else " = []"
            args.append(f"{field}: {kind}{default}")
        output += [f"    public init({', '.join(args)}) {{"]
        output += [f"        self.{field} = {field}" for field, _ in fields]
        output += ["    }", "}", ""]
    return "\n".join(output)


if __name__ == "__main__":
    destination = Path(sys.argv[1])
    text = generate(json.load(sys.stdin))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text)
