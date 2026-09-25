"""Air: harmonics where a shelf has nothing to lift.

This one is different from everything else here and the difference matters.
Every other stage restores something the measurement says was taken away:
a clipped peak, a flattened attack, a squashed chorus, an octave that a
1979 cutting lathe could not hold. This stage INVENTS. It generates
harmonics that were never in the recording, from content that was, and
mixes them in.

That is what an Aphex Aural Exciter does and why it exists. A high shelf
multiplies what is in the band, so where a band is empty -- a lossy codec
cut it, a tape rolled off -- a shelf raises the noise under it and nothing
else. A harmonic generator takes the octave BELOW and folds its overtones
upward, so 5 kHz of material becomes 10 and 15 and 20 kHz of new content.
Musically related to the source, which is why it reads as detail rather
than as hiss.

Because it invents, it is off by default and it is a taste control. What
it is NOT allowed to be is dishonest: the report says how much energy was
added and where, so "subtle" can be checked rather than assumed.

Aliasing is the whole engineering problem. A non-linearity generates
harmonics without end, and every one above Nyquist folds back down as an
inharmonic product -- which is grit, not air, and lands in exactly the
region being polished. Measured on a 7 kHz tone at 48 kHz: the 4th and
5th harmonics fold to 20 kHz and 13 kHz at -29.6 and -38.8 dB. Run the
non-linearity at 4x and filter on the way back and those become -91.1 and
-97.7 dB. Sixty decibels, for one resampling either side.

The 4x up and down is `soxr` (libsoxr) rather than scipy's
`resample_poly` -- same job, a purpose-built C resampler instead of
scipy's general one, and about 4x faster on a full track, measured.
`TestAliasing` in `tests/test_air.py` is what actually enforces the
sixty decibels above; it passes unchanged, so re-measuring the exact
pair for this resampler was not worth guessing at a different
methodology.
"""

from __future__ import annotations

import numpy as np
import soxr
from scipy.signal import butter, sosfilt, sosfiltfilt

from . import bs1770

DEFAULT_AIR_DB = 0.0            # off
# Where the source material is taken from. The harmonics land an octave
# and more above this, so 3.5 kHz feeds 7 kHz upward -- presence and air,
# not the sibilance region, which is what a lower tune would emphasise.
DEFAULT_TUNE_HZ = 3500.0
# The band the amount is measured in, matching what the survey reports as
# the top end. The control means "raise this band by N dB", which is a
# statement that can be checked afterwards rather than a mix knob.
BAND_LOW_HZ = 8000.0
BAND_HIGH_HZ = 20000.0
OVERSAMPLE = 4
# Asymmetry. A symmetric curve gives odd harmonics only, which is the
# harder, hollower sound; the offset tips it so even orders come through
# too, and the second harmonic is the one that reads as sweetness.
BIAS = 0.35
# Measured, not picked. The band energy is normalised, so drive does not
# change how much air comes out -- it changes what it COSTS in peak, and
# that cost is a U. Asking +3 dB on a fixture with everything above 16 kHz
# removed:
#
#   drive   0.25   0.50   0.75   1.00   1.50   2.00   3.00
#   peak +  2.50   2.11   2.47   2.79   3.34   3.77   4.33
#
# with the 16-22 kHz content flat at -45.1 to -45.4 throughout. Half is
# the floor of that curve: low enough that the residue is mostly second
# harmonic and therefore smooth, high enough that it does not need a large
# mix gain to reach the target.
DRIVE = 0.5
# Below this there is nothing up there to make harmonics FROM, and what
# the stage would be exciting is the noise floor.
MIN_SOURCE_DBFS = -60.0


def _band(x: np.ndarray, rate: int, low: float, high: float) -> np.ndarray:
    """Just the band the amount is measured in."""
    top = min(high, rate * 0.49)
    if top <= low:
        return np.zeros_like(x)
    return sosfiltfilt(butter(4, [low, top], btype="band", fs=rate,
                              output="sos"), x, axis=0)


def _band_energy(x: np.ndarray, rate: int, low: float, high: float) -> float:
    band = _band(x, rate, low, high)
    return float(np.mean(band * band))


def _blank(note: str | None = None) -> dict:
    return {"applied": False, "amount_db": 0.0, "measured_db": 0.0,
            "tune_hz": None, "peak_change_db": 0.0, "lufs_change_db": 0.0,
            "guided": False, "note": note}


def excite(x: np.ndarray, rate: int, amount_db: float = DEFAULT_AIR_DB,
           tune_hz: float = DEFAULT_TUNE_HZ,
           drive: float = DRIVE, bias: float = BIAS,
           guide: np.ndarray | None = None) -> tuple[np.ndarray, dict]:
    """Add `amount_db` of generated harmonics to the 8-20 kHz band.

    The amount is measured, not mixed: the harmonic signal is scaled so the
    band actually rises by the figure asked for, and the report says what
    it rose by. A mix control that means "some" is how an exciter ends up
    used at three times the intended depth.

    `guide`, per sample 0 to 1 (see `stems.load_air_guide`), is where the
    air goes. The gain is set exactly as without it, and the harmonics are
    then scaled by it: where the guide is open the track gets precisely the
    air `amount_db` would give it unguided, and less where the drums carry
    the top end. Subtler overall by design; `measured_db` is what the band
    rose by across the whole track.
    """
    if amount_db <= 0:
        return x, _blank("no air asked for")
    report = _blank()
    report["tune_hz"] = float(tune_hz)

    source = sosfiltfilt(butter(4, tune_hz, btype="high", fs=rate,
                                output="sos"), x, axis=0)
    level = float(np.sqrt(np.mean(source * source))) if source.size else 0.0
    if level <= 10 ** (MIN_SOURCE_DBFS / 20):
        report["note"] = (f"nothing above {tune_hz / 1000:.1f} kHz to make "
                          f"harmonics from")
        return x, report

    # Up, distort, down. The resampler filters on the way back, which is
    # what keeps the folded harmonics out; see the module docstring for
    # what it costs not to.
    #
    # soxr rather than scipy's resample_poly: same job (polyphase, filtered
    # resampling), a purpose-built C library instead of scipy's general
    # one -- about 4x faster on a full track, measured. `VHQ` because this
    # is exactly the aliasing suppression the module docstring measured and
    # the margin costs little next to that 4x.
    up = soxr.resample(source, rate, rate * OVERSAMPLE, quality="VHQ")
    shaped = np.tanh(drive * up + bias) - np.tanh(bias)
    # Subtract the curve's own small-signal gain, leaving only what is
    # genuinely non-linear. Without this the stage is mostly a high shelf
    # with a little distortion on it: tanh is very nearly linear near the
    # origin, so the "harmonic" path carries a scaled copy of the source,
    # it adds COHERENTLY with the dry signal, and the amount overshoots --
    # measured, +1 dB asked for came back as +3.13. It also makes the
    # whole argument for the stage false, since a shelf would then do the
    # same thing.
    #
    # The gain to remove is the derivative at zero: d/du tanh(drive*u +
    # bias) = drive * (1 - tanh^2(bias)).
    harmonics = soxr.resample(shaped - drive * (1 - np.tanh(bias) ** 2) * up,
                              rate * OVERSAMPLE, rate, quality="VHQ")
    harmonics = harmonics[:x.shape[0]]
    if harmonics.shape[0] < x.shape[0]:
        harmonics = np.pad(harmonics,
                           ((0, x.shape[0] - harmonics.shape[0]), (0, 0)))

    # Again, and causally this time. An asymmetric curve rectifies, so it
    # produces DC and a spray of difference tones BELOW the tune frequency
    # -- and those are the ones that sound like distortion rather than
    # like air. Only what the stage generated upward survives this.
    harmonics = sosfilt(butter(4, tune_hz, btype="high", fs=rate,
                               output="sos"), harmonics, axis=0)

    dry = _band(x, rate, BAND_LOW_HZ, BAND_HIGH_HZ)
    wet = _band(harmonics, rate, BAND_LOW_HZ, BAND_HIGH_HZ)
    before = float(np.mean(dry * dry))
    added = float(np.mean(wet * wet))
    if added <= 0 or before <= 0:
        report["note"] = "no usable band energy to work with"
        return x, report
    # Solve for the gain exactly rather than assuming the two are
    # uncorrelated. They are not: the second harmonic of 4-8 kHz material
    # lands at 8-16 kHz, where the source already lives, so there is a
    # cross term and it does not vanish. Treating the addition as
    # incoherent undershot by about 18% at every setting -- +3.0 dB asked
    # for came back as +2.45.
    #
    #   (dry + g*wet)^2 = dry^2 + 2*g*cross + g^2*wet^2 = dry^2 * 10^(a/10)
    #
    # which is a quadratic in g with one positive root.
    cross = float(np.mean(dry * wet))
    wanted = before * (10 ** (amount_db / 10) - 1.0)
    gain = float((-cross + np.sqrt(cross * cross + added * wanted)) / added)

    if guide is not None:
        harmonics = harmonics * np.asarray(guide, dtype=np.float64)[:, None]
        report["guided"] = True
        report["guide_mean"] = float(np.mean(guide))
    y = (x + gain * harmonics).astype(x.dtype)
    after = _band_energy(y, rate, BAND_LOW_HZ, BAND_HIGH_HZ)

    was, now = bs1770.measure(x), bs1770.measure(y)
    report.update({
        "applied": True,
        "amount_db": float(amount_db),
        # What the band actually did, which is the number worth reading.
        "measured_db": float(10 * np.log10(after / before)) if before > 0 else 0.0,
        "peak_change_db": _delta(now["true_peak_dbtp"], was["true_peak_dbtp"]),
        "lufs_change_db": _delta(now["lufs_i"], was["lufs_i"]),
    })
    return y, report


def _delta(after: float | None, before: float | None) -> float:
    if after is None or before is None:
        return 0.0
    return float(after - before)


def summarise(reports: list[dict]) -> str:
    done = [r for r in reports if r.get("applied")]
    if not reports:
        return "  Air: not asked for."
    if not done:
        return (f"  Air: nothing to work from on any of {len(reports)} "
                f"track(s).")
    asked = np.median([r["amount_db"] for r in done])
    got = np.median([r["measured_db"] for r in done])
    loud = np.median([r["lufs_change_db"] for r in done])
    return (f"  Air: {len(done)} of {len(reports)} excited. 8-20 kHz up "
            f"{got:+.2f} dB against {asked:+.1f} asked, loudness "
            f"{loud:+.2f} dB.\n"
            f"    These harmonics were not in the recording. This is the one "
            f"stage here that\n"
            f"    invents rather than restores, so listen before committing "
            f"a folder to it.")
