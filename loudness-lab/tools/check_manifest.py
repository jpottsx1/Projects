#!/usr/bin/env python3
"""Will the manifest the Python writes decode into the Swift that reads it?

The app runs `loudness-lab subbass` and then opens the `manifest.json` it
left behind. That file is the interface between them, and a single missing
or misspelled key fails the WHOLE document -- so the symptom is not "one
field is blank", it is a run that processed a folder correctly and then
showed no results at all. A long way from the cause.

Finding that out costs a round trip: this machine has no Swift toolchain,
so a mismatch only appears on a Mac, one key at a time, one build apart.
The same argument that produced check_golden.py produces this.

Nothing here compiles Swift. It runs the Python to write a real manifest,
reads the struct declarations out of Manifest.swift and Profile.swift, and
walks one against the other.
"""

from __future__ import annotations

import json
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    ROOT / "macapp/Sources/LoudnessLabUI/Model/Manifest.swift",
    ROOT / "macapp/Sources/LoudnessKit/Library/Profile.swift",
]

SCALARS = {
    "Int": int,
    "Double": float,
    "Float": float,
    "Bool": bool,
    "String": str,
}


def _block(source: str, start: int) -> str:
    """The braced body beginning at `start`, balanced."""
    depth, index = 1, start
    while depth and index < len(source):
        depth += {"{": 1, "}": -1}.get(source[index], 0)
        index += 1
    return source[start:index - 1]


def _depths(text: str) -> list[int]:
    """Brace depth at the START of each character of `text`."""
    depths, depth = [], 0
    for character in text:
        depths.append(depth)
        depth += {"{": 1, "}": -1}.get(character, 0)
    return depths


def parse_structs(source: str) -> dict[str, dict]:
    """{name: {"fields": {property: swift type}, "keys": {property: wire key},
    "tolerant": bool}} for every struct declared in `source`.

    Only what the struct declares ITSELF: a nested type's members belong to
    the nested type. Getting that wrong is how this file passed everything
    the first time it was run -- `Manifest` came back with no fields at
    all, having been handed its nested `Track`'s CodingKeys, and a document
    with no fields to check is a document that cannot fail.
    """
    found: dict[str, dict] = {}
    for match in re.finditer(r"\b(?:public\s+)?struct\s+(\w+)\s*:", source):
        name = match.group(1)
        opening = source.find("{", match.end())
        if opening < 0:
            continue
        body = _block(source, opening + 1)
        depths = _depths(body)

        # Nested bodies removed, so their members are not read as this
        # type's. The braces themselves stay, so a declaration cannot be
        # joined to the line after it.
        flat = "".join(c for c, d in zip(body, depths)
                       if d == 0 or c in "{}")

        fields = {}
        for line in re.finditer(
                r"^\s*(?:public\s+)?(?:let|var)\s+(\w+)\s*:\s*([^={\n]+)",
                flat, re.MULTILINE):
            # A trailing comment is part of the line and not part of the
            # type. Left in, `String?  // the corpus` is a type this
            # checker does not know, and an unknown type is reported --
            # which is right, but for the wrong reason and on every field
            # that happens to be annotated.
            declared = line.group(2).split("//")[0].strip()
            if declared:
                fields[line.group(1)] = declared

        keys = {}
        enum = next((m for m in re.finditer(r"enum\s+CodingKeys\s*:[^{]*\{", body)
                     if depths[m.start()] == 0), None)
        if enum:
            for case in re.finditer(r"case\s+([^\n]+)", _block(body, enum.end())):
                for entry in case.group(1).split(","):
                    entry = entry.strip()
                    if not entry:
                        continue
                    if "=" in entry:
                        prop, wire = entry.split("=", 1)
                        keys[prop.strip()] = wire.strip().strip('"')
                    else:
                        keys[entry] = entry
            # A CodingKeys enum is exhaustive: a property missing from it
            # is not decoded at all, so it is not ours to check.
            fields = {k: v for k, v in fields.items() if k in keys}
        else:
            keys = {name_: name_ for name_ in fields}

        found[name] = {
            "fields": fields, "keys": keys,
            # A hand-written decoder is free to accept a key that is not
            # there. The synthesised one is not -- a default value does NOT
            # make a key optional, which is the trap this whole file exists
            # to catch.
            "tolerant": any(depths[m.start()] == 0 for m in re.finditer(
                r"init\s*\(\s*from\s+decoder\s*:", body)),
        }
    return found


def check(value, swift_type: str, structs: dict, path: str,
          problems: list) -> None:
    swift_type = swift_type.strip()
    if swift_type.endswith("?"):
        if value is None:
            return
        return check(value, swift_type[:-1], structs, path, problems)
    if value is None:
        problems.append(f"{path}: null, but {swift_type} is not optional")
        return
    if swift_type.startswith("[") and swift_type.endswith("]"):
        if not isinstance(value, list):
            problems.append(f"{path}: {type(value).__name__}, expected an array")
            return
        for index, item in enumerate(value):
            check(item, swift_type[1:-1], structs, f"{path}[{index}]", problems)
        return
    if swift_type in SCALARS:
        wanted = SCALARS[swift_type]
        if wanted is float and isinstance(value, (int, float)) \
                and not isinstance(value, bool):
            return
        if wanted is int and isinstance(value, bool):
            problems.append(f"{path}: a boolean, expected Int")
            return
        if not isinstance(value, wanted):
            problems.append(f"{path}: {type(value).__name__}, expected {swift_type}")
        return
    if swift_type in structs:
        check_struct(value, swift_type, structs, path, problems)
        return
    # An unknown type is not a pass; say so rather than skipping quietly.
    problems.append(f"{path}: this checker does not know the type {swift_type}")


def check_struct(value, name: str, structs: dict, path: str,
                 problems: list) -> None:
    declared = structs[name]
    if not isinstance(value, dict):
        problems.append(f"{path}: {type(value).__name__}, expected {name}")
        return
    for prop, swift_type in declared["fields"].items():
        wire = declared["keys"].get(prop, prop)
        where = f"{path}.{wire}" if path else wire
        if wire not in value:
            if declared["tolerant"] or swift_type.strip().endswith("?"):
                continue
            problems.append(f"{where}: missing, and {name} needs it "
                            f"({prop}: {swift_type})")
            continue
        check(value[wire], swift_type, structs, where, problems)


def write_manifest(into: Path) -> Path:
    """A real one, from the real command, over a real file."""
    import numpy as np

    sys.path.insert(0, str(ROOT))
    from loudnesslab import cli, subbass

    rate = 48_000
    t = np.arange(int(rate * 4.0)) / rate
    mix = (0.6 * np.sin(2 * np.pi * 55 * t)
           + 0.3 * np.sin(2 * np.pi * 440 * t))
    audio = np.column_stack([mix, mix]).astype(np.float32) * 0.7
    source = into / "src"
    source.mkdir(parents=True)
    subbass.write_flac(source / "a.flac", audio, rate)

    out = into / "out"
    # The gate is off, because this is a question about the shape of the
    # file that comes out and not about whether a synthetic tone deserves a
    # sub. A gated track writes no manifest at all and the check would
    # report nothing rather than passing or failing.
    code = cli.main(["subbass", str(source), "--db", str(into / "l.db"),
                     "--out", str(out), "--amount", "3", "--jobs", "1",
                     "--min-activity", "0", "--porcelain"])
    if code != 0:
        raise SystemExit(f"the subbass command exited with {code}")
    return out / "manifest.json"


def main() -> int:
    structs: dict[str, dict] = {}
    for path in SOURCES:
        if not path.is_file():
            print(f"missing: {path}")
            return 2
        structs.update(parse_structs(path.read_text()))
    for wanted in ("Manifest", "Track", "Variant", "Profile"):
        if wanted not in structs:
            print(f"could not find `struct {wanted}` in the Swift sources")
            return 2

    with tempfile.TemporaryDirectory() as tmp:
        import contextlib
        import io
        with contextlib.redirect_stdout(io.StringIO()):
            manifest = write_manifest(Path(tmp))
        payload = json.loads(manifest.read_text())

    problems: list[str] = []
    check_struct(payload, "Manifest", structs, "", problems)
    if problems:
        print(f"{len(problems)} problem(s) decoding the manifest as Swift "
              f"`Manifest`:")
        for problem in problems:
            print(f"  {problem}")
        return 1
    tracks = len(payload.get("tracks", []))
    print(f"manifest decodes: Manifest, {tracks} Track, "
          f"{sum(len(t['variants']) for t in payload['tracks'])} Variant, "
          f"Profile.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
