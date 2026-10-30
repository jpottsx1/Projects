"""True-peak limiting: the last few dB that levelling needs and the peak
ceiling refuses.

Levelling turns a track to the target but never past the ceiling, and on
older masters the ceiling wins. Nineteen tracks off "Now 12" 80s 1984"
(2026-10-29): reaching -11.5 LUFS-I under -1 dBTP needs 0-4.9 dB off the
peaks, 2 dB at the median, and 9 of 10 levelled tracks ended 1-4 dB short.
Platinum Notes, given three of them, turned each to -11.5 and took 1.5-3.3
dB off the peaks to do it -- with no EQ and the loudness range within 0.4
LU. That is a limiter, and this is one.

It only takes PEAKS down. The gain is a curve that sits at unity except
around a peak too tall for the ceiling, where it dips just far enough,
early enough (ATTACK_S of lookahead) and recovers over RELEASE_S. Most of
a track is untouched; what changes is the top of the loudest hits, which
is the cost, and why it is capped.

Taking peaks down takes a little loudness with them, so `level` turns the
track up again by what was lost and limits again, until it lands. Peaks
are judged on the 4x-oversampled signal, as BS.1770 measures true peak,
once: a gain scales them, so every later attempt reuses them scaled.
"""

from __future__ import annotations

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view
from scipy.signal import resample_poly

from . import bs1770

OVERSAMPLE = 4
# The gain is decided once a millisecond and drawn straight between those
# points. Each straight piece lies at or under the lower of its two ends,
# so drawing it can never lift the gain above what either end allows.
BLOCK_S = 0.001
# Long enough that the dip is a fade rather than a step -- a step is a
# click -- and short enough not to duck the beat before a hit.
ATTACK_S = 0.005
# Measured on three tracks Platinum Notes had also levelled (2026-10-29),
# all brought to -11.5 LUFS-I: at 80 ms Laura Branigan's "Self Control"
# was being limited 55% of the time and Cocteau Twins lost 0.8 LU of
# loudness range to it; at 20 ms, 19% and 0.5 LU, and with a 0 dB ceiling
# within 0.15 LU of what PN left. 5 ms limited less again, but a release
# shorter than one cycle of a 50 Hz bass note bends the note itself.
RELEASE_S = 0.020
# Aimed this far under the ceiling, for the waveform between samples that
# a changing gain moves a little; measured, and aimed lower if it was not
# enough.
MARGIN_DB = 0.1
# Close enough to the target to stop turning up and limiting again.
TOLERANCE_LU = 0.05
ATTEMPTS = 4


def peaks_per_sample(x: np.ndarray) -> np.ndarray:
    """|x| at each sample, taken as the tallest of its oversampled points
    and over both channels. Chunked like bs1770.true_peak_dbtp, for the
    same reason: the oversampled whole track is four copies of it."""
    n = x.shape[0]
    out = np.empty(n, dtype=np.float32)
    chunk, pad = 1 << 20, 1 << 13
    for start in range(0, n, chunk):
        lo, hi = max(0, start - pad), min(n, start + chunk + pad)
        seg = resample_poly(x[lo:hi].astype(np.float32), OVERSAMPLE, 1, axis=0)
        seg = np.abs(seg).max(axis=1)
        stop = min(n, start + chunk)
        core = seg[(start - lo) * OVERSAMPLE:(stop - lo) * OVERSAMPLE]
        out[start:stop] = core.reshape(-1, OVERSAMPLE).max(axis=1)
    # The sample itself too: the oversampler's filter can ring a hair under
    # a sample it passes through.
    return np.maximum(out, np.abs(x).max(axis=1))


def gain_curve(peaks: np.ndarray, rate: int, ceiling: float,
               floor: float = 0.0) -> np.ndarray:
    """Gain per sample keeping peaks * gain <= ceiling (linear), never
    below `floor`."""
    n = peaks.size
    block = max(1, int(round(BLOCK_S * rate)))
    blocks = -(-n // block)
    padded = np.zeros(blocks * block, dtype=np.float32)
    padded[:n] = peaks
    tallest = padded.reshape(blocks, block).max(axis=1)
    need = np.minimum(1.0, ceiling / np.maximum(tallest, 1e-12))
    need = np.maximum(need, floor)
    # One point at each block boundary, allowing no more than either block
    # it touches.
    points = np.empty(blocks + 1)
    points[0], points[-1] = need[0], need[-1]
    points[1:-1] = np.minimum(need[:-1], need[1:])

    # Attack. A minimum over the last A points, then a mean over the next
    # A of those: every value in that mean is a minimum that included this
    # point, so the mean is never above what this point allows -- and the
    # gain has already been on its way down for A points when it arrives.
    a = max(1, int(round(ATTACK_S / BLOCK_S)))
    held = sliding_window_view(np.concatenate([np.ones(a - 1), points]), a).min(axis=1)
    smooth = sliding_window_view(np.concatenate([held, np.full(a - 1, held[-1])]),
                                 a).mean(axis=1)

    # Release: down at once (the attack has already shaped it), back up no
    # faster than RELEASE_S. Rising toward `smooth` from under it, so never
    # above it. A plain loop: one step a millisecond, ~0.2 s a track.
    alpha = 1.0 - float(np.exp(-BLOCK_S / RELEASE_S))
    wanted = smooth.tolist()
    out = [1.0] * len(wanted)
    previous = 1.0
    for i, target in enumerate(wanted):
        previous = target if target <= previous else \
            previous + (target - previous) * alpha
        out[i] = previous

    at = np.arange(n, dtype=np.float64) / block
    return np.interp(at, np.arange(blocks + 1), np.asarray(out)).astype(np.float32)


def _loudness(weighted: np.ndarray, gain: np.ndarray, rate: int) -> dict:
    """The loudness fields bs1770.measure gives, for the audio this gain
    makes, from the track K-weighted ONCE. Weighting is a filter with a
    memory of milliseconds and the gain moves over tens of them, so
    weighting then scaling is weighting the scaled audio: within 0.001 LU
    of measuring it on three limited tracks (2026-10-29), at a third of
    the cost, which is what a loop of attempts spends its time on."""
    y = weighted * gain[:, None]
    momentary = bs1770._block_mean_square(y, bs1770.MOMENTARY_S,
                                          bs1770.MOMENTARY_HOP_S, rate)
    short = bs1770._block_mean_square(y, bs1770.SHORT_S, bs1770.SHORT_HOP_S, rate)
    short_l = bs1770._block_loudness(short) if short.size else np.array([])
    gated = short_l[short_l > bs1770.ABS_GATE] if short_l.size else np.array([])
    lufs_i = (bs1770._gated_mean(momentary, bs1770._block_loudness(momentary),
                                 bs1770.REL_GATE_I)
              if momentary.size else float("-inf"))
    return {
        "lufs_i": bs1770._clean(lufs_i),
        "s_max": bs1770._clean(float(gated.max())) if gated.size else None,
        "s_p95": bs1770._pct(gated, 95), "s_p90": bs1770._pct(gated, 90),
        "s_p50": bs1770._pct(gated, 50),
    }


def level(x: np.ndarray, rate: int, value: float, target: float,
          estimator: str, ceiling_dbtp: float, max_db: float):
    """Turn `x` (measuring `value` on `estimator`) to `target`, limiting
    its peaks to `ceiling_dbtp` by at most `max_db`.

    Returns (audio, gain_db, report), or None where the plain gain already
    fits under the ceiling and there is nothing for a limiter to do. Where
    reaching the target would take more than `max_db` off the peaks, the
    gain stops where `max_db` is enough and the track ends short of the
    target, as it would have without the limiter -- by less. The report
    carries the result's loudness and true peak, so it need not be
    measured again.
    """
    peaks = peaks_per_sample(x)
    top = float(peaks.max())
    if top <= 0:
        return None
    top_db = 20 * np.log10(top)
    wanted = target - value
    if max_db <= 0 or top_db + wanted <= ceiling_dbtp:
        return None
    aim = ceiling_dbtp - MARGIN_DB
    most = aim - top_db + max_db
    capped = wanted > most
    wanted = min(wanted, most)
    weighted = bs1770.k_weight(x, rate)

    def attempt(gain_db: float, aim_db: float) -> np.ndarray:
        scale = 10 ** (gain_db / 20)
        return scale * gain_curve(peaks * scale, rate, 10 ** (aim_db / 20))

    gain = attempt(wanted, aim)
    reached = _loudness(weighted, gain, rate)
    tries = 1
    while not capped and tries < ATTEMPTS:
        now = reached.get(estimator)
        if now is None or abs(target - now) < TOLERANCE_LU:
            break
        # Limiting took some loudness with it: put it back, and the peaks
        # that it pushes over are limited in turn.
        wanted = min(wanted + target - now, most)
        capped = wanted >= most
        gain = attempt(wanted, aim)
        reached = _loudness(weighted, gain, rate)
        tries += 1

    y = (x * gain[:, None]).astype(x.dtype)
    peak = bs1770.true_peak_dbtp(y, rate)
    if peak > ceiling_dbtp:
        # The gain changing between samples nudged the waveform between
        # them. Aim lower by what got through, once; loudness moves by a
        # fraction of that.
        aim -= peak - ceiling_dbtp + 0.02
        gain = attempt(wanted, aim)
        reached = _loudness(weighted, gain, rate)
        y = (x * gain[:, None]).astype(x.dtype)
        peak = bs1770.true_peak_dbtp(y, rate)
    curve = gain / (10 ** (wanted / 20))
    return y, float(wanted), {
        "applied": True,
        "reduction_db": float(-20 * np.log10(max(float(curve.min()), 1e-12))),
        "share": float(np.mean(curve < 10 ** (-0.1 / 20))),
        "attempts": tries,
        "short_of_target": bool(capped),
        "true_peak_dbtp": float(peak),
        "measured": {**reached, "true_peak_dbtp": float(peak)},
    }
