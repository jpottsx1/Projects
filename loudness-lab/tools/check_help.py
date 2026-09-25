#!/usr/bin/env python3
"""Check every setting the app exposes has help text written for it.

A setting whose reasoning is lost is a setting nobody can judge, and the
easiest way to lose it is to add a control and move on. Most of the numbers
in this project were chosen by measuring something; the help window is
where that lives, so this makes leaving it out an error rather than an
omission nobody notices.

Reads the fields off Profile.swift and the entries out of Help.swift. No
Swift toolchain needed, so it runs where the code is written.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILE = ROOT / "macapp/Sources/LoudnessKit/Library/Profile.swift"
HELP = ROOT / "macapp/Sources/LoudnessLabUI/Views/Help.swift"
VIEWS = ROOT / "macapp/Sources/LoudnessLabUI/Views"

# Profile fields that are not controls: prose, or set by the profile itself.
NOT_A_CONTROL = {"description"}

# Profile field -> the Help entry that documents it. Spelled out rather than
# inferred, so a rename shows up here instead of silently matching nothing.
DOCUMENTED_BY = {
    "target": "target",
    "estimator": "estimator",
    "peakCeiling": "peakCeiling",
    "auto": "auto",
    "reference": "reference",
    "amount": "amount",
    "maxAmount": "maxAmount",
    "minActivity": "minActivity",
    "punch": "punch",
    "punchDecay": "punchDecay",
    "declip": "declip",
    "declipMax": "declipMax",
    "targetLRA": "targetLRA",
    "maxAttenuation": "maxAttenuation",
    "transient": "transient",
    "minCrest": "minCrest",
    "air": "air",
    "airTune": "airTune",
    "stemKicks": "stemKicks",
}


def main() -> int:
    for path in (PROFILE, HELP):
        if not path.exists():
            print(f"missing {path}")
            return 2

    if not VIEWS.is_dir():
        print(f"missing {VIEWS}")
        return 2

    fields = set(re.findall(r"public var (\w+)\s*:", PROFILE.read_text()))
    fields -= NOT_A_CONTROL

    help_text = HELP.read_text()
    entries = set(re.findall(r"static let (\w+) = HelpEntry\(", help_text))

    problems: list[str] = []

    for field in sorted(fields):
        entry = DOCUMENTED_BY.get(field)
        if entry is None:
            problems.append(
                f"Profile.{field} is a setting with no help entry. Add one to "
                f"Help.swift and name it in DOCUMENTED_BY.")
        elif entry not in entries:
            problems.append(
                f"Profile.{field} points at Help.{entry}, which does not exist.")

    for stale in sorted(set(DOCUMENTED_BY) - fields):
        problems.append(
            f"DOCUMENTED_BY names Profile.{stale}, which is gone. Remove it, "
            f"and the help entry with it.")

    # Every entry has to reach a reader: the window lists `sections`, and an
    # entry left out of them is written but unreachable.
    listed = set(re.findall(r"\b(\w+)\b", help_text.split("static let sections")[-1]))
    for orphan in sorted(entries - listed):
        problems.append(f"Help.{orphan} is not in any section, so nothing shows it.")

    # And every entry should be on something, not only in the window.
    # `Help.x.summary` on a modifier, and bare `Help.x` handed to the slider
    # helper, are both "attached" -- so match the name, not a trailing field.
    # Every view, not a list of three that goes stale the moment a pane is
    # added -- which is exactly what happened when the queue pane arrived.
    views = "".join(path.read_text() for path in sorted(VIEWS.glob("*.swift"))
                    if path.name != "Help.swift")
    shown = set(re.findall(r"Help\.(\w+)\b", views))
    for unused in sorted(entries - shown):
        problems.append(f"Help.{unused} is never attached to a control (no hover text).")

    if problems:
        print("help is out of step with the settings:")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print(f"help covers all {len(fields)} settings; "
          f"{len(entries)} entries, all shown and all reachable")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
