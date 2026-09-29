#!/usr/bin/env python3
"""How fast can Demucs separate on this Mac, and does faster change anything?

Separating is the slow half of processing new songs: 36 s a track on
Jeff's Mac (16 GB, the graphics chip), one track at a time, against 29 s
a track for everything else. Demucs cuts a song into 7.8 s pieces with a
quarter of each overlapping the next, and hands the graphics chip one
piece at a time. Handing it several (`batch`), overlapping less, and
dropping Demucs's random half-second shift may all be faster -- but only
the machine that will use them can say by how much, and none of it is
worth anything if the kicks found on the drum part change.

So this separates the same songs every way in CONFIGS, times each, and
compares each drum part with a reference one:

    kicks      how many of the kicks found agree (within 10 ms), as a
               fraction -- what the sub stage actually reads
    closeness  how close the drum part is, in dB (60+ is the same audio)

The yardstick for "the same" is Demucs's own random shift: "now" and "no
shift" differ only by it, so that difference is noise Demucs already
has, and a faster way that differs by no more is as good. The fastest of
those is recommended.

    .venv/bin/python tools/separation_speed.py <folder> [--songs 3]
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from loudnesslab import decode, stems, subbass  # noqa: E402

RATE = decode.TARGET_RATE
# (name, separator, what is passed to it). "now" is what processing does
# today: PyTorch Demucs with no random shift (Jeff's first run of this
# test, 2026-09-29, found batching, less overlap and half precision no
# faster or much slower, so they are gone from the list). "random shift"
# is Demucs's own default, kept as the yardstick for how much a result
# may move and still count as the same. "MLX" is the same htdemucs
# rewritten for Apple's MLX (the demucs-mlx package), said to be 2.6x
# faster on the graphics chip; 2 at once is its own recommendation.
CONFIGS = [
    ("now", "demucs", {"batch": 1, "shifts": 0, "overlap": 0.25}),
    ("random shift", "demucs", {"batch": 1, "shifts": 1, "overlap": 0.25}),
    ("MLX", "demucs-mlx", {"batch": 2, "shifts": 0, "overlap": 0.25}),
    ("MLX, 1 at once", "demucs-mlx", {"batch": 1, "shifts": 0, "overlap": 0.25}),
]
REFERENCE = "now"              # deterministic, so the others compare to it
YARDSTICK = "random shift"
MATCH_S = 0.010
# And never below this, whatever the yardstick: a model whose random shift
# moved the kicks a lot (a stand-in with random weights moved 90% of them)
# would otherwise pass anything.
MIN_KICKS = 0.95


def kick_agreement(a: np.ndarray, b: np.ndarray, rate: int) -> float:
    """Of the kicks found in two lists (sample offsets), the share that
    have a partner in the other within MATCH_S: 1.0 is the same kicks."""
    if a.size == 0 and b.size == 0:
        return 1.0
    if a.size == 0 or b.size == 0:
        return 0.0
    window = MATCH_S * rate
    b_sorted = np.sort(b)
    at = np.clip(np.searchsorted(b_sorted, a), 1, b_sorted.size - 1)
    nearest = np.minimum(np.abs(b_sorted[at] - a), np.abs(b_sorted[at - 1] - a))
    matched = int(np.sum(nearest <= window))
    return 2 * matched / (a.size + b.size)


def closeness_db(reference: np.ndarray, other: np.ndarray) -> float:
    """How close two versions of a part are: the part's energy over the
    difference's, in dB. Capped at 120 (identical)."""
    signal = float(np.sum(np.square(reference, dtype=np.float64)))
    noise = float(np.sum(np.square(reference.astype(np.float64) - other)))
    if noise <= signal * 1e-12:
        return 120.0
    return 10 * np.log10(signal / noise) if signal > 0 else 0.0


def recommend(rows: list[dict]) -> str:
    """The fastest way whose kicks agree with the reference at least as
    well as Demucs's own random shift does, allowing a hair for rounding.
    `rows`: name, seconds (None if it failed), kicks."""
    by_name = {row["name"]: row for row in rows}
    now = by_name.get(REFERENCE)
    shifted = by_name.get(YARDSTICK)
    if not now or now["seconds"] is None:
        return "No recommendation: the current way did not run."
    yardstick = (shifted["kicks"] if shifted and shifted["seconds"] is not None
                 else 1.0)
    floor = max(MIN_KICKS, yardstick - 0.005)
    usable = [row for row in rows if row["seconds"] is not None
              and row["name"] != YARDSTICK
              and (row["name"] == REFERENCE or row["kicks"] >= floor)]
    best = min(usable, key=lambda row: row["seconds"])
    if best["name"] == REFERENCE:
        return "Recommendation: keep separating as now; nothing was faster."
    saved = 1 - best["seconds"] / now["seconds"]
    return (f"Recommendation: {best['name']} -- {saved:.0%} faster than now, "
            f"agreeing on {best['kicks']:.1%} of the kicks (needed "
            f"{floor:.1%}: Demucs's own random shift leaves {yardstick:.1%}).")


def run(folder: Path, songs: int = 3, out=print) -> str:
    files = decode.find_audio(folder)[:songs]
    if not files:
        out(f"No audio files in {folder}.")
        return ""
    out(f"{len(files)} song(s) from {folder}, each separated {len(CONFIGS)} ways.")
    tracks = [(path.name, decode.decode(path, RATE)) for path in files]
    parts: dict[str, list] = {}
    rows = []
    warmed = set()
    for name, backend, options in CONFIGS:
        if backend not in stems.available():
            out(f"  {name:<26} not installed")
            rows.append({"name": name, "seconds": None, "devices": set(),
                         "failure": f"{backend} is not installed",
                         "minutes": sum(x.shape[0] for _, x in tracks) / RATE / 60})
            parts[name] = []
            continue
        if (backend, options.get("batch")) not in warmed:
            # The first separation loads the model (MLX converts its weights
            # the very first time) and warms the graphics chip up; not timed.
            try:
                stems.separate(tracks[0][1][:RATE * 10], RATE, backend,
                               options=options)
            except Exception:  # the timed run below says what went wrong
                pass
            warmed.add((backend, options.get("batch")))
        stems._loaded.pop("mps_failed", None)
        seconds, failure, devices = 0.0, None, set()
        drums = []
        for _, x in tracks:
            started = time.monotonic()
            try:
                separated = stems.separate(x, RATE, backend, options=options)
            except Exception as exc:  # one way failing is a result, not the end
                failure = f"{type(exc).__name__}: {exc}"[:200]
                break
            seconds += time.monotonic() - started
            devices.add(stems.last_device.get("name", "?"))
            if stems.gpu_failure():
                failure = stems.gpu_failure()
            drums.append(separated["drums"])
        parts[name] = drums
        rows.append({"name": name, "seconds": None if failure else seconds,
                     "failure": failure, "devices": devices,
                     "minutes": sum(x.shape[0] for _, x in tracks) / RATE / 60})
        out(f"  {name:<26} {seconds:6.1f} s"
            + (f"  -- failed: {failure}" if failure else ""))
    reference = parts[REFERENCE]
    for row in rows:
        if row["failure"] or len(parts[row["name"]]) < len(tracks):
            row["kicks"], row["closeness"], row["seconds"] = 0.0, 0.0, None
            continue
        agree, close = [], []
        for (song, x), ref, mine in zip(tracks, reference, parts[row["name"]]):
            found_ref = subbass.detect_kicks(x, RATE, ref)[0]
            found = subbass.detect_kicks(x, RATE, mine)[0]
            agree.append(kick_agreement(found_ref, found, RATE))
            close.append(closeness_db(ref, mine))
        row["kicks"] = float(np.mean(agree))
        row["closeness"] = float(np.min(close))
    minutes = rows[0]["minutes"]
    lines = ["", f"{'way':<26}{'seconds':>9}{'a song':>9}{'kicks':>8}"
                 f"{'closeness':>12}  (against '{REFERENCE}')"]
    for row in rows:
        if "not installed" in (row.get("failure") or ""):
            # Not a slow or wrong result -- no result at all.
            lines.append(f"{row['name']:<26}{'not tested: not installed':>35}")
            continue
        per_song = (f"{row['seconds'] / len(tracks):>9.1f}"
                    if row["seconds"] is not None else f"{'failed':>9}")
        lines.append(f"{row['name']:<26}"
                     + (f"{row['seconds']:>9.1f}" if row["seconds"] is not None
                        else f"{'-':>9}")
                     + per_song + f"{row['kicks']:>8.3f}{row['closeness']:>9.1f} dB")
    lines += ["", f"{minutes:.1f} minutes of music. '{YARDSTICK}' against "
                  f"'{REFERENCE}' is Demucs's own random shift: the yardstick.",
              recommend(rows)]
    text = "\n".join(lines)
    out(text)
    return text


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("folder", type=Path)
    parser.add_argument("--songs", type=int, default=3)
    args = parser.parse_args(argv)
    if "demucs" not in stems.available():
        print("Demucs is not installed: .venv/bin/pip install demucs")
        return 2
    run(args.folder, args.songs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
