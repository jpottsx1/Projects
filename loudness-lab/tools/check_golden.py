#!/usr/bin/env python3
"""Check golden.json against the Swift structs that have to decode it.

The vectors are one JSON document decoded into one Swift struct, so a
single wrong key fails the WHOLE file -- every section, every test. Worse,
finding out costs a round trip: this machine has no Swift toolchain, so a
mismatch is only discovered on a Mac, one key at a time, one build apart.
Two have been found that way already (a missing `tail` on the grooves, an
INTEGER flag typed as `Bool`), and each cost a full cycle.

Nothing here compiles Swift. It reads the struct declarations out of
GoldenTests.swift, walks golden.json against them, and reports every
mismatch at once with the path to it -- which is all the Swift decoder
would have told us anyway, had we been able to run it.

Run directly, or let make_golden.py call it after writing the vectors.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWIFT = ROOT / "macapp/Tests/LoudnessKitTests/GoldenTests.swift"
VECTORS = ROOT / "macapp/Tests/LoudnessKitTests/Golden/golden.json"

# `Value` decodes a number OR the strings "-inf"/"inf"; it is hand-written
# in the Swift and has no fields to introspect, so it is described here.
NON_FINITE = ("-inf", "inf", "inf", "nan")


def split_top_level(text: str, separator: str) -> list[str]:
    """Split on `separator`, ignoring any inside [] or <>."""
    parts, depth, current = [], 0, ""
    for character in text:
        if character in "[<":
            depth += 1
        elif character in "]>":
            depth -= 1
        if character == separator and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += character
    parts.append(current)
    return [p.strip() for p in parts if p.strip()]


def parse_structs(source: str) -> dict[str, dict[str, str]]:
    """{struct name: {field: swift type}} for every `Decodable` struct."""
    structs: dict[str, dict[str, str]] = {}
    for match in re.finditer(r"struct\s+(\w+)\s*:\s*Decodable\s*\{", source):
        name = match.group(1)
        depth, index = 1, match.end()
        while depth and index < len(source):
            depth += {"{": 1, "}": -1}.get(source[index], 0)
            index += 1
        structs[name] = parse_fields(source[match.end():index - 1])
    return structs


def parse_fields(body: str) -> dict[str, str]:
    """Read `let a, b: T; let c: U` into {a: T, b: T, c: U}.

    Swift lets one `let` declare several names sharing the last type, and
    also several names with their OWN types, in the same statement. Both
    appear in this file, so both are handled: names accumulate until a type
    is seen, and that type applies to all of them.
    """
    fields: dict[str, str] = {}
    body = re.sub(r"//[^\n]*", "", body)          # comments
    body = re.sub(r"\n\s*(init|func|var)\b.*", "", body, flags=re.S)
    for statement in re.findall(r"\blet\s+([^\n;]+)", body):
        pending: list[str] = []
        for item in split_top_level(statement, ","):
            pieces = split_top_level(item, ":")
            if len(pieces) == 1:
                pending.append(pieces[0])
                continue
            pending.append(pieces[0])
            for name in pending:
                if re.fullmatch(r"\w+", name):
                    fields[name] = pieces[1]
            pending = []
    return fields


def describe(value) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "a boolean"
    if isinstance(value, int):
        return f"an integer ({value})"
    if isinstance(value, float):
        return f"a number ({value})"
    if isinstance(value, str):
        return f"a string ({value!r})"
    if isinstance(value, list):
        return "an array"
    return "an object"


def check(value, swift_type: str, path: str, structs: dict, problems: list) -> None:
    swift_type = swift_type.strip()

    if swift_type.endswith("?"):
        if value is None:
            return
        return check(value, swift_type[:-1], path, structs, problems)
    if value is None:
        problems.append(f"{path}: null, but Swift wants {swift_type} "
                        f"(not optional)")
        return

    if swift_type.startswith("[") and swift_type.endswith("]"):
        inner = swift_type[1:-1]
        pieces = split_top_level(inner, ":")
        if len(pieces) == 2:                       # [String: T]
            if not isinstance(value, dict):
                problems.append(f"{path}: {describe(value)}, but Swift wants "
                                f"a dictionary {swift_type}")
                return
            for key, item in value.items():
                check(item, pieces[1], f"{path}.{key}", structs, problems)
            return
        if not isinstance(value, list):            # [T]
            problems.append(f"{path}: {describe(value)}, but Swift wants "
                            f"an array {swift_type}")
            return
        for index, item in enumerate(value):
            check(item, inner, f"{path}[{index}]", structs, problems)
        return

    if swift_type == "Value":
        if isinstance(value, str) and value.lower().lstrip("-") in ("inf", "nan"):
            return
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return
        problems.append(f"{path}: {describe(value)}, but Value wants a number "
                        f"or one of {NON_FINITE}")
        return

    if swift_type in ("Int", "UInt64", "Int64"):
        # A JSON boolean is NOT an integer to Swift, whatever Python thinks.
        if isinstance(value, bool) or not isinstance(value, int):
            problems.append(f"{path}: {describe(value)}, but Swift wants "
                            f"{swift_type}")
        elif swift_type == "UInt64" and value < 0:
            problems.append(f"{path}: negative, but Swift wants UInt64")
        return

    if swift_type == "Double":
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            problems.append(f"{path}: {describe(value)}, but Swift wants Double")
        return

    if swift_type == "Bool":
        if not isinstance(value, bool):
            problems.append(f"{path}: {describe(value)}, but Swift wants Bool")
        return

    if swift_type == "String":
        if not isinstance(value, str):
            problems.append(f"{path}: {describe(value)}, but Swift wants String")
        return

    if swift_type in structs:
        if not isinstance(value, dict):
            problems.append(f"{path}: {describe(value)}, but Swift wants "
                            f"{swift_type}")
            return
        for field, field_type in structs[swift_type].items():
            if field not in value:
                problems.append(f"{path}.{field}: absent, and "
                                f"{swift_type}.{field} is {field_type} "
                                f"-- this fails the WHOLE file's decode")
                continue
            check(value[field], field_type, f"{path}.{field}", structs, problems)
        return

    problems.append(f"{path}: cannot check against unknown type {swift_type}")


def main() -> int:
    if not SWIFT.exists() or not VECTORS.exists():
        print(f"missing {SWIFT if not SWIFT.exists() else VECTORS}")
        return 2
    structs = parse_structs(SWIFT.read_text())
    if "Golden" not in structs:
        print("could not find the root `Golden` struct in GoldenTests.swift")
        return 2

    vectors = json.loads(VECTORS.read_text())
    problems: list[str] = []
    check(vectors, "Golden", "golden", structs, problems)

    if problems:
        print(f"golden.json will NOT decode into {SWIFT.name}:")
        for problem in problems:
            print(f"  {problem}")
        return 1

    fields = sum(len(f) for f in structs.values())
    print(f"golden.json decodes: {len(structs)} structs, {fields} fields checked")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
