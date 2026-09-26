"""A sub that follows the bassline, not only the kick.

On some records the low end is the bass, not the drums: She Blinded Me
With Science ("the bass line is the kick drum and we are missing it"),
Blue Monday ("could be deeper"). A sub laid only under kicks cannot follow
that. This tracks the notes of the separated bass part and builds a tone
an octave under each.

As everywhere with stems: the bass part is only READ. Its notes and its
loudness decide the tone; the tone is synthesised, a pure sine, and added
to the untouched original. Nothing separated reaches the audio.

Three choices, each for a stated reason:

- **An octave under the note, never on it.** A tone at the note's own
  pitch would sum with the bass already there in whatever phase they
  happened to meet -- a boost on one note and a hole on the next. An
  octave down is a frequency the recording does not have, so it only
  adds. A note above 150 Hz goes two octaves down, to stay under 75 Hz.
- **Nothing under a note already deep.** Below 56 Hz the note is in the
  sub band itself, and an octave down is under 28 Hz -- felt more than
  heard, and what a club system's high-pass throws away. Those notes are
  left as they are.
- **The bass part's own loudness.** The tone rises and falls with the
  bass, note by note, so a staccato line stays staccato and a breakdown
  without bass gets no tone.

`share` decides how the added low end is split between this and the kick
bursts: in proportion to where the track's low end already is.
"""

from __future__ import annotations

import numpy as np
import soxr
from scipy.signal import butter, medfilt, sosfiltfilt

TRACK_RATE = 2000              # all a bassline's fundamental needs
FRAME_RATE = 100               # a pitch every 10 ms
WINDOW_S = 0.064               # two periods of a 31 Hz note
LOW_HZ, HIGH_HZ = 35.0, 250.0  # bass fundamentals: B0-ish to B3
# YIN's threshold on the cumulative-mean-normalised difference: under it a
# frame is a note. 0.15 is the paper's; a separated bass part is not a
# clean one, so a frame is voiced up to 0.3 and its pitch taken at the
# first dip under 0.15 where there is one.
YIN_THRESHOLD = 0.15
VOICED_BELOW = 0.3
# A frame quieter than this, against the bass part's loud frames (95th
# percentile), is silence -- a rest, or bleed from another part.
LEVEL_GATE_DB = -30.0
SUB_FLOOR_HZ = 28.0            # as subbass.SUB_FLOOR_HZ
SUB_CEILING_HZ = 75.0          # as subbass.SUB_CEILING_HZ
SMOOTH_S = 0.015               # rise and fall of the tone, against clicks


def _mono(y: np.ndarray) -> np.ndarray:
    y = np.asarray(y, dtype=np.float64)
    return y.mean(axis=1) if y.ndim == 2 else y


def track(bass: np.ndarray, rate: int) -> tuple[np.ndarray, np.ndarray]:
    """(f0, level) at FRAME_RATE: the bass part's note in Hz (0 where there
    is none) and its loudness (RMS in its fundamental's band).

    YIN (de Cheveigne and Kawahara, 2002) on the part low-passed and taken
    down to TRACK_RATE. The difference function is computed for every lag
    at once from running sums, so a five-minute track is a fraction of a
    second.
    """
    mono = _mono(bass)
    band = sosfiltfilt(butter(4, [LOW_HZ * 0.8, HIGH_HZ], btype="band",
                              fs=rate, output="sos"), mono)
    y = soxr.resample(band, rate, TRACK_RATE, quality="VHQ")
    width = int(WINDOW_S * TRACK_RATE)
    hop = TRACK_RATE // FRAME_RATE
    max_lag = int(TRACK_RATE / LOW_HZ) + 1
    frames = max(0, (y.size - width - max_lag) // hop + 1)
    if frames == 0:
        return np.zeros(0), np.zeros(0)
    starts = np.arange(frames) * hop

    def windowed(values: np.ndarray) -> np.ndarray:
        run = np.concatenate([[0.0], np.cumsum(values)])
        return run[starts + width] - run[starts]

    energy = windowed(y[:y.size] ** 2)
    diff = np.zeros((frames, max_lag + 1))
    for lag in range(1, max_lag + 1):
        shifted = np.concatenate([y[lag:], np.zeros(lag)])
        cross = windowed(y * shifted)
        later = windowed(shifted ** 2)
        diff[:, lag] = energy + later - 2 * cross
    # Cumulative-mean-normalised difference.
    running = np.cumsum(diff[:, 1:], axis=1)
    lags = np.arange(1, max_lag + 1)
    norm = np.ones_like(diff)
    norm[:, 1:] = diff[:, 1:] * lags / np.maximum(running, 1e-30)

    min_lag = int(TRACK_RATE / HIGH_HZ)
    f0 = np.zeros(frames)
    aperiodic = np.ones(frames)
    search = norm[:, min_lag:max_lag]
    for i in range(frames):
        row = search[i]
        under = np.flatnonzero(row < YIN_THRESHOLD)
        if under.size:
            # The first dip under the threshold, then down to its bottom.
            j = under[0]
            while j + 1 < row.size and row[j + 1] < row[j]:
                j += 1
        else:
            j = int(np.argmin(row))
        aperiodic[i] = row[j]
        if 0 < j < row.size - 1:
            a, b, c = row[j - 1], row[j], row[j + 1]
            bend = a - 2 * b + c
            j = j + (0.5 * (a - c) / bend if bend > 0 else 0.0)
        f0[i] = TRACK_RATE / (j + min_lag)

    level = np.sqrt(energy / width)
    loud = np.percentile(level, 95) if level.size else 0.0
    gate = loud * 10 ** (LEVEL_GATE_DB / 20)
    voiced = (aperiodic < VOICED_BELOW) & (level > gate) & (loud > 0)
    f0 = np.where(voiced, f0, 0.0)
    # A lone voiced or unvoiced frame, or an octave slip for one frame, is
    # the tracker and not the bass player.
    if f0.size >= 5:
        f0 = np.where(voiced, medfilt(f0, 5), 0.0)
        f0 = np.where(medfilt(voiced.astype(float), 5) > 0.5, f0, 0.0)
    return f0, level


def sub_frequency(f0: np.ndarray) -> np.ndarray:
    """The tone's pitch for each frame: an octave under the note, two for a
    note above 150 Hz; 0 where there is no note or it is already deep."""
    sub = np.asarray(f0, dtype=np.float64) / 2
    sub = np.where(sub > SUB_CEILING_HZ, sub / 2, sub)
    return np.where((f0 > 0) & (sub >= SUB_FLOOR_HZ), sub, 0.0)


def tone(bass: np.ndarray, rate: int, n: int) -> tuple[np.ndarray, dict]:
    """The bassline sub for a track `n` samples long at `rate`: a sine an
    octave under each note, as loud as the bass part is there. Unscaled --
    the sub stage sizes it. And a report: how much of the time a note was
    found, and how much of that got a tone."""
    f0, level = track(bass, rate)
    sub = sub_frequency(f0)
    report = {"voiced": float(np.mean(f0 > 0)) if f0.size else 0.0,
              "with_tone": float(np.mean(sub > 0)) if sub.size else 0.0,
              "median_note_hz": float(np.median(f0[f0 > 0])) if np.any(f0 > 0) else None,
              "median_sub_hz": float(np.median(sub[sub > 0])) if np.any(sub > 0) else None}
    if not np.any(sub > 0):
        return np.zeros(n, dtype=np.float32), report
    hop = rate / FRAME_RATE
    # Frame centres, in samples of the track.
    centres = (np.arange(sub.size) * hop
               + WINDOW_S * rate / 2).astype(np.float64)
    amp = np.where(sub > 0, level, 0.0)
    # Hold the last pitch through a rest, so the phase does not jump when
    # the note comes back; the amplitude is what silences it.
    held = sub.copy()
    for i in range(1, held.size):
        if held[i] == 0:
            held[i] = held[i - 1]
    first = np.flatnonzero(held > 0)[0]
    held[:first] = held[first]
    at = np.arange(n, dtype=np.float64)
    freq = np.interp(at, centres, held)
    envelope = np.interp(at, centres, amp)
    # Rise and fall over SMOOTH_S, both ways, so no note starts or stops
    # with a click.
    smooth = butter(2, 1.0 / SMOOTH_S, btype="low", fs=rate, output="sos")
    envelope = np.maximum(sosfiltfilt(smooth, envelope), 0.0)
    phase = 2 * np.pi * np.cumsum(freq) / rate
    return (envelope * np.sin(phase)).astype(np.float32), report


def share(drums: np.ndarray, bass: np.ndarray, rate: int,
          low: float = 30.0, high: float = 120.0) -> float:
    """How much of the track's low end the bass part carries, against the
    drum part: 0 is all kick, 1 is all bass. The added sub is split the
    same way, so it goes where the low end already is."""
    sos = butter(4, [low, high], btype="band", fs=rate, output="sos")
    energy_bass = float(np.mean(sosfiltfilt(sos, _mono(bass)) ** 2))
    energy_drums = float(np.mean(sosfiltfilt(sos, _mono(drums)) ** 2))
    total = energy_bass + energy_drums
    return energy_bass / total if total > 0 else 0.0
