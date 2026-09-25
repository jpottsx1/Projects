#!/usr/bin/env python3
"""Check the Python's profiles and the Swift's are the same profiles.

They are written twice, by hand, in two languages. Nothing has kept them
honest -- and a profile that says one thing on the command line and
another in the app is worse than a profile that only exists in one place,
because the disagreement is silent and the audio is different.

No Swift toolchain needed: the Swift is read, not compiled.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWIFT = ROOT / "macapp/Sources/LoudnessKit/Library/Profile.swift"
sys.path.insert(0, str(ROOT))
from loudnesslab import profiles  # noqa: E402

# Swift spelling -> Python spelling.
NAMES = {
    "targetLRA": "target_lra", "maxAttenuation": "max_attenuation",
    "transient": "transient", "minCrest": "min_crest",
    "air": "air", "airTune": "air_tune", "stemKicks": "stem_kicks",
    "airFixed": "air_fixed", "airStems": "air_stems",
    "target": "target", "estimator": "estimator", "peakCeiling": "peak_ceiling",
    "auto": "auto", "reference": "reference", "amount": "amount",
    "maxAmount": "max_amount", "minActivity": "min_activity",
    "subOffset": "sub_offset",
    "punch": "punch", "punchDecay": "punch_decay",
    "declip": "declip", "declipMax": "declip_max",
}


def swift_defaults(source: str) -> dict:
    """The `public var x: T = v` lines on Profile itself."""
    out = {}
    for name, value in re.findall(
            r"public var (\w+)\s*:\s*[\w?]+\s*=\s*([^\s/]+)", source):
        out[name] = value.strip()
    # An optional declared without an initialiser defaults to nil, which is
    # a real default and not a missing one.
    for name in re.findall(r"public var (\w+)\s*:\s*\w+\?\s*(?://[^\n]*)?$",
                           source, re.M):
        out.setdefault(name, "nil")
    return out


def swift_profiles(source: str) -> dict:
    """Each `var x = Profile()` block, with the fields it then sets."""
    block = source[source.index("public static let builtIn"):]
    found = {}
    # `var disco = Profile()` ... `disco.maxAmount = 8`
    for variable in re.findall(r"var (\w+) = Profile\(\)", block):
        settings = dict(re.findall(rf"\b{variable}\.(\w+)\s*=\s*([^\n/]+)", block))
        found[variable] = {k: v.strip() for k, v in settings.items()
                           if k != "description"}
    # `return ["disco-70s": disco, ...]`
    mapping = dict(re.findall(r'"([\w-]+)"\s*:\s*(\w+)', block))
    return {name: found.get(variable, {}) for name, variable in mapping.items()}


def same(swift: str, python) -> bool:
    if isinstance(python, bool):
        return swift.lower() == str(python).lower()
    if isinstance(python, (int, float)):
        try:
            return abs(float(swift) - float(python)) < 1e-9
        except ValueError:
            return False
    if python is None:
        return swift in ("nil", "None")
    return swift.strip('"') == str(python)


def main() -> int:
    source = SWIFT.read_text()
    defaults = swift_defaults(source)
    built = swift_profiles(source)
    problems: list[str] = []

    for name in sorted(set(profiles.BUILT_IN) | set(built)):
        if name not in built:
            problems.append(f"{name}: in the Python, missing from the Swift")
            continue
        if name not in profiles.BUILT_IN:
            problems.append(f"{name}: in the Swift, missing from the Python")
            continue
        expected = {**profiles.FIELDS, **profiles.BUILT_IN[name]}
        for swift_name, python_name in NAMES.items():
            want = expected[python_name]
            got = built[name].get(swift_name, defaults.get(swift_name))
            if got is None:
                problems.append(f"{name}.{swift_name}: not set and no default")
            elif not same(got, want):
                problems.append(
                    f"{name}.{swift_name}: Swift {got}, Python {want!r}")

    if problems:
        print("the two sets of profiles disagree:")
        for problem in problems:
            print(f"  {problem}")
        return 1
    print(f"{len(built)} profiles, {len(NAMES)} settings each, "
          f"identical in both languages")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
