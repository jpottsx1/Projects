"""Clearing the mud: a dynamic cut in 200-400 Hz.

Early-seventies records sit thick in the lower midrange. Measured on
Jeff's library against his disco reference (2026-09-28): 16 of 20 tracks
more than 1 dB above it in 200-400 Hz, 3 dB the median, 4.8 at most
(George McCrae, The Stylistics, ABBA). A fixed cut would take that out
of the sparse passages too -- a verse of voice and guitar has little
there to begin with, and thinning it is not what was asked. So the cut
follows the music: at each moment it is as deep as the band is built up
then, relative to the rest of the track, and nothing where it is not.

How it works, and why each part:

- **The band, zero-phase.** 200-400 Hz is taken out with a Butterworth
  run forwards and backwards, so it is in step with the track, and put
  back scaled: y = x + (g - 1) * band. Where g is 1 the track is exactly
  what it was, and nothing outside the band is touched at any g.
- **How built up the band is, moment by moment.** Its level against the
  whole track's over 400 ms windows every 50 ms.
- **A threshold, as a dynamic EQ has.** Every moment above it is cut by
  how far above it is, and nothing below it is touched; the threshold
  is set so the band as a whole drops by the amount asked for --
  measured and reported, as the sub and air are, not a knob that means
  "some". Never deeper than MAX_CUT_DB at any moment. A track thick
  throughout -- most of these masters, EQ'd once -- is then cut nearly
  evenly; one that thickens in places is cut there. (The first version
  left each track's own least-built-up 30% alone, which on a track
  thick throughout left muddy passages uncut and could not take more
  than 4.8 dB out of it whatever was asked. A test holds that now.)
- **Smooth.** The 400 ms windows, interpolated sample by sample, move
  far too slowly to pump or click.
"""

from __future__ import annotations

import numpy as np
from scipy.signal import butter, sosfiltfilt

LOW_HZ, HIGH_HZ = 200.0, 400.0
WINDOW_S = 0.4
HOP_S = 0.05
MAX_CUT_DB = 12.0


def _blank(note: str | None = None) -> dict:
    return {"applied": False, "amount_db": 0.0, "measured_db": 0.0,
            "cutting": 0.0, "max_cut_db": 0.0, "note": note}


def _band(x: np.ndarray, rate: int, order: int = 2) -> np.ndarray:
    sos = butter(order, [LOW_HZ, HIGH_HZ], btype="band", fs=rate, output="sos")
    return sosfiltfilt(sos, x, axis=0)


def band_db(x: np.ndarray, rate: int) -> float:
    """The 200-400 Hz band's energy, in dB, through a steeper filter than
    the one the stage cuts with -- what the report measures by."""
    band = _band(np.asarray(x, dtype=np.float64), rate, order=4)
    return float(10 * np.log10(np.mean(band * band) + 1e-30))


def _frames(power: np.ndarray, rate: int) -> tuple[np.ndarray, np.ndarray]:
    """(window means of a per-sample power, their centres in samples)."""
    width, hop = int(WINDOW_S * rate), int(HOP_S * rate)
    if power.size <= width:
        return np.array([power.mean()]), np.array([power.size / 2])
    run = np.concatenate([[0.0], np.cumsum(power)])
    starts = np.arange(0, power.size - width + 1, hop)
    return (run[starts + width] - run[starts]) / width, starts + width / 2


def clear(x: np.ndarray, rate: int, amount_db: float) -> tuple[np.ndarray, dict]:
    """Take `amount_db` out of the 200-400 Hz band, deepest where it is
    most built up. Returns the audio and what was actually done."""
    if amount_db <= 0:
        return x, _blank("no mud cut asked for")
    source = np.asarray(x, dtype=np.float64)
    stereo = source if source.ndim == 2 else source[:, None]
    band = _band(stereo, rate)
    band_power = np.mean(band * band, axis=1)
    whole_power = np.mean(stereo * stereo, axis=1)
    b, centres = _frames(band_power, rate)
    w, _ = _frames(whole_power, rate)
    active = w > w.max() * 10 ** (-50 / 10) if w.max() > 0 else np.zeros_like(w, bool)
    if b.sum() <= 0 or not active.any():
        return x, _blank("nothing in 200-400 Hz to cut")
    excess = 10 * np.log10(np.maximum(b, 1e-30) / np.maximum(w, 1e-30))

    def cut_for(threshold: float) -> np.ndarray:
        return np.where(active, np.clip(excess - threshold, 0.0, MAX_CUT_DB), 0.0)

    def drop(threshold: float) -> float:
        # The band's energy after against before, from the windows.
        return float(10 * np.log10(np.sum(b * 10 ** (-cut_for(threshold) / 10))
                                   / np.sum(b)))

    def solve(target: float) -> float:
        # Lower threshold, deeper cut: bisect for the one that takes
        # `target` dB out of the band.
        high = float(excess[active].max())
        low = float(excess[active].min()) - MAX_CUT_DB
        for _ in range(60):
            middle = (low + high) / 2
            if drop(middle) > -target:
                high = middle
            else:
                low = middle
        return low

    def apply(threshold: float) -> np.ndarray:
        cut = np.interp(np.arange(stereo.shape[0]), centres, cut_for(threshold))
        gain = 10 ** (-cut / 20) - 1.0
        return stereo + band * gain[:, None]

    before = band_db(stereo, rate)
    threshold = solve(amount_db)
    y = apply(threshold)
    measured = band_db(y, rate) - before
    # The windows are an estimate of the band the report measures through
    # a steeper filter; a few corrections land the measured figure on the
    # amount asked for (one was not enough at 8 dB: 7.78).
    target = amount_db
    for _ in range(3):
        if abs(measured + amount_db) <= 0.02 or measured >= 0:
            break
        target *= amount_db / -measured
        threshold = solve(target)
        y = apply(threshold)
        measured = band_db(y, rate) - before
    cuts = cut_for(threshold)
    report = {"applied": True, "amount_db": float(amount_db),
              "measured_db": float(measured),
              "cutting": float(np.mean(cuts[active] > 0.5)),
              "max_cut_db": float(cuts.max()), "note": None}
    if cuts.max() >= MAX_CUT_DB - 1e-9 and measured > -amount_db + 0.25:
        report["note"] = (f"asked for {amount_db:.1f} dB, the band came down "
                          f"{-measured:.1f}: capped at {MAX_CUT_DB:.0f} dB a moment")
    out = y if source.ndim == 2 else y[:, 0]
    return out.astype(np.asarray(x).dtype), report
