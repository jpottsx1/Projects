#!/usr/bin/env python3
"""Is the peak ceiling holding processed tracks under the level target, and
would rotating the phase of the bass give the headroom back?

The sub and air both raise peaks. The levelling that ends the chain turns
each track to the target (-16 on s_p95 by default) but never past the peak
ceiling (-1 dBTP), so a track whose peaks rose ends up quieter than the
target -- "held back". Before building anything to recover that, this
measures how often it happens, and by how much.

And it tries the remedy: a phase rotator, as broadcast processors use --
all-pass filters that move the timing of the low frequencies and change
the level of nothing. Bass waveforms are often lopsided, taller on one
side than the other, and rotating them evens that out, so the same sound
peaks lower. Three strengths are tried (ROTATIONS); for each track the
report gives the best, what it took off the true peak, and how much of
the held-back level that would give back. It also checks the claim the
remedy rests on: loudness and the band levels must not move.

    .venv/bin/python tools/headroom.py <folder of processed tracks>
        [--target -16] [--estimator s_p95] [--ceiling -1]

In a folder written by a comparison run, only the processed ("-- B ...")
files are read: the originals were not processed.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from scipy.signal import sosfilt

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from loudnesslab import bs1770, decode, render, spectrum  # noqa: E402

RATE = decode.TARGET_RATE
# (name, [(corner Hz, Q), ...]): cascaded second-order all-pass sections,
# causal -- run forwards and backwards an all-pass cancels itself out.
ROTATIONS = [
    ("gentle", [(150.0, 0.7)]),
    ("broadcast", [(150.0, 0.7), (150.0, 0.7), (200.0, 0.7), (200.0, 0.7)]),
    ("deep", [(100.0, 0.7), (100.0, 0.7), (150.0, 0.7), (150.0, 0.7),
              (200.0, 0.7), (200.0, 0.7), (300.0, 0.7), (300.0, 0.7)]),
]


def allpass(corners: list[tuple[float, float]], rate: int) -> np.ndarray:
    """Second-order sections of an all-pass cascade: magnitude exactly one
    at every frequency, phase turning through 360 degrees around each
    corner (RBJ cookbook). scipy's layout: b0 b1 b2 a0 a1 a2."""
    rows = []
    for hz, q in corners:
        w = 2 * np.pi * hz / rate
        alpha = np.sin(w) / (2 * q)
        cos = np.cos(w)
        a0 = 1 + alpha
        rows.append([(1 - alpha) / a0, -2 * cos / a0, (1 + alpha) / a0,
                     1.0, -2 * cos / a0, (1 - alpha) / a0])
    return np.array(rows)


def rotate(x: np.ndarray, corners, rate: int = RATE) -> np.ndarray:
    return sosfilt(allpass(corners, rate), x, axis=0).astype(x.dtype)


def held_back(estimate: float | None, peak: float | None, target: float,
              ceiling: float) -> tuple[float, float]:
    """(the gain the levelling wants, how much of it the peak ceiling
    refuses). 0 refused is a track that reaches the target."""
    if estimate is None or peak is None:
        return 0.0, 0.0
    wanted = target - estimate
    allowed = ceiling - peak
    return wanted, max(0.0, wanted - allowed)


def band_levels(x: np.ndarray, rate: int = RATE) -> dict:
    return {b["band_hz"]: b["ltas_db"] for b in spectrum.analyse(x, rate)}


def analyse(task: dict) -> dict:
    """One track. Runs in a pool worker."""
    x = decode.decode(Path(task["path"]), RATE)
    measured = bs1770.measure(x)
    estimate, peak = measured.get(task["estimator"]), measured["true_peak_dbtp"]
    wanted, refused = held_back(estimate, peak, task["target"], task["ceiling"])
    row = {"name": Path(task["path"]).name, "wanted": wanted, "refused": refused,
           "peak": peak, "rotations": {}}
    before_bands = band_levels(x)
    for name, corners in ROTATIONS:
        turned = rotate(x, corners)
        after = bs1770.measure(turned)
        bands = band_levels(turned)
        shift = max(abs(bands[b] - before_bands[b]) for b in before_bands
                    if np.isfinite(before_bands[b]) and np.isfinite(bands[b]))
        row["rotations"][name] = {
            "peak_down": peak - after["true_peak_dbtp"],
            "loudness_moved": abs(after["lufs_i"] - measured["lufs_i"]),
            "band_moved": shift,
        }
    return row


def summary(rows: list[dict]) -> list[str]:
    held = [r for r in rows if r["refused"] > 0.05]
    lines = ["", f"{len(held)} of {len(rows)} track(s) held under the target by "
                 f"the peak ceiling."]
    if held:
        refused = sorted(r["refused"] for r in held)
        lines.append(f"  held back {np.median(refused):.1f} dB (median), "
                     f"{refused[-1]:.1f} dB at most")
    for name, _ in ROTATIONS:
        down = [r["rotations"][name]["peak_down"] for r in rows]
        back = [min(r["refused"], max(0.0, r["rotations"][name]["peak_down"]))
                for r in held]
        moved = max(max(r["rotations"][name]["loudness_moved"],
                        r["rotations"][name]["band_moved"]) for r in rows)
        lines.append(f"  {name:<10} peaks down {np.median(down):+.2f} dB (median), "
                     f"{max(down):+.2f} at best"
                     + (f"; gives back {np.median(back):.2f} dB of the held-back "
                        f"level (median)" if held else "")
                     + f"; loudness and bands moved at most {moved:.3f} dB")
    if not held:
        lines.append("Nothing is held back, so there is nothing for a phase "
                     "rotator to give back at these settings.")
    return lines


def run(folder: Path, target: float = -16.0, estimator: str = "s_p95",
        ceiling: float = -1.0, workers: int | None = None, out=print) -> list[dict]:
    files = decode.find_audio(folder)
    processed = [f for f in files if " -- B " in f.name]
    files = processed or [f for f in files if " -- A " not in f.name]
    if not files:
        out(f"No audio files in {folder}.")
        return []
    out(f"{len(files)} processed track(s) in {folder}; levelling to {target} "
        f"on {estimator}, peaks no higher than {ceiling} dBTP.")
    out("wants: the gain levelling asks for; held: what the peak ceiling "
        "refuses of it; the rotation columns: the change in true peak.")
    out(f"{'wants':>7}{'held':>7}{'peak':>8}  "
        + "".join(f"{name:>11}" for name, _ in ROTATIONS) + "  track")
    rows = []

    def done(_n, _total, row):
        rows.append(row)
        out(f"{row['wanted']:+7.1f}{row['refused']:7.1f}{row['peak']:+8.2f}  "
            + "".join(f"{-row['rotations'][name]['peak_down']:+11.2f}"
                      for name, _ in ROTATIONS) + f"  {row['name']}")

    tasks = [{"path": str(f), "target": target, "estimator": estimator,
              "ceiling": ceiling} for f in files]
    render.pipeline(tasks, analyse, workers or render.default_jobs(), done=done)
    out("\n".join(summary(rows)))
    return rows


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("folder", type=Path)
    parser.add_argument("--target", type=float, default=-16.0)
    parser.add_argument("--estimator", default="s_p95")
    parser.add_argument("--ceiling", type=float, default=-1.0)
    args = parser.parse_args(argv)
    run(args.folder, args.target, args.estimator, args.ceiling)
    return 0


if __name__ == "__main__":
    sys.exit(main())
