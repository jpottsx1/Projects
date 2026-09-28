#!/usr/bin/env python3
"""Are the finished files levelled? Read back from the files themselves.

The number on the player's button is one song at a time. This reads every
audio file in a folder -- the output folder, or a library folder whose
originals were replaced -- measures it the way the processing did, and
says for each one whether it is at the target, and if not, why:

- levelled            within TOLERANCE_DB of the target
- held by peak limit  short of the target because turning it up further
                      would have pushed its true peak over the ceiling --
                      on purpose, and the reason a dynamic record can land
                      quieter than the rest
- A/B pair            a comparison file, level-matched to its partner for
                      listening and never levelled for a set
- not levelled        none of the above: an original, or a file from
                      somewhere else

    .venv/bin/python tools/check_levels.py <folder> [--target -16]
        [--estimator s_p95] [--ceiling -1]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from loudnesslab import bs1770, decode, profiles  # noqa: E402

TOLERANCE_DB = 0.3       # an MP3 re-encode moves the level a few hundredths
PAIR_MARKS = (" -- A original", " -- B ")

LEVELLED, HELD, PAIR, LOUD, NOT = ("levelled", "held by peak limit",
                                   "A/B pair", "louder than target",
                                   "not levelled")


def verdict(name: str, level: float | None, peak: float | None,
            target: float, ceiling: float) -> str:
    if any(mark in name for mark in PAIR_MARKS):
        return PAIR
    if level is None:
        return NOT
    if abs(level - target) <= TOLERANCE_DB:
        return LEVELLED
    if level > target:
        return LOUD
    if peak is not None and peak >= ceiling - TOLERANCE_DB:
        return HELD
    return NOT


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("folder", type=Path)
    parser.add_argument("--target", type=float,
                        default=profiles.FIELDS["target"])
    parser.add_argument("--estimator", default=profiles.FIELDS["estimator"],
                        choices=("s_p95", "lufs_i"))
    parser.add_argument("--ceiling", type=float,
                        default=profiles.FIELDS["peak_ceiling"])
    args = parser.parse_args(argv)

    files = sorted(decode.find_audio(args.folder))
    if not files:
        print(f"No audio files under {args.folder}.")
        return 1
    print(f"{len(files)} file(s) under {args.folder}")
    print(f"Target {args.target:+.1f} on {args.estimator}, peaks no higher "
          f"than {args.ceiling:+.1f} dBTP.\n")

    counts: dict[str, int] = {}
    rows = []
    for path in files:
        try:
            measured = bs1770.measure(decode.decode(path))
        except Exception as exc:  # one unreadable file is not the report
            print(f"  could not read {path.name}: {exc}")
            continue
        level = measured.get(args.estimator)
        peak = measured.get("true_peak_dbtp")
        what = verdict(path.name, level, peak, args.target, args.ceiling)
        counts[what] = counts.get(what, 0) + 1
        rows.append((what, level, peak, path.name))
        print(f"  {_num(level)}  peak {_num(peak)}  {what:<18}  {path.name}",
              flush=True)

    print()
    for what in (LEVELLED, HELD, LOUD, NOT, PAIR):
        if counts.get(what):
            print(f"  {counts[what]:>4}  {what}")
    print()
    held = [r for r in rows if r[0] == HELD]
    if held:
        print("  Held by the peak limit, quietest first:")
        for _, level, _, name in sorted(held, key=lambda r: r[1]):
            print(f"    {level - args.target:+.1f} dB  {name}")
        print()
    if counts.get(PAIR):
        print("  A/B pairs are matched to each other for listening, not "
              "levelled.\n  Turn 'Write A/B pairs' off for files to play "
              "out.")
    if counts.get(NOT) or counts.get(LOUD):
        print("  'Not levelled' and 'louder than target' files did not come "
              "out of a\n  levelled run with these settings -- originals, "
              "or a different target.")
    if counts.get(LEVELLED, 0) + counts.get(HELD, 0) == len(rows):
        print("  Every file is levelled, or as close as its peaks allow.")
    return 0


def _num(value: float | None) -> str:
    return "  --  " if value is None else f"{value:+6.1f}"


if __name__ == "__main__":
    sys.exit(main())
