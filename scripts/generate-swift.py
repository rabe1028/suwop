#!/usr/bin/env -S uv run --no-project --script
"""Generate value-only Swift DTOs from Rust's JSON schema; fail on unknown schema kinds."""

import json
import re
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
        "immichStackMembership",
        "immichVisibility",
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


EXPLICIT_NULL = "x-suwop-explicit-null"


def nullable(node):
    kinds = node.get("type")
    if isinstance(kinds, list):
        return len(kinds) == 2 and "null" in kinds and len(set(kinds)) == 2
    options = node.get("anyOf", [])
    return (
        len(options) == 2
        and all(isinstance(option, dict) for option in options)
        and sum(option.get("type") == "null" for option in options) == 1
    )


def marker_fields(definitions):
    allowed = set()
    for node in definitions.values():
        allowed.update(id(field) for field in node.get("properties", {}).values())
        for variant in node.get("oneOf", []):
            payload = variant.get("properties", {}).get("data", {})
            if isinstance(payload, dict):
                allowed.update(id(field) for field in payload.get("properties", {}).values())
    return allowed


def validate_markers(node, allowed):
    if isinstance(node, dict):
        if EXPLICIT_NULL in node and (
            id(node) not in allowed or node[EXPLICIT_NULL] is not True or not nullable(node)
        ):
            raise ValueError("Explicit-null marker requires a supported nullable struct field")
        for value in node.values():
            validate_markers(value, allowed)
    elif isinstance(node, list):
        for value in node:
            validate_markers(value, allowed)


def payload_objects(definitions):
    """Strictly decode deny_unknown_fields objects reachable from the new tagged payloads."""
    pending = [node for node in definitions.values() if "oneOf" in node]
    seen = set()
    strict = set()
    while pending:
        node = pending.pop()
        if isinstance(node, dict):
            if "$ref" in node:
                name = node["$ref"].rsplit("/", 1)[-1]
                if name not in definitions:
                    raise ValueError("Unknown tagged payload reference")
                if name not in seen:
                    seen.add(name)
                    target = definitions[name]
                    if target.get("additionalProperties") is False and "properties" in target:
                        strict.add(name)
                    pending.append(target)
            pending.extend(node.values())
        elif isinstance(node, list):
            pending.extend(node)
    return strict


def validate_payload(node, definitions, inline_object=False, seen=None):
    """No implicit JSONValue fallback on the new typed tagged-union path."""
    if seen is None:
        seen = set()
    if node is True:
        # Explicit unconstrained JSON is intentional; an unknown schema is not equivalent.
        return
    if not isinstance(node, dict) or "oneOf" in node or "enum" in node or "const" in node:
        raise ValueError("Unsupported nested tagged payload schema")
    if "$ref" in node:
        name = node["$ref"].rsplit("/", 1)[-1]
        if name not in definitions:
            raise ValueError("Unknown tagged payload reference")
        if name in seen:
            return
        seen.add(name)
        target = definitions[name]
        if "enum" in target or "oneOf" in target:
            return  # Named enum definitions are independently validated/emitted by generate().
        validate_payload(target, definitions, inline_object=True, seen=seen)
        return
    if "anyOf" in node or isinstance(node.get("type"), list):
        if not nullable(node):
            raise ValueError("Unsupported nested payload union")
        if "anyOf" in node:
            for option in node["anyOf"]:
                if option.get("type") != "null":
                    validate_payload(option, definitions, seen=seen)
        else:
            validate_payload(
                {**node, "type": next(t for t in node["type"] if t != "null")},
                definitions,
                seen=seen,
            )
        return
    kind = node.get("type")
    if kind == "array":
        validate_payload(node.get("items"), definitions, seen=seen)
    elif kind == "object":
        if "properties" in node and inline_object:
            for field in node["properties"].values():
                validate_payload(field, definitions, seen=seen)
        elif "properties" not in node and "additionalProperties" in node:
            validate_payload(node["additionalProperties"], definitions, seen=seen)
        else:
            raise ValueError("Nested object payload requires a named reference")
    elif kind not in {"string", "integer", "number", "boolean"}:
        raise ValueError("Unknown tagged payload schema kind")


def emit_struct(name, node, strict=False):
    props = node["properties"]
    order = ORDER.get(name, sorted(props))
    if set(order) != set(props):
        raise ValueError(f"Property order differs from schema: {name}")
    fields = [(field, swift_type(props[field], field)) for field in order]
    explicit = {
        field
        for field in order
        if isinstance(props[field], dict) and props[field].get(EXPLICIT_NULL) is True
    }
    output = [f"public struct {name}: Codable, Sendable {{"]
    output += [f"    public var {field}: {kind}" for field, kind in fields]
    args = []
    for field, kind in fields:
        default = " = nil" if kind.endswith("?") else ""
        if field in {"appleVisibility", "immichStack"}:
            default = " = .unknown"
        if field in {"isFavorite", "isOffline", "canPlayVideo"}:
            default = " = false"
        if field == "inventoryComplete":
            default = " = true"
        if kind.startswith("[") and not (field in explicit and kind.endswith("?")):
            default = " = [:]" if ":" in kind else " = []"
        args.append(f"{field}: {kind}{default}")
    output += [f"    public init({', '.join(args)}) {{"]
    output += [f"        self.{field} = {field}" for field, _ in fields]
    output += ["    }"]
    if strict or explicit:
        keys = ", ".join(order)
        allowed = ", ".join(json.dumps(field) for field in order)
        output += [f"    private enum CodingKeys: String, CodingKey {{ case {keys} }}"]
        output += ["    public init(from decoder: any Decoder) throws {"]
        if strict or node.get("additionalProperties") is False:
            output += [f"        try requireSchemaKeys(decoder, allowed: [{allowed}])"]
        output += ["        let values = try decoder.container(keyedBy: CodingKeys.self)"]
        for field, kind in fields:
            method = "decodeIfPresent" if kind.endswith("?") else "decode"
            output += [
                f"        {field} = try values.{method}("
                f"{kind.removesuffix('?')}.self, forKey: .{field})"
            ]
        output += ["    }"]
        if explicit:
            output += ["    public func encode(to encoder: any Encoder) throws {"]
            output += ["        var values = encoder.container(keyedBy: CodingKeys.self)"]
            for field, kind in fields:
                method = (
                    "encodeIfPresent" if kind.endswith("?") and field not in explicit else "encode"
                )
                output += [f"        try values.{method}({field}, forKey: .{field})"]
            output += ["    }"]
    return [*output, "}", ""]


def emit_tagged(name, node, definitions):
    variants = []
    nested = []
    tags = set()
    for variant in node["oneOf"]:
        props = variant.get("properties", {})
        tag = props.get("type", {})
        value = tag.get("const")
        required = set(variant.get("required", []))
        if (
            variant.get("type") != "object"
            or variant.get("additionalProperties") is not False
            or tag.get("type") != "string"
            or not isinstance(value, str)
            or re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_]*", value) is None
            or value in tags
            or set(props) not in ({"type"}, {"type", "data"})
            or required != set(props)
        ):
            raise ValueError(f"Unsupported tagged variant: {name}")
        tags.add(value)
        kind = None
        if "data" in props:
            data = props["data"]
            validate_payload(data, definitions, inline_object=True)
            if isinstance(data, dict) and data.get("type") == "object" and "properties" in data:
                if data.get("additionalProperties") is not False:
                    raise ValueError(f"Open tagged payload: {name}")
                kind = name + value[0].upper() + value[1:] + "Data"
                if kind in definitions:
                    raise ValueError(f"Tagged payload name collision: {kind}")
                nested += emit_struct(kind, data, strict=True)
            else:
                kind = swift_type(data)
                if (kind == "JSONValue" and data is not True) or kind.endswith("?"):
                    raise ValueError(f"Unsupported tagged payload: {name}")
        variants.append((value, kind))
    if not variants:
        raise ValueError(f"Empty tagged enum: {name}")
    output = [*nested, f"public enum {name}: Codable, Sendable {{"]
    output += [f"    case `{tag}`" + (f"({kind})" if kind else "") for tag, kind in variants]
    output += ["    private enum CodingKeys: String, CodingKey { case type, data }"]
    output += ["    public init(from decoder: any Decoder) throws {"]
    output += ["        let values = try decoder.container(keyedBy: CodingKeys.self)"]
    output += ["        switch try values.decode(String.self, forKey: .type) {"]
    for tag, kind in variants:
        keys = '["type", "data"]' if kind else '["type"]'
        output += [
            f"        case {json.dumps(tag)}:",
            f"            try requireSchemaKeys(decoder, allowed: {keys})",
        ]
        expression = f".{tag}(try values.decode({kind}.self, forKey: .data))" if kind else f".{tag}"
        output += [f"            self = {expression}"]
    output += [
        "        default:",
        "            throw DecodingError.dataCorruptedError(forKey: .type, in: values,",
        '                debugDescription: "Unknown enum tag")',
        "        }",
        "    }",
    ]
    output += [
        "    public func encode(to encoder: any Encoder) throws {",
        "        var values = encoder.container(keyedBy: CodingKeys.self)",
        "        switch self {",
    ]
    for tag, kind in variants:
        pattern = f"let .{tag}(data)" if kind else f".{tag}"
        output += [
            f"        case {pattern}:",
            f"            try values.encode({json.dumps(tag)}, forKey: .type)",
        ]
        if kind:
            output += ["            try values.encode(data, forKey: .data)"]
    return [*output, "        }", "    }", "}", ""]


SCHEMA_KEYS = r"""private struct GeneratedSchemaKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func requireSchemaKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: GeneratedSchemaKey.self)
    guard Set(values.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath, debugDescription: "Unknown object field"
        ))
    }
}
"""


def generate(schema):
    definitions = schema["$defs"]
    validate_markers(schema, marker_fields(definitions))
    strict = payload_objects(definitions)
    output = [
        "// Generated from Rust schema. Run make generate-types; do not edit.",
        "import Foundation",
        "",
    ]
    if strict or any(
        "oneOf" in node
        or any(
            isinstance(field, dict) and EXPLICIT_NULL in field
            for field in node.get("properties", {}).values()
        )
        for node in definitions.values()
    ):
        output += [SCHEMA_KEYS]
    for name, node in sorted(definitions.items()):
        if "enum" in node:
            output += [f"public enum {name}: String, Codable, CaseIterable, Sendable {{"]
            output += [f"    case `{value}`" for value in node["enum"]]
            output += ["}", ""]
        elif "oneOf" in node:
            output += emit_tagged(name, node, definitions)
        elif node.get("type") == "object" and "properties" in node:
            if name in strict:
                validate_payload(node, definitions, inline_object=True)
            output += emit_struct(name, node, strict=name in strict)
        else:
            raise ValueError(f"Unsupported named schema: {name}")
    return "\n".join(output)


if __name__ == "__main__":
    destination = Path(sys.argv[1])
    text = generate(json.load(sys.stdin))
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(text)
