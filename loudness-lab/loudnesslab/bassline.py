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
- **On a deep note, in step with it.** Below 56 Hz the note is in the
  sub band itself, and an octave down is under 28 Hz -- felt more than
  heard, and what a club system's high-pass throws away. So a deep note
  gets a tone on its own pitch, and the problem above is solved by
  reading the phase: the tone's phase is taken from the ORIGINAL
  recording at that note, so it lands exactly on top of what is there
  and only ever adds. She Blinded Me With Science is the case: its notes
  sit around 41 Hz, and without this 5% of the track got a tone.
  Without the recording to lock to (`mix`), deep notes get nothing.
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
# How fast the deep-note tone follows the recording's phase: the phase is
# read through a low-pass this wide. Narrow enough that a kick's thump does
# not print itself into the tone, wide enough to settle within a note.
# Measured on half-second notes with a kick on each (tests/test_bassline):
# 4-20 Hz all put every note in step at 0.998; 2 Hz lags a note change
# (0.981); 60 Hz lets the kick in (97.8% of the tone at its note, against
# 99.95% here).
LOCK_HZ = 6.0


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


def tone(bass: np.ndarray, rate: int, n: int,
         mix: np.ndarray | None = None) -> tuple[np.ndarray, dict]:
    """The whole bassline sub, both tones summed, and the report -- see
    `tones`. For measuring; the sub stage wants them apart."""
    free, locked, report = tones(bass, rate, n, mix)
    return (free + locked).astype(np.float32), report


def tones(bass: np.ndarray, rate: int, n: int, mix: np.ndarray | None = None
          ) -> tuple[np.ndarray, np.ndarray, dict]:
    """The bassline sub for a track `n` samples long at `rate`, as two
    tones: a sine an octave under each note, and -- given the recording,
    `mix` -- one on each note under 56 Hz, in step with it (`locked`). As
    loud as the bass part is there. Unscaled: the sub stage sizes them.

    Apart because the sub stage may flip the polarity of what it adds, to
    reinforce the kick; flipping the locked tone would put it exactly out
    of step with its note, and take the note away.

    And a report: how much of the time a note was found, and how much of
    that got which tone."""
    f0, level = track(bass, rate)
    sub = sub_frequency(f0)
    deep = (f0 > 0) & (sub == 0) if mix is not None else np.zeros(f0.size, bool)
    report = {"voiced": float(np.mean(f0 > 0)) if f0.size else 0.0,
              "with_tone": float(np.mean(sub > 0)) if sub.size else 0.0,
              "median_note_hz": float(np.median(f0[f0 > 0])) if np.any(f0 > 0) else None,
              "median_sub_hz": float(np.median(sub[sub > 0])) if np.any(sub > 0) else None,
              "on_note": float(np.mean(deep)) if deep.size else 0.0,
              "median_deep_hz": float(np.median(f0[deep])) if np.any(deep) else None}
    free, locked = np.zeros(n), np.zeros(n)
    if not np.any(sub > 0) and not np.any(deep):
        return free.astype(np.float32), locked.astype(np.float32), report
    # Frame centres, in samples of the track.
    centres = (np.arange(f0.size) * (rate / FRAME_RATE)
               + WINDOW_S * rate / 2).astype(np.float64)
    at = np.arange(n, dtype=np.float64)
    if np.any(sub > 0):
        freq, envelope = _pitch_and_level(sub, level, centres, at, rate)
        free = envelope * np.sin(2 * np.pi * np.cumsum(freq) / rate)
    if np.any(deep):
        pitch = np.where(deep, f0, 0.0)
        freq, envelope = _pitch_and_level(pitch, level, centres, at, rate)
        phase = 2 * np.pi * np.cumsum(freq) / rate
        locked = envelope * np.cos(phase + _phase_of(mix, phase, rate))
    return free.astype(np.float32), locked.astype(np.float32), report


def _pitch_and_level(pitch: np.ndarray, level: np.ndarray, centres: np.ndarray,
                     at: np.ndarray, rate: int) -> tuple[np.ndarray, np.ndarray]:
    """A tone's frequency and envelope at every sample, from per-frame
    values: silent where `pitch` is 0."""
    amp = np.where(pitch > 0, level, 0.0)
    # Hold the last pitch through a rest, so the phase does not jump when
    # the note comes back; the amplitude is what silences it.
    held = pitch.copy()
    for i in range(1, held.size):
        if held[i] == 0:
            held[i] = held[i - 1]
    first = np.flatnonzero(held > 0)[0]
    held[:first] = held[first]
    freq = np.interp(at, centres, held)
    envelope = np.interp(at, centres, amp)
    # Rise and fall over SMOOTH_S, both ways, so no note starts or stops
    # with a click.
    smooth = butter(2, 1.0 / SMOOTH_S, btype="low", fs=rate, output="sos")
    return freq, np.maximum(sosfiltfilt(smooth, envelope), 0.0)


def _phase_of(mix: np.ndarray, phase: np.ndarray, rate: int) -> np.ndarray:
    """How far the recording's own component at the tone's frequency is
    ahead of `phase`, at every sample: add it, and a tone on the note's
    pitch lands in step with the note.

    The recording is heterodyned by the tone's running phase -- A cos(phase
    + theta) times e^(-i phase) is A/2 e^(i theta) plus a term at twice the
    note -- and low-passed at LOCK_HZ, which keeps the first and removes
    the second. Done at TRACK_RATE: a bass fundamental needs no more."""
    low = soxr.resample(_mono(mix), rate, TRACK_RATE, quality="VHQ")
    times = np.arange(low.size) * (rate / TRACK_RATE)
    here = np.interp(times, np.arange(phase.size, dtype=np.float64), phase)
    lock = butter(2, LOCK_HZ, btype="low", fs=TRACK_RATE, output="sos")
    ahead = (sosfiltfilt(lock, low * np.cos(here))
             - 1j * sosfiltfilt(lock, low * np.sin(here)))
    offset = np.unwrap(np.angle(ahead))
    return np.interp(np.arange(phase.size, dtype=np.float64), times, offset)


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


def what_it_did(heard: dict, share: float) -> str:
    """The log's line for a processed track, from `tones`' report."""
    said = []
    if heard["median_sub_hz"] is not None:
        said.append(f"a tone around {heard['median_sub_hz']:.0f} Hz under notes "
                    f"above 56 Hz, {heard['with_tone']:.0%} of the track")
    if heard.get("median_deep_hz") is not None:
        said.append(f"one in step with the deep notes around "
                    f"{heard['median_deep_hz']:.0f} Hz, {heard['on_note']:.0%} "
                    f"of the track")
    if not said:
        return "no bass notes found to follow, so the sub is under the kicks only"
    return f"{share:.0%} of the sub under the bassline: " + "; ".join(said)
