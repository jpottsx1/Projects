"""ITU-R BS.1770-4 loudness measurement, plus EBU Tech 3342 loudness range.

This is the reference implementation for the project: it is validated against
ffmpeg's ebur128 filter in tests/test_bs1770.py, and the eventual Swift port
should be validated against it in turn.

Everything runs at 48 kHz. The K-weighting coefficients published in BS.1770-4
are defined at that rate, and deriving them for other rates is an extra source
of error we do not need -- decode.py resamples on the way in.

Note on the short-term percentiles: these are the numbers the project actually
cares about. Matching tracks on the 95th percentile of short-term loudness is
what keeps the loud sections of a dynamic record level with a flat modern
master; see README for why integrated loudness does not.
"""

from __future__ import annotations

import numpy as np
from scipy.signal import lfilter, resample_poly

RATE = 48000

# BS.1770-4 Table 1/2: stage 1 high shelf, stage 2 RLB high-pass, at 48 kHz.
_STAGE1_B = np.array([1.53512485958697, -2.69169618940638, 1.19839281085285])
_STAGE1_A = np.array([1.0, -1.69065929318241, 0.73248077421585])
_STAGE2_B = np.array([1.0, -2.0, 1.0])
_STAGE2_A = np.array([1.0, -1.99004745483398, 0.99007225036621])

OFFSET = -0.691  # BS.1770-4 eq. 2
ABS_GATE = -70.0  # LUFS, absolute gate
REL_GATE_I = -10.0  # LU below the ungated mean, for integrated loudness
REL_GATE_LRA = -20.0  # LU below the ungated mean, for LRA (EBU Tech 3342)

MOMENTARY_S = 0.400
MOMENTARY_HOP_S = 0.100  # 75% overlap, as specified
SHORT_S = 3.000
SHORT_HOP_S = 0.100  # what libebur128 and ffmpeg use for the S meter

# Stereo only. BS.1770 weights surround channels at 1.41; we decode to stereo.
WEIGHTS = np.array([1.0, 1.0])


def k_weight(x: np.ndarray, rate: int = RATE) -> np.ndarray:
    """Apply the two K-weighting stages. x is (n, channels)."""
    if rate != RATE:
        raise ValueError(f"K-weighting coefficients are 48 kHz only, got {rate}")
    y = lfilter(_STAGE1_B, _STAGE1_A, x.astype(np.float64), axis=0)
    return lfilter(_STAGE2_B, _STAGE2_A, y, axis=0)


def _block_mean_square(y: np.ndarray, win_s: float, hop_s: float,
                       rate: int = RATE) -> np.ndarray:
    """Mean square per block per channel -> (n_blocks, n_channels).

    Uses a cumulative sum so a 12-minute extended mix stays cheap. float64
    throughout; the residual error only ever affects blocks far below the
    -70 LUFS absolute gate, which are discarded anyway.
    """
    n, nch = y.shape
    win = int(round(win_s * rate))
    hop = int(round(hop_s * rate))
    if n < win:
        return np.zeros((0, nch))
    n_blocks = 1 + (n - win) // hop
    csum = np.empty((n + 1, nch), dtype=np.float64)
    csum[0] = 0.0
    np.cumsum(y * y, axis=0, out=csum[1:])
    start = np.arange(n_blocks) * hop
    return (csum[start + win] - csum[start]) / win


def _block_loudness(mean_square: np.ndarray) -> np.ndarray:
    """BS.1770-4 eq. 2: block loudness in LKFS from per-channel mean squares."""
    power = mean_square @ WEIGHTS
    with np.errstate(divide="ignore"):
        return OFFSET + 10.0 * np.log10(power)


def _gated_mean(mean_square: np.ndarray, loudness: np.ndarray,
                relative_gate: float) -> float:
    """Two-pass gating: absolute gate, then a gate relative to the result."""
    keep = loudness > ABS_GATE
    if not keep.any():
        return float("-inf")
    # The gating averages mean squares, not decibels.
    first = mean_square[keep].mean(axis=0) @ WEIGHTS
    threshold = OFFSET + 10.0 * np.log10(first) + relative_gate
    keep &= loudness > threshold
    if not keep.any():
        return float("-inf")
    return float(OFFSET + 10.0 * np.log10(mean_square[keep].mean(axis=0) @ WEIGHTS))


def true_peak_dbtp(x: np.ndarray, rate: int = RATE, oversample: int = 4) -> float:
    """Peak of the 4x-oversampled signal, in dBTP.

    Chunked so the oversampled buffer never gets large; chunks overlap and the
    overlap is discarded so the resampler's edge transients do not leak in.
    BS.1770-4 puts 4x oversampling within about 0.5 dB of the real peak, which
    is why the pipeline should aim at -1.0 dBTP rather than -0.1.
    """
    chunk = 1 << 20
    pad = 1 << 13
    peak = 0.0
    n = x.shape[0]
    for start in range(0, n, chunk):
        lo = max(0, start - pad)
        hi = min(n, start + chunk + pad)
        seg = resample_poly(x[lo:hi].astype(np.float32), oversample, 1, axis=0)
        head = (start - lo) * oversample
        tail = seg.shape[0] - (hi - (start + chunk)) * oversample if hi > start + chunk else seg.shape[0]
        core = seg[head:tail]
        if core.size:
            peak = max(peak, float(np.abs(core).max()))
    return _to_db(peak)


def _to_db(amplitude: float) -> float:
    return 20.0 * np.log10(amplitude) if amplitude > 0 else float("-inf")


def count_clipping(x: np.ndarray, threshold: float = 0.9995,
                   run_length: int = 4) -> tuple[int, int]:
    """(samples at or above full scale, runs of consecutive such samples).

    Consecutive full-scale samples are the signature of a master that was
    already clipped before it reached us -- worth knowing before deciding
    whether a track is a candidate for anything beyond attenuation.
    """
    flat = np.abs(x).max(axis=1) >= threshold
    clipped = int(flat.sum())
    if clipped == 0:
        return 0, 0
    # Count maximal runs of length >= run_length.
    padded = np.concatenate([[False], flat, [False]])
    edges = np.flatnonzero(padded[1:] != padded[:-1])
    lengths = edges[1::2] - edges[0::2]
    return clipped, int((lengths >= run_length).sum())


def measure(x: np.ndarray, rate: int = RATE) -> dict:
    """Full loudness measurement of a decoded stereo track.

    x is (n_samples, 2) in [-1, 1]. Returns the loudness fields stored in the
    database, plus the raw gated short-term series for callers that want to
    plot the distribution.
    """
    if x.ndim != 2 or x.shape[1] != 2:
        raise ValueError(f"expected (n, 2) stereo, got {x.shape}")

    y = k_weight(x, rate)

    momentary_ms = _block_mean_square(y, MOMENTARY_S, MOMENTARY_HOP_S, rate)
    short_ms = _block_mean_square(y, SHORT_S, SHORT_HOP_S, rate)

    momentary_l = _block_loudness(momentary_ms) if momentary_ms.size else np.array([])
    short_l = _block_loudness(short_ms) if short_ms.size else np.array([])

    lufs_i = (_gated_mean(momentary_ms, momentary_l, REL_GATE_I)
              if momentary_ms.size else float("-inf"))

    # Percentiles are taken over absolutely-gated short-term values, so a long
    # silent intro or run-out does not drag the low percentiles down.
    gated_short = short_l[short_l > ABS_GATE] if short_l.size else np.array([])

    result = {
        "lufs_i": _clean(lufs_i),
        "lra": _lra(short_ms, short_l),
        "s_max": _clean(float(gated_short.max())) if gated_short.size else None,
        "s_p95": _pct(gated_short, 95),
        "s_p90": _pct(gated_short, 90),
        "s_p50": _pct(gated_short, 50),
        "s_p10": _pct(gated_short, 10),
        "true_peak_dbtp": _clean(true_peak_dbtp(x, rate)),
        "sample_peak_dbfs": _clean(_to_db(float(np.abs(x).max()))),
    }
    clipped, runs = count_clipping(x)
    result["clipped_samples"] = clipped
    result["clip_runs"] = runs
    if result["true_peak_dbtp"] is not None and result["lufs_i"] is not None:
        result["crest_db"] = result["true_peak_dbtp"] - result["lufs_i"]
    else:
        result["crest_db"] = None
    result["_short_term"] = gated_short
    return result


def _lra(short_ms: np.ndarray, short_l: np.ndarray) -> float | None:
    """EBU Tech 3342 loudness range: P95 - P10 of gated short-term loudness."""
    if short_ms.size == 0:
        return None
    keep = short_l > ABS_GATE
    if keep.sum() < 2:
        return None
    first = short_ms[keep].mean(axis=0) @ WEIGHTS
    threshold = OFFSET + 10.0 * np.log10(first) + REL_GATE_LRA
    keep &= short_l > threshold
    values = short_l[keep]
    if values.size < 2:
        return None
    return float(np.percentile(values, 95) - np.percentile(values, 10))


def _pct(values: np.ndarray, q: float) -> float | None:
    return _clean(float(np.percentile(values, q))) if values.size else None


def _clean(value: float) -> float | None:
    """-inf and NaN become NULL rather than poisoning downstream statistics."""
    return None if value is None or not np.isfinite(value) else float(value)
