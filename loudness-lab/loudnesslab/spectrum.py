"""Long-term average spectrum in 1/3-octave bands, plus low-end diagnostics.

The point of this module is to answer three questions about a track's bottom
end that a single loudness number cannot:

  1. What shape is the low end, independent of how loud the track is?
     -> shape_db, the band level relative to the track's own broadband level.

  2. Is there real musical content down there, or a constant floor of rumble,
     hiss and vinyl noise that would just get louder if we EQ'd it?
     -> p10_db / p90_db per band. Content modulates with the music; a noise
        floor does not. A band with a 2 dB spread across the track is not
        carrying a bassline.

  3. Was this cut for vinyl?
     -> side_mid_db. Records cut before roughly 1990 were very often mono'd
        or elliptically EQ'd below 150-300 Hz to keep the stylus in the
        groove, which shows up as side energy collapsing in the low bands.
"""

from __future__ import annotations

import numpy as np

NFFT = 32768  # 1.46 Hz bins at 48 kHz -- enough to resolve the 25 Hz band
HOP = NFFT // 2
FRAME_CHUNK = 64  # frames per batched FFT, to bound peak memory

# Nominal ISO 1/3-octave centres, 20 Hz to 20 kHz.
BAND_CENTRES = (
    20.0, 25.0, 31.5, 40.0, 50.0, 63.0, 80.0, 100.0, 125.0, 160.0, 200.0,
    250.0, 315.0, 400.0, 500.0, 630.0, 800.0, 1000.0, 1250.0, 1600.0, 2000.0,
    2500.0, 3150.0, 4000.0, 5000.0, 6300.0, 8000.0, 10000.0, 12500.0,
    16000.0, 20000.0,
)
# Bands at or below this are "the bottom end" for reporting purposes.
LOW_BAND_MAX_HZ = 315.0

# A band this far below the track's broadband level carries no audible
# content, so its stereo relationship is whatever the anti-alias filters left
# behind -- uncorrelated numerical residue that reads as WIDE. Reporting that
# would invert the vinyl-mono signal exactly where we most want it, so the
# width figure is withheld instead.
MIN_SHAPE_FOR_WIDTH_DB = -40.0

# Frames quieter than this far below the track's loud frames are treated as
# silence (run-ins, gaps, digital black) and excluded from the statistics.
FRAME_GATE_LU = 40.0
FRAME_GATE_FLOOR_DB = -90.0


def _band_edges(rate: int) -> list[tuple[float, int, int]]:
    """(centre, first_bin, last_bin_exclusive) for each band inside Nyquist."""
    df = rate / NFFT
    nyquist = rate / 2
    edges = []
    for centre in BAND_CENTRES:
        lo = centre * 2 ** (-1 / 6)
        hi = centre * 2 ** (1 / 6)
        if hi >= nyquist:
            break
        first = max(1, int(np.ceil(lo / df)))
        last = int(np.floor(hi / df)) + 1
        if last <= first:  # band narrower than a bin; widen to one bin
            last = first + 1
        edges.append((centre, first, last))
    return edges


def _frame_band_power(x: np.ndarray, rate: int) -> tuple[np.ndarray, np.ndarray]:
    """Per-frame band mean-square and broadband mean-square for one channel.

    Normalised so that a full-scale sine inside a band reads 0.5 (i.e. its
    mean square), matching the dBFS-RMS convention used elsewhere.
    """
    window = np.hanning(NFFT).astype(np.float32)
    norm = NFFT * float((window.astype(np.float64) ** 2).sum())
    edges = _band_edges(rate)

    n_frames = 0 if x.shape[0] < NFFT else 1 + (x.shape[0] - NFFT) // HOP
    band_power = np.zeros((n_frames, len(edges)), dtype=np.float64)
    broadband = np.zeros(n_frames, dtype=np.float64)

    for start in range(0, n_frames, FRAME_CHUNK):
        stop = min(start + FRAME_CHUNK, n_frames)
        offsets = (np.arange(start, stop) * HOP)[:, None] + np.arange(NFFT)[None, :]
        frames = x[offsets] * window
        spec = np.abs(np.fft.rfft(frames, axis=1)).astype(np.float64) ** 2
        # One-sided: double everything but DC and Nyquist.
        spec[:, 1:-1] *= 2.0
        broadband[start:stop] = spec.sum(axis=1) / norm
        for i, (_, first, last) in enumerate(edges):
            band_power[start:stop, i] = spec[:, first:last].sum(axis=1) / norm

    return band_power, broadband


def _db(power: np.ndarray | float) -> np.ndarray | float:
    with np.errstate(divide="ignore"):
        return 10.0 * np.log10(np.maximum(power, 1e-30))


def analyse(x: np.ndarray, rate: int, source_is_mono: bool = False) -> list[dict]:
    """Per-band spectral statistics for a decoded stereo track.

    x is (n_samples, 2). Returns one dict per 1/3-octave band, ready to be
    written straight into the `bands` table.
    """
    if x.ndim != 2 or x.shape[1] != 2:
        raise ValueError(f"expected (n, 2) stereo, got {x.shape}")

    mid = ((x[:, 0] + x[:, 1]) * 0.5).astype(np.float32)
    side = ((x[:, 0] - x[:, 1]) * 0.5).astype(np.float32)

    mid_bands, mid_broad = _frame_band_power(mid, rate)
    if mid_bands.shape[0] == 0:
        return []

    # Gate out silence relative to the track's own loud frames.
    loud = np.percentile(_db(mid_broad), 95)
    threshold = max(loud - FRAME_GATE_LU, FRAME_GATE_FLOOR_DB)
    keep = _db(mid_broad) > threshold
    if keep.sum() < 4:
        keep = np.ones_like(keep)

    side_bands = None
    if not source_is_mono:
        side_bands, _ = _frame_band_power(side, rate)

    centres = [c for c, _, _ in _band_edges(rate)]
    broadband_db = float(_db(mid_broad[keep].mean()))

    rows = []
    for i, centre in enumerate(centres):
        col = mid_bands[keep, i]
        ltas_db = float(_db(col.mean()))
        row = {
            "band_hz": centre,
            "ltas_db": _finite(ltas_db),
            "shape_db": _finite(ltas_db - broadband_db),
            "p10_db": _finite(float(np.percentile(_db(col), 10))),
            "p90_db": _finite(float(np.percentile(_db(col), 90))),
            "side_mid_db": None,
        }
        if side_bands is not None and (ltas_db - broadband_db) >= MIN_SHAPE_FOR_WIDTH_DB:
            side_mean = float(side_bands[keep, i].mean())
            mid_mean = float(col.mean())
            if mid_mean > 0 and side_mean > 0:
                row["side_mid_db"] = _finite(10.0 * np.log10(side_mean / mid_mean))
        rows.append(row)
    return rows


def _finite(value: float) -> float | None:
    return None if not np.isfinite(value) else round(float(value), 3)
