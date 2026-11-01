"""Bass body: an even lift in 63-160 Hz, where the kick and bass have weight.

The sub works under 63 Hz and the mud cut over 200, and nothing looked at
the octave and a half between, which is where a record sounds thin or
full. Measured on Jeff's 80s batch against MODERN DANCE after processing
(2026-10-12): 80-125 Hz typically 4-8 dB under the reference, Lisa Lisa
10.8 at 80 Hz, while 31.5 Hz sat 12-17 dB OVER it -- deep synth bass
lines, which the sub's sizing then added to.

How it works, and why each part:

- **The band, zero-phase.** 56-180 Hz (the 63 and 160 Hz third-octave
  bands' outer edges) is taken out with a Butterworth run forwards and
  backwards, so it is in step with the track, and put back scaled:
  y = x + (g - 1) * band. At g = 1 the track is exactly what it was, and
  the skirts fall away either side.
- **Even, not dynamic.** Unlike the mud cut, which follows the music,
  thinness here is a property of the master -- EQ'd once, the whole way
  through -- so the lift is the same everywhere. A steady boost is also
  the easiest thing to judge by ear against the original.
- **Measured.** g is set so the band as a whole rises by the amount
  asked, through a steeper filter than the one the boost uses, and the
  figure reported is the measured rise -- as the sub, air and mud report
  theirs, not a knob that means "some". Never more than MAX_BOOST_DB.

Peaks rise with it; the levelling that runs last takes that back out.
"""

from __future__ import annotations

import numpy as np
from scipy.signal import butter, sosfiltfilt

LOW_HZ, HIGH_HZ = 56.0, 180.0
MAX_BOOST_DB = 10.0


def _blank(note: str | None = None) -> dict:
    return {"applied": False, "amount_db": 0.0, "measured_db": 0.0,
            "gain_db": 0.0, "note": note}


def _band(x: np.ndarray, rate: int, order: int = 2) -> np.ndarray:
    sos = butter(order, [LOW_HZ, HIGH_HZ], btype="band", fs=rate, output="sos")
    return sosfiltfilt(sos, x, axis=0)


def band_db(x: np.ndarray, rate: int) -> float:
    """The band's energy, in dB, through a steeper filter than the one the
    stage boosts with -- what the report measures by."""
    band = _band(np.asarray(x, dtype=np.float64), rate, order=4)
    return float(10 * np.log10(np.mean(band * band) + 1e-30))


def boost(x: np.ndarray, rate: int, amount_db: float) -> tuple[np.ndarray, dict]:
    """Raise 63-160 Hz by `amount_db`. Returns the audio and what was done."""
    if amount_db <= 0:
        return x, _blank("no body asked for")
    amount_db = min(float(amount_db), MAX_BOOST_DB)
    source = np.asarray(x, dtype=np.float64)
    stereo = source if source.ndim == 2 else source[:, None]
    before = band_db(stereo, rate)
    if before < -120:
        return x, _blank("nothing in 63-160 Hz to lift")
    band = _band(stereo, rate)

    def apply(gain_db: float) -> np.ndarray:
        return stereo + band * (10 ** (gain_db / 20) - 1.0)

    # The band boost raises the measured band by a little less than its
    # gain (the skirts are shallower than the measuring filter's), so a
    # few corrections land the measured figure on the amount asked for.
    gain = amount_db
    y = apply(gain)
    measured = band_db(y, rate) - before
    for _ in range(4):
        if abs(measured - amount_db) <= 0.02 or measured <= 0:
            break
        gain = min(gain * amount_db / measured, 2 * MAX_BOOST_DB)
        y = apply(gain)
        measured = band_db(y, rate) - before
    report = {"applied": True, "amount_db": amount_db,
              "measured_db": float(measured), "gain_db": float(gain),
              "note": None}
    out = y if source.ndim == 2 else y[:, 0]
    return out.astype(np.asarray(x).dtype), report
