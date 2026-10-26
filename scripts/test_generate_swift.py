"""Narrow schema support and fail-closed generation; runtime Codable checks live in Swift."""

import copy
import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "generate_swift", Path(__file__).with_name("generate-swift.py")
)
generator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generator)
MARKER = generator.EXPLICIT_NULL


def object_schema(properties, required=()):
    return {
        "type": "object",
        "properties": properties,
        "required": list(required),
        "additionalProperties": False,
    }


def tagged():
    return {
        "$defs": {
            "Record": object_schema({"camelCase": {"type": "string"}}, ["camelCase"]),
            "Choice": {
                "oneOf": [
                    object_schema({"type": {"type": "string", "const": "empty"}}, ["type"]),
                    object_schema(
                        {
                            "type": {"type": "string", "const": "record"},
                            "data": {"$ref": "#/$defs/Record"},
                        },
                        ["type", "data"],
                    ),
                    object_schema(
                        {
                            "type": {"type": "string", "const": "unknown"},
                            "data": object_schema(
                                {
                                    "attempt_id": {"type": "string"},
                                    "accepted": {"type": ["string", "null"], MARKER: True},
                                },
                                ["attempt_id"],
                            ),
                        },
                        ["type", "data"],
                    ),
                ]
            },
        }
    }


class GenerateSwiftTests(unittest.TestCase):
    def test_old_optional_struct_output_keeps_synthesized_omission_and_initializer(self):
        schema = {"$defs": {"Old": object_schema({"optional": {"type": ["string", "null"]}})}}
        self.assertEqual(
            generator.generate(schema),
            "// Generated from Rust schema. Run make generate-types; do not edit.\n"
            "import Foundation\n\n"
            "public struct Old: Codable, Sendable {\n"
            "    public var optional: String?\n"
            "    public init(optional: String? = nil) {\n"
            "        self.optional = optional\n"
            "    }\n}\n",
        )

    def test_tagged_unit_reference_inline_payload_and_wire_names_are_typed(self):
        text = generator.generate(tagged())
        self.assertIn("case `empty`", text)
        self.assertIn("case `record`(Record)", text)
        self.assertIn("case `unknown`(ChoiceUnknownData)", text)
        self.assertIn("public var attempt_id: String", text)
        self.assertIn("public var camelCase: String", text)
        self.assertIn("self = .record(try values.decode(Record.self, forKey: .data))", text)
        self.assertIn('requireSchemaKeys(decoder, allowed: ["type"])', text)
        self.assertIn('requireSchemaKeys(decoder, allowed: ["type", "data"])', text)
        self.assertIn('debugDescription: "Unknown enum tag"', text)
        self.assertNotIn("JSONValue", text)
        record = text.split("public struct Record:")[1]
        self.assertIn('requireSchemaKeys(decoder, allowed: ["camelCase"])', record)

    def test_explicit_null_is_limited_to_marked_field_not_other_optionals(self):
        fields = {
            "marked": {"type": ["string", "null"], MARKER: True},
            "plain": {"type": ["string", "null"]},
        }
        text = generator.generate({"$defs": {"Pair": object_schema(fields)}})
        self.assertIn("try values.encode(marked, forKey: .marked)", text)
        self.assertIn("try values.encodeIfPresent(plain, forKey: .plain)", text)
        self.assertIn("decodeIfPresent(String.self, forKey: .marked)", text)
        text = generator.generate(tagged())
        self.assertIn("try values.encode(accepted, forKey: .accepted)", text)
        self.assertIn("decodeIfPresent(String.self, forKey: .accepted)", text)

    def test_reference_nullable_marker_is_supported(self):
        schema = tagged()
        schema["$defs"]["Outer"] = object_schema(
            {"optional": {"anyOf": [{"$ref": "#/$defs/Record"}, {"type": "null"}], MARKER: True}}
        )
        text = generator.generate(schema)
        self.assertIn("public var optional: Record?", text)
        self.assertIn("try values.encode(optional, forKey: .optional)", text)

    def test_marker_nonnullable_null_only_invalid_value_and_wrong_position_fail(self):
        for field in (
            {"type": "string", MARKER: True},
            {"type": ["null"], MARKER: True},
            {"type": ["string", "null"], MARKER: False},
            {"type": ["string", "null"], MARKER: "true"},
            {"type": "array", "items": {"type": ["string", "null"], MARKER: True}},
        ):
            with self.subTest(field=field), self.assertRaises(ValueError):
                generator.generate({"$defs": {"Bad": object_schema({"field": field})}})
        for location in ("root", "definition", "variant", "data"):
            schema = tagged()
            target = {
                "root": schema,
                "definition": schema["$defs"]["Record"],
                "variant": schema["$defs"]["Choice"]["oneOf"][0],
                "data": schema["$defs"]["Choice"]["oneOf"][1]["properties"]["data"],
            }[location]
            target[MARKER] = True
            with self.subTest(location=location), self.assertRaises(ValueError):
                generator.generate(schema)

    def test_missing_tag_data_requirement_open_variants_and_duplicate_tags_fail(self):
        for mode in ("tag", "data-required", "open", "extra-key", "duplicate", "fallback"):
            schema = tagged()
            variants = schema["$defs"]["Choice"]["oneOf"]
            if mode == "tag":
                variants[0]["properties"]["type"].pop("const")
            elif mode == "data-required":
                variants[1]["required"].remove("data")
            elif mode == "open":
                variants[1]["additionalProperties"] = True
            elif mode == "extra-key":
                variants[0]["properties"]["other"] = {"type": "string"}
            elif mode == "duplicate":
                variants.append(copy.deepcopy(variants[0]))
            else:
                variants[1]["properties"]["data"] = {}
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                generator.generate(schema)

    def test_inline_payload_name_collision_and_unsupported_named_union_fail(self):
        schema = tagged()
        schema["$defs"]["ChoiceUnknownData"] = object_schema({})
        with self.assertRaisesRegex(ValueError, "collision"):
            generator.generate(schema)
        for union in ({"anyOf": [{"type": "string"}, {"type": "integer"}]}, {"oneOf": []}):
            with self.subTest(union=union), self.assertRaises(ValueError):
                generator.generate({"$defs": {"Unsupported": union}})

    def test_nested_unknown_union_field_array_and_reference_are_not_jsonvalue_fallbacks(self):
        for position in ("field", "items", "reference", "open-reference"):
            schema = tagged()
            unknown = {"oneOf": [{"type": "string"}, {"type": "integer"}]}
            if position == "field":
                schema["$defs"]["Choice"]["oneOf"][2]["properties"]["data"]["properties"]["bad"] = (
                    unknown
                )
            elif position == "items":
                schema["$defs"]["Choice"]["oneOf"][2]["properties"]["data"]["properties"]["bad"] = {
                    "type": "array",
                    "items": unknown,
                }
            else:
                schema["$defs"]["Record"]["properties"]["bad"] = unknown
                if position == "open-reference":
                    schema["$defs"]["Record"]["additionalProperties"] = True
            with self.subTest(position=position), self.assertRaises(ValueError):
                generator.generate(schema)
        schema = tagged()
        schema["$defs"]["Record"]["properties"]["intentional"] = True
        self.assertIn("public var intentional: JSONValue", generator.generate(schema))

    def test_explicit_true_jsonvalue_is_preserved_without_implicit_unknown_fallback(self):
        old = generator.generate({"$defs": {"Old": object_schema({"raw": True})}})
        self.assertIn("public var raw: JSONValue", old)
        self.assertNotIn("requireSchemaKeys", old)
        schema = tagged()
        schema["$defs"]["Choice"]["oneOf"][1]["properties"]["data"] = True
        self.assertIn("case `record`(JSONValue)", generator.generate(schema))
