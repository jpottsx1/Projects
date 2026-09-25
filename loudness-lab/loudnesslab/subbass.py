"""Prototype: kick-synchronised sub-bass synthesis.

The measurements say 1980s material sits 10-15 dB below modern in the
32-63 Hz octave while being identical from 80 Hz up. That is the shape a
dbx-120-style subharmonic synthesiser was built for -- energy an octave
below content that is already there.

This does NOT use the dbx's frequency divider. A divider flip-flops on zero
crossings, which needs a near-monophonic source; in a dense mix the 70-140 Hz
band holds the kick, the bassline and the bottom of everything else at once,
the tracking fails, and an octave below the wrong partial is a wrong bass
note. In dance and pop material most of the missing 32-63 Hz energy is kick,
so this instead detects the kick and lays a short decaying sine under it.
Nothing is pitch-tracked, so nothing can mistrack.

Unlike everything else in this project this is lossy and irreversible: it
decodes, changes the waveform and re-encodes. It writes FLAC to a separate
folder and never touches an original.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import numpy as np
from scipy.signal import butter, find_peaks, sosfilt, sosfiltfilt

# The octave the measurements say is missing.
SUB_LOW_HZ, SUB_HIGH_HZ = 31.5, 63.0
# Where the kick's own body lives, and what we detect on.
KICK_LOW_HZ, KICK_HIGH_HZ = 30.0, 100.0
# Nothing below this reaches a dancefloor; synthesising it only eats headroom.
SUB_FLOOR_HZ = 28.0
SUB_CEILING_HZ = 75.0

# Where a kick's "snap" lives: the beater click, not the body.
PUNCH_LOW_HZ, PUNCH_HIGH_HZ = 2000.0, 6000.0
DEFAULT_PUNCH_DECAY_MS = 8.0
PUNCH_RAMP_S = 0.001

DEFAULT_FREQ_HZ = 45.0
DEFAULT_DECAY_S = 0.12
MIN_KICK_SPACING_S = 0.12      # 500 BPM; beyond that it is not a kick pattern
ATTACK_S = 0.005               # ramp in, or the burst clicks
ONSET_RATIO = 1.5              # how far the fast envelope must rise above the slow
BACKTRACK_S = 0.045            # how far back to look for the start of the attack
BACKTRACK_FRACTION = 0.25


def _band(x: np.ndarray, rate: int, low: float, high: float) -> np.ndarray:
    mono = x.mean(axis=1) if x.ndim == 2 else x
    sos = butter(4, [low, high], btype="band", fs=rate, output="sos")
    return sosfilt(sos, mono.astype(np.float64))


def _band_power(x: np.ndarray, rate: int, low: float, high: float) -> float:
    """Mean square within a band, on the mono sum."""
    return float(np.mean(_band(x, rate, low, high) ** 2))


def _gain_for_increase(track_band: np.ndarray, sub_band: np.ndarray,
                       amount_db: float) -> float:
    """Exact gain that lifts the band by amount_db.

    Band power of (track + g*sub) is E_t + 2g*C + g^2*E_s, so the gain is the
    positive root of a quadratic rather than the sqrt(power ratio) an
    incoherent estimate gives. That distinction is not academic here: the
    burst is deliberately phase-aligned with the kick, so the cross term C is
    large, and assuming independence missed the target by 1.5 dB in one
    direction on one fixture and 0.8 dB the other way on another.
    """
    energy_track = float(np.mean(track_band ** 2))
    energy_sub = float(np.mean(sub_band ** 2))
    cross = float(np.mean(track_band * sub_band))
    if energy_sub <= 0:
        return 0.0
    wanted = energy_track * (10 ** (amount_db / 10) - 1)
    discriminant = cross ** 2 + energy_sub * wanted
    if discriminant < 0:
        return 0.0
    return max(0.0, (-cross + np.sqrt(discriminant)) / energy_sub)


def _envelope(signal: np.ndarray, rate: int, hz: float) -> np.ndarray:
    """Zero-phase envelope. filtfilt, not filt: a causal envelope lags the
    attack by 20-25 ms, and a sub burst that late against a 45 Hz cycle of
    22 ms flams and partly cancels what it was meant to reinforce."""
    return sosfiltfilt(butter(2, hz, btype="low", fs=rate, output="sos"),
                       np.abs(signal))


def detect_kicks(x: np.ndarray, rate: int,
                 drums: np.ndarray | None = None) -> tuple[np.ndarray, np.ndarray]:
    """(sample offsets, relative strengths) of kick onsets.

    `drums` is a separated drum stem (see `stems.py`), the same length as
    `x`. Given one, the detector reads it instead of the mix: the bassline
    shares this band with the kick, and on the stem it has been taken out.

    The discriminator is attack sharpness, not level: a fast envelope rising
    well above a slow one. A bass note that merely changes pitch does not do
    that, which is what a plain rising-edge detector kept mistaking for a
    kick. Measured against synthetic tracks with known kick positions, a
    bassline changing note on every beat and a kickless breakdown, this holds
    recall and precision around 0.9-1.0 from 96 to 174 BPM; the rising-edge
    version managed 0.52 recall and 0.30 precision on the same material.
    """
    source = x if drums is None else drums
    mono = source.mean(axis=1).astype(np.float64)
    band = sosfiltfilt(butter(4, [KICK_LOW_HZ, KICK_HIGH_HZ], btype="band",
                              fs=rate, output="sos"), mono)
    fast = _envelope(band, rate, 60.0)
    slow = _envelope(band, rate, 3.0)
    if not np.any(fast > 0):
        return np.array([], dtype=int), np.array([])

    # A ratio explodes wherever the track is near silent, so only consider
    # places with real energy in the band.
    floor = float(np.percentile(fast, 90)) * 1e-3 + 1e-12
    onset = (fast / (slow + floor)) * (fast > 0.15 * float(np.percentile(fast, 95)))
    peaks, _ = find_peaks(onset, height=ONSET_RATIO,
                          distance=max(1, int(MIN_KICK_SPACING_S * rate)))
    if peaks.size == 0:
        return np.array([], dtype=int), np.array([])

    peaks = _backtrack(peaks, fast, rate)
    strengths = fast[peaks]
    loudest = strengths.max()
    return peaks, (strengths / loudest if loudest > 0 else strengths)


# How far the tempo the kicks imply may sit from the BPM tag. Measured on
# 35 tagged tracks, detecting on a Demucs drum stem: where the kicks were
# right, the implied tempo came within 0.98-1.03 of the tag; the nearest
# wrong one was 1.25 away. 5% sits in that gap with room on both sides.
TEMPO_TOLERANCE = 0.05


def tempo_check(kicks: np.ndarray, rate: int,
                tagged_bpm: float | None) -> str | None:
    """Why the kicks found should NOT be trusted, or None if they can be.

    One kick per beat is what four-on-the-floor has, so the median gap
    between the kicks found should be one beat of the tagged tempo. Double
    means something between the beats is being read as a kick -- an octave
    bassline on the mix, or on a stem a funk pattern busier than one per
    beat -- and a burst under each would put sub on the off-beat.

    Half the tag is accepted: the kicks are real, one every other tagged
    beat, which is a half-time groove or a tag Serato doubled. Fewer
    detections than beats cannot put a burst anywhere it does not belong.
    """
    if tagged_bpm is None or not np.isfinite(tagged_bpm) or tagged_bpm <= 0:
        return None
    if kicks.size < 8:
        return None             # enhance() declines this itself, and says so
    implied = 60.0 / float(np.median(np.diff(kicks) / rate))
    for multiple in (1.0, 0.5):
        if abs(implied / (tagged_bpm * multiple) - 1.0) <= TEMPO_TOLERANCE:
            return None
    return (f"kicks imply {implied:.0f} BPM against a tag of "
            f"{tagged_bpm:.0f} -- not one kick per beat, so no sub")


def _backtrack(peaks: np.ndarray, fast: np.ndarray, rate: int) -> np.ndarray:
    """Move each onset from the peak of the ratio back to the attack's start.

    The ratio peaks once the envelope has already risen. Placing the burst
    there leaves it consistently late; walking back to where the envelope was
    still a quarter of its peak lands on the attack itself.
    """
    span = int(BACKTRACK_S * rate)
    out = np.empty(peaks.size, dtype=int)
    for index, peak in enumerate(peaks):
        low = max(0, peak - span)
        below = np.flatnonzero(fast[low:peak + 1] <= fast[peak] * BACKTRACK_FRACTION)
        out[index] = low + below[-1] if below.size else peak
    return out


def _burst(rate: int, freq: float, decay_s: float) -> np.ndarray:
    """One decaying sine, ramped in so the onset does not click."""
    length = int(decay_s * 4 * rate)
    t = np.arange(length) / rate
    burst = np.sin(2 * np.pi * freq * t) * np.exp(-t / decay_s)
    ramp = int(ATTACK_S * rate)
    if ramp > 1:
        burst[:ramp] *= 0.5 - 0.5 * np.cos(np.pi * np.arange(ramp) / ramp)
    return burst


def _lay_bursts(n: int, rate: int, kicks: np.ndarray, strengths: np.ndarray,
                freq: float, decay_s: float) -> np.ndarray:
    sub = np.zeros(n, dtype=np.float64)
    burst = _burst(rate, freq, decay_s)
    for offset, strength in zip(kicks, strengths):
        end = min(n, offset + burst.size)
        if end > offset:
            sub[offset:end] += burst[:end - offset] * strength
    # Keep it in the sub octave: nothing inaudible below, nothing muddy above.
    sub = sosfilt(butter(2, SUB_FLOOR_HZ, btype="high", fs=rate, output="sos"), sub)
    return sosfilt(butter(4, SUB_CEILING_HZ, btype="low", fs=rate, output="sos"), sub)


# Below this, the sub octave is not moving with the music. Calibrated
# against a static low-frequency floor, which reads about 11 dB, and real
# groove material, which reads in the forties.
MIN_LOW_ACTIVITY_DB = 20.0


def low_band_activity(x: np.ndarray, rate: int) -> float:
    """How much the sub octave swings over the track, in dB.

    Measured on the band's own envelope at a rhythm timescale, NOT on
    per-frame band levels. The frame version answers a different question and
    gets this one wrong: a 0.68 s window averages over several kicks, so a
    relentless groove -- which is the most musical low end there is -- reads
    as barely moving, while the same bass with breakdowns reads as lively.
    Measured that way a wall-to-wall funk record scored 10.9 dB and a static
    rumble 6.2, far too close to tell apart. On the envelope they are 43.7
    and 11.3.
    """
    band = sosfiltfilt(butter(4, [SUB_LOW_HZ, SUB_HIGH_HZ], btype="band",
                              fs=rate, output="sos"), x.mean(axis=1))
    envelope = sosfiltfilt(butter(2, 20.0, btype="low", fs=rate, output="sos"),
                           np.abs(band))
    envelope = envelope[envelope > 0]
    if envelope.size < rate:
        return float("nan")
    quiet = float(np.percentile(envelope, 10))
    loud = float(np.percentile(envelope, 90))
    if quiet <= 0 or loud <= 0:
        return float("nan")
    return float(20 * np.log10(loud / quiet))


def attack_contrast(x: np.ndarray, rate: int, kicks: np.ndarray,
                    low: float = PUNCH_LOW_HZ, high: float = PUNCH_HIGH_HZ,
                    window_s: float = 0.015) -> float:
    """How far the band leaps above its usual level at each kick, in dB.

    The metric for attack work. Global crest factor is not: a band-limited
    change lasting eight milliseconds does not move a track's overall
    peak-to-loudness ratio at all, which is why crest read +0.02 dB while the
    attacks were plainly being emphasised. Crest staying put is in fact the
    desirable outcome -- it says the track's overall dynamic character is
    untouched and only the micro-detail moved.
    """
    if kicks.size == 0:
        return float("nan")
    band = sosfiltfilt(butter(4, [low, high], btype="band", fs=rate,
                              output="sos"), x.mean(axis=1))
    envelope = sosfiltfilt(butter(2, 200.0, btype="low", fs=rate, output="sos"),
                           np.abs(band))
    baseline = float(np.median(envelope))
    if baseline <= 0:
        return float("nan")
    span = int(window_s * rate)
    peaks = [float(envelope[k:min(k + span, envelope.size)].max())
             for k in kicks if k + 8 < envelope.size]
    if not peaks:
        return float("nan")
    return float(20 * np.log10(np.median(peaks) / baseline))


def shape_attacks(x: np.ndarray, rate: int, kicks: np.ndarray,
                  strengths: np.ndarray, boost_db: float,
                  decay_ms: float = DEFAULT_PUNCH_DECAY_MS,
                  low: float = PUNCH_LOW_HZ,
                  high: float = PUNCH_HIGH_HZ) -> tuple[np.ndarray, dict]:
    """Emphasise the attack of each kick, WITHOUT adding energy to the band.

    This is a transient shaper, not an expander, and the difference is the
    whole point. An expander keys on absolute level over tens of milliseconds
    and so changes how loud passages sit against quiet ones -- it raises
    loudness range, which is exactly what makes tracks disagree with each
    other. This keys on where the kicks are, acts over a few milliseconds,
    and leaves loudness range alone.

    The band is renormalised afterwards to the energy it started with, so
    what changes is the distribution of that energy in time and not how much
    of it there is. Without that step this would be a treble boost wearing a
    transient shaper's name, and the long-term spectrum would show it.
    """
    info = {"punch_db": boost_db, "band_level_change_db": 0.0,
            "sustain_trim_db": 0.0}
    if boost_db <= 0 or kicks.size == 0:
        info["punch_db"] = 0.0
        return x, info

    sos = butter(4, [low, high], btype="band", fs=rate, output="sos")
    # Zero-phase, so that (x - band) is a true complement and recombining
    # cannot leave a phase-shifted residue behind.
    band = sosfiltfilt(sos, x, axis=0)
    rest = x - band

    envelope = np.ones(x.shape[0], dtype=np.float64)
    decay = decay_ms / 1000.0
    length = max(2, int(decay * 5 * rate))
    t = np.arange(length) / rate
    shape = (10 ** (boost_db / 20) - 1.0) * np.exp(-t / decay)
    ramp = int(PUNCH_RAMP_S * rate)
    if ramp > 1:
        shape[:ramp] *= 0.5 - 0.5 * np.cos(np.pi * np.arange(ramp) / ramp)
    for offset, strength in zip(kicks, strengths):
        end = min(x.shape[0], offset + length)
        if end > offset:
            envelope[offset:end] += shape[:end - offset] * strength

    shaped = band * envelope[:, None]
    before = float(np.mean(band.astype(np.float64) ** 2))
    after = float(np.mean(shaped.astype(np.float64) ** 2))
    if before > 0 and after > 0:
        trim = np.sqrt(before / after)
        shaped = shaped * trim
        info["sustain_trim_db"] = float(20 * np.log10(trim))
        info["band_level_change_db"] = float(
            10 * np.log10(np.mean(shaped.astype(np.float64) ** 2) / before))
    return (rest + shaped).astype(np.float32), info


def _blank_report(amount_db: float) -> dict:
    """What enhance() reports before it has done anything."""
    return {"kicks": 0, "kicks_per_minute": 0.0, "requested_db": amount_db,
            "applied_db": 0.0, "polarity_flipped": False,
            "safety_trim_db": 0.0, "punch_db": 0.0, "sustain_trim_db": 0.0,
            "band_level_change_db": 0.0, "note": None}


def enhance(x: np.ndarray, rate: int, amount_db: float = 5.0,
            freq: float = DEFAULT_FREQ_HZ,
            decay_s: float = DEFAULT_DECAY_S,
            punch_db: float = 0.0,
            punch_decay_ms: float = DEFAULT_PUNCH_DECAY_MS,
            drums: np.ndarray | None = None) -> tuple[np.ndarray, dict]:
    """Add `amount_db` of energy to the 31.5-63 Hz octave, under the kicks.

    `drums`, if given, is where the kicks are found -- see `detect_kicks`.
    Only the detection moves: the sub is still added to `x`, never to the
    stem, so nothing the separator got wrong reaches the audio.

    Returns the new audio and a report of what was actually done, because the
    point of a prototype is to be checked rather than believed.
    """
    if amount_db <= 0 and punch_db <= 0:
        # Nothing asked for. Say so and return the same array, rather than
        # spending a kick detection to arrive at x + 0.
        report = _blank_report(amount_db)
        report["note"] = "no spectral change asked for"
        return x, report

    kicks, strengths = detect_kicks(x, rate, drums)
    report = _blank_report(amount_db)
    report["kicks"] = int(kicks.size)
    report["kicks_per_minute"] = (kicks.size / (x.shape[0] / rate / 60)
                                  if x.shape[0] else 0.0)
    if kicks.size < 8:
        report["note"] = "too few kick onsets to work from"
        return x, report

    if amount_db <= 0 and punch_db > 0:
        out, punch_info = shape_attacks(x, rate, kicks, strengths, punch_db,
                                        punch_decay_ms)
        report.update(punch_info)
        return out, report

    sub = _lay_bursts(x.shape[0], rate, kicks, strengths, freq, decay_s)
    if float(np.mean(sub ** 2)) <= 0:
        report["note"] = "synthesis produced nothing"
        return x, report

    track_band = _band(x, rate, SUB_LOW_HZ, SUB_HIGH_HZ)
    sub_band = _band(sub, rate, SUB_LOW_HZ, SUB_HIGH_HZ)
    if float(np.mean(sub_band ** 2)) <= 0:
        report["note"] = "synthesis landed outside the target band"
        return x, report

    # Reinforce rather than fight what is already under the kick.
    if float(np.mean(track_band * sub_band)) < 0:
        sub, sub_band = -sub, -sub_band
        report["polarity_flipped"] = True

    gain = _gain_for_increase(track_band, sub_band, amount_db)
    existing = float(np.mean(track_band ** 2))
    out = x + np.column_stack([sub * gain, sub * gain])

    # The band change is measured BEFORE any trim. A trim scales everything
    # equally, so it moves level without touching spectral balance -- and
    # spectral balance is the entire point here. Reporting the two together
    # made a correct +5 dB lift read as +3.4 on a track that happened to need
    # 1.6 dB of headroom.
    after = _band_power(out, rate, SUB_LOW_HZ, SUB_HIGH_HZ)
    if existing > 0 and after > 0:
        report["applied_db"] = float(10 * np.log10(after / existing))

    # Adding energy raises the peak. Keep the file writable; the level pass
    # that follows sets the final loudness anyway.
    # Punch after the sub: the sub is part of the kick now, and shaping the
    # attack of the finished kick is what the ear is judging.
    if punch_db > 0:
        out, punch_info = shape_attacks(out, rate, kicks, strengths, punch_db,
                                        punch_decay_ms)
        report.update(punch_info)

    peak = float(np.abs(out).max())
    if peak > 0.99:
        trim = 0.99 / peak
        out = out * trim
        report["safety_trim_db"] = float(20 * np.log10(trim))
    return out.astype(np.float32), report


def write_flac(path: Path, x: np.ndarray, rate: int,
               source: Path | None = None) -> None:
    """Write FLAC, carrying the source's tags across.

    FLAC rather than MP3 deliberately: this stage has already spent one
    decode, and a second lossy encode would give away more than the sub is
    worth. From here the file is lossless.
    """
    command = ["ffmpeg", "-nostdin", "-v", "error", "-y",
               "-f", "f32le", "-ar", str(rate), "-ac", "2", "-i", "-"]
    if source is not None:
        command += ["-i", str(source), "-map_metadata", "1"]
    command += ["-map", "0:a", "-c:a", "flac", str(path)]
    result = subprocess.run(command, input=np.clip(x, -1.0, 1.0)
                            .astype("<f4").tobytes(), capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace").strip()[:200])
