"""Intro edits: a track that starts cold, given an intro made from itself.

A song that opens straight into the groove (or the vocal) leaves a DJ
nowhere to mix in. This builds a run of bars in front of it out of the
song's own instrumental, so the mix has room and the song then arrives
exactly where it always did, on the grid:

    [ loop of the instrumental, tiled to N bars ][ the original, untouched ]

The steps, and what each leans on:

    1. separate    stems.separate: drums, bass, other, vocals. The
                   instrumental is drums + bass + other; the vocal is what
                   is left out of the loop.
    2. grid        the kicks on the drum stem give the tempo and where the
                   beats fall (`fit_grid`); the accents give which beat is
                   the first of the bar (`find_downbeat`).
    3. join        the first bar line at or after the song's first sound.
                   A vocal that starts a beat or two ahead of it (a pickup)
                   is kept: the original takes over from the pickup, so the
                   vocal comes in by itself, mid-phrase, as it was sung.
    4. loop        a bar-aligned stretch with the least vocal in it and a
                   real groove (`candidates`), repeated back from the join
                   so the last repeat ends exactly on the bar line.
    5. seams       each repeat is crossfaded into the next over a few
                   milliseconds taken from just before the kick, so the
                   attack itself is never inside a fade.

The original's samples after the join are copied as they are; only their
position moves, by a whole number of bars. Nothing is time-stretched.

The grid is a constant tempo with a fitted phase. A record played live,
drifting a few percent, will not hold it; `Grid.coherence` says how well
the kicks agreed, and `render` warns when it is low rather than producing
a loop that flams.
"""

from __future__ import annotations

import gc
import json
import os
import select
import sys
import time
from dataclasses import dataclass, field
from fractions import Fraction
from pathlib import Path

import numpy as np
from scipy.ndimage import uniform_filter1d
from scipy.signal import butter, fftconvolve, resample_poly, sosfilt, sosfiltfilt

from . import decode, stems, subbass, write

LENGTHS = (8, 16, 32)               # intro lengths offered, in bars
LOOP_BARS = (1, 2, 4, 8)            # loop lengths a source may have
DEFAULT_LOOP_BARS = 4
BEATS_PER_BAR = 4

# Crossfade at each seam and at the hand-over to the original, in seconds.
# Long enough that cutting a sustained bass note does not click, short
# enough that it sits inside the kick's own attack.
SEAM_S = 0.010
# The original comes in this long before the pickup / downbeat has to be
# whole, so the fade finishes before the first transient and leaves it
# alone.
GUARD_S = 0.002
# A fade over the very first samples, to keep the start of the file from
# clicking when the loop begins mid-waveform.
START_FADE_S = 0.0015

# Below this a first sound is silence: -50 dBFS.
SOUND_FLOOR = 10 ** (-50 / 20)
# How far before a beat the first sound may fall and still be "on" it,
# as a share of a beat.
ON_BEAT = 0.15

# The kick grid must agree to at least this firmly (the length of the mean
# phase vector, 1 = every kick on the same spot) to trust the loop on it.
MIN_COHERENCE = 0.6
# Which beat is the bar's first: if the accents point to one phase by at
# least this much more than the runner-up, believe them over the song's
# start; a start exactly on a beat needs more, because most cold starts
# ARE on the one.
DOWNBEAT_CONFIDENCE = 0.10
DOWNBEAT_CONFIDENCE_ON_START = 0.25

# Where the groove lands: a bar counts as "full" when the drum stem's level is
# within this many dB of its body level (the median of the track's middle
# half), and the song is taken to have arrived at the first bar that starts
# JOIN_SUSTAIN of them in a row. The bar line to join at is then the biggest
# jump in level within JOIN_LOOKBACK bars before that, which is the drop's
# own downbeat: a build that rises over several bars would otherwise be
# joined late. Drums vary more than a whole mix does, hence -6 and not -3.
JOIN_FULL_DB = -6.0
JOIN_SUSTAIN = 4
JOIN_LOOKBACK = 2
# A vocal lead-in ahead of a join partway through the song is kept, up to
# this many half-beats (2 beats), if the vocal there is at least this share
# of the vocal in the first bar of the song proper.
PICKUP_STEPS = 4
PICKUP_SHARE = 0.25

# What a loop source must be: this far under the instrumental in vocal
# level to count as vocal-free, with drums and body not more than this far
# below the track's typical bar.
VOCAL_FREE_DB = -20.0
MIN_DRUMS_DB = -6.0
MIN_LEVEL_DB = -6.0
# A loop's drums should come round again one loop later (Pearson r of the
# drum envelope of its first bar against the same place a loop on). Each
# step short of 1 costs this many dB of vocal in the ranking, and below
# MIN_REPEAT the seam is called out. Measured on three records (2026-10-03):
# the song's own opening, which builds, matched 0.3 against four bars on.
REPEAT_WEIGHT = 15.0
# Vocal level below this does not count against a loop: stems always leak a
# little, and -30 dB under the instrumental is inaudible. Without the floor
# a stem that is exactly silent scores -120 and no other term could ever
# outweigh it.
VOCAL_FLOOR_DB = -30.0
MIN_REPEAT = 0.6
# A loop is repeated four times in a 16 bar intro, so a fill in it is heard
# four times, the last one right before the song arrives. Each unit above
# FILL_OK that its most unusual bar deviates from the groove around it
# (`bar_deviation`) costs this many dB.
FILL_OK = 0.3
FILL_WEIGHT = 30.0
FILL_NOTED = 0.5                # from here the loop is called out as having a fill
DEVIATION_SLOTS = 16
# A loop is chosen to sound like the bars the song arrives with, not like the
# song's typical bar: how far its rhythm pattern is from theirs (0 = the same,
# summed over the loop's bars), how far its bar length (tempo) is, how far its
# pitch content is, and how far its level is. All traded in dB, like the rest.
FEEL_WEIGHT = 25.0
TEMPO_WEIGHT = 15.0             # per percent of bar length
CHROMA_WEIGHT = 30.0
JOIN_LEVEL_WEIGHT = 1.0
# A loop whose tempo differs from the song's at the join by more than the
# first number is resampled to it (a pitch change under a fifth of a semitone
# at the second); more than that is left alone and called out.
RETUNE_MIN = 0.0003
RETUNE_MAX = 0.012
# The song's own break or fill to end the intro on: a bar after which the drums
# come back at least this much louder, so the intro's last bar leads into the
# downbeat the way the song itself leads into one. The bar after it has to
# sound like the song's first bar (chroma, 1 = identical) or the join would
# change key at the seam.
LEAD_IN_JUMP_DB = 10.0
LEAD_IN_MATCH = 0.8


@dataclass
class Grid:
    bpm: float
    period: float                   # samples per beat, not rounded
    first_beat: float               # sample of one beat; others at +n*period
    coherence: float                # how firmly the kicks agree, 0-1
    downbeat_phase: int             # which beat (n % 4) starts a bar
    confidence: float               # how clearly accents chose that phase
    how: str                        # what chose the phase, for the report

    @property
    def bar(self) -> float:
        return self.period * BEATS_PER_BAR

    def beat(self, n: int) -> float:
        return self.first_beat + n * self.period


@dataclass
class Source:
    """A candidate stretch to loop."""
    bar: int                        # which bar line after the join, 0 = the join
    start: int                      # sample
    vocal_db: float                 # vocal against instrumental, dB (lower = cleaner)
    level_db: float                 # instrumental against the track's typical bar
    drums_db: float                 # drums against the track's typical bar
    vocal_free: bool
    seconds: float = 0.0            # where in the song, for the report
    length: int = 0                 # samples from its first bar line to the one after
    snapped: bool = True            # both ends tied to a real kick
    repeat: float = 1.0             # how well the drums repeat one loop later, -1..1
    fill: float = 0.0               # most unusual bar's deviation from the groove, 0 = none
    # How it compares with the bars the song arrives with (see `_reference`):
    feel: float = 0.0               # rhythm pattern distance, 0 = the same
    tempo_off: float = 0.0          # its bar length over theirs, minus 1
    chroma_match: float = 1.0       # pitch content, 1 = the same
    level_vs_join_db: float = 0.0   # its instrumental level minus theirs


@dataclass
class Analysis:
    rate: int
    original: np.ndarray            # (n, 2)
    instrumental: np.ndarray        # (n, 2): drums + bass + other
    vocals: np.ndarray              # (n, 2)
    drums: np.ndarray               # (n, 2)
    grid: Grid
    first_sound: int
    join: int                       # sample of the first bar line (the "downbeat")
    pickup: int                     # samples of lead-in before the join (0 = none)
    bar_lines: np.ndarray           # samples of every bar line from the join on
    snapped: np.ndarray = field(default_factory=lambda: np.array([], dtype=bool))
    kicks: np.ndarray = field(default_factory=lambda: np.array([], dtype=int))
    envelope: np.ndarray = field(default_factory=lambda: np.array([]))
    # Which bar line the song should arrive at (an index into `bar_lines`;
    # 0 is the first bar of the track), and why. See `suggest_join`.
    suggested_join_bar: int = 0
    join_reason: str = ""
    warnings: list[str] = field(default_factory=list)
    # The two stems the instrumental is made of, kept apart so an intro can
    # bring them in one at a time (`render` with style="build").
    bass: np.ndarray = field(default_factory=lambda: np.zeros((0, 2), dtype=np.float32))
    other: np.ndarray = field(default_factory=lambda: np.zeros((0, 2), dtype=np.float32))
    # Per-track work worth doing once (bar patterns, pitch content).
    cache: dict = field(default_factory=dict)


# ---------------------------------------------------------------- the grid

def fit_grid(kicks: np.ndarray, strengths: np.ndarray, rate: int,
             bpm: float) -> tuple[float, float, float] | None:
    """(period in samples, one beat's sample, coherence) from kick onsets.

    The tempo is read from the kicks' own spacing and the tag only says
    roughly where to look. Tags are often rounded (118 for 117.96) and
    sometimes a percent or two out; a grid placed by the tag drifts half
    a beat across a track and puts every kick in the wrong place, so the
    tag is trusted to about 3% and no further:

      1. the median gap between consecutive kicks, counted in beats of the
         tag, gives a first period that is right to a fraction of a percent;
      2. each kick is numbered by the beat it falls on, and the period and
         the first beat are fitted to the kicks that land within 12% of one
         (a syncopated kick between beats is not allowed to bend the fit);
      3. repeated until it settles.
    """
    if kicks.size < 8 or bpm <= 0:
        return None
    k = np.sort(kicks.astype(np.float64))
    weight = np.ones(k.size)
    if strengths.size == kicks.size:
        weight = strengths.astype(np.float64)[np.argsort(kicks)]
    period = 60.0 / bpm * rate
    gaps = np.diff(k)
    beats = np.round(gaps / period)
    usable = (beats >= 1) & (np.abs(gaps / (np.maximum(beats, 1) * period) - 1) < 0.03)
    if usable.sum() < 4:
        return None
    period = float(np.median(gaps[usable] / beats[usable]))

    first = float(k[0])
    near = np.ones(k.size, dtype=bool)
    for _ in range(4):
        index = np.round((k - first) / period)
        residual = k - (first + index * period)
        near = np.abs(residual) <= 0.12 * period
        if near.sum() < 8:
            return None
        slope, intercept = np.polyfit(index[near], k[near], 1, w=weight[near])
        period, first = float(slope), float(intercept)
    angle = np.exp(2j * np.pi * (k[near] - first) / period)
    coherence = float(abs((angle * weight[near]).sum() / weight[near].sum()))
    return period, first, coherence


def snap(sample: float, kicks: np.ndarray, period: float) -> int:
    """`sample` moved onto the real kick nearest it, if one is within a
    tenth of a beat. The fitted grid is right to a few hundred parts per
    million, which is several milliseconds by the end of a track; a loop
    cut that far from its kick lands late against it, and the original
    after the join does not."""
    if kicks.size:
        i = int(np.argmin(np.abs(kicks - sample)))
        if abs(kicks[i] - sample) <= 0.1 * period:
            return int(kicks[i])
    return int(round(sample))


def attack(drums_abs: np.ndarray, sample: float, kicks: np.ndarray,
           period: float, rate: int) -> tuple[int, bool]:
    """Where the kick nearest `sample` really begins.

    `snap` finds the detector's onset, which sits some milliseconds into
    the attack (it reads a 60 Hz envelope's rise). A cut made there would
    land inside the kick and the crossfade would eat its front. So look
    back from it on the drum stem for the first sample over 8% of the
    kick's peak: that is the attack, and the cuts go just ahead of it.
    Returns (sample, found): `found` is False when no kick was near enough
    and the grid's own position was used.
    """
    found = bool(kicks.size) and bool(np.min(np.abs(kicks - sample)) <= 0.1 * period)
    c = snap(sample, kicks, period)
    lo, hi = max(0, c - int(0.030 * rate)), min(len(drums_abs), c + int(0.030 * rate))
    if hi <= lo or not found:
        return c, found
    peak = float(drums_abs[lo:hi].max())
    if peak <= 0:
        return c, found
    over = np.nonzero(drums_abs[lo:min(hi, c + int(0.005 * rate))] > 0.08 * peak)[0]
    return (int(lo + over[0]) if over.size else c), found


def _low_band(x: np.ndarray, rate: int) -> np.ndarray:
    mono = x.mean(axis=1).astype(np.float64)
    return np.abs(sosfiltfilt(butter(2, 150.0, btype="low", fs=rate,
                                     output="sos"), mono))


def find_downbeat(low: np.ndarray, rate: int, period: float, first: float,
                  first_sound: int) -> tuple[int, float, str]:
    """(which beat, n % 4, starts a bar; confidence; what decided it).

    Accents: a bar's first beat carries the most low end more often than
    not (the bass changes there, the kick is not ducked). Each of the four
    phases is scored by its mean low-band energy over the loud part of the
    track. Four-on-the-floor records score all four alike, so a weak
    result falls back to the song's start: a track that starts cold, on a
    beat, starts on the one.
    """
    n_beats = int((len(low) - first) // period)
    if n_beats < 16:
        phase = _phase_of_start(first, period, first_sound)
        return phase, 0.0, "the song's start (too short to read accents)"
    starts = (first + np.arange(n_beats) * period).astype(int)
    span = max(1, int(0.4 * period))
    csum = np.concatenate([[0.0], np.cumsum(low)])
    energy = np.array([(csum[min(s + span, len(low))] - csum[s]) / span
                       for s in starts])
    loud = energy > 0.5 * np.median(energy)
    scores = np.zeros(BEATS_PER_BAR)
    for phase in range(BEATS_PER_BAR):
        picked = energy[(np.arange(n_beats) % BEATS_PER_BAR == phase) & loud]
        scores[phase] = picked.mean() if picked.size else 0.0
    order = np.argsort(scores)[::-1]
    best, second = scores[order[0]], scores[order[1]]
    confidence = float((best - second) / best) if best > 0 else 0.0

    start_phase = _phase_of_start(first, period, first_sound)
    on_start = _on_beat(first, period, first_sound)
    needed = DOWNBEAT_CONFIDENCE_ON_START if on_start else DOWNBEAT_CONFIDENCE
    if confidence >= needed:
        return int(order[0]), confidence, "the accents in the low end"
    return start_phase, confidence, "the song's start (the accents are even)"


def _on_beat(first: float, period: float, sample: int) -> bool:
    off = ((sample - first) / period + 0.5) % 1.0 - 0.5
    return abs(off) <= ON_BEAT


def _phase_of_start(first: float, period: float, first_sound: int) -> int:
    """n % 4 of the first beat at or just before the first sound."""
    n = int(np.ceil((first_sound - ON_BEAT * period - first) / period))
    return n % BEATS_PER_BAR


def first_sound_of(x: np.ndarray, rate: int) -> int:
    """The sample where the music begins: the first 20 ms of the track
    that holds more than -50 dBFS RMS."""
    mono = x.mean(axis=1)
    size = max(1, int(0.02 * rate))
    frames = len(mono) // size
    if frames == 0:
        return 0
    power = np.sqrt((mono[:frames * size].reshape(frames, size) ** 2).mean(axis=1))
    loud = np.nonzero(power > SOUND_FLOOR)[0]
    return int(loud[0] * size) if loud.size else 0


# ------------------------------------------------------------- the analysis

def analyse(x: np.ndarray, parts: dict[str, np.ndarray], rate: int,
            bpm: float, downbeat_s: float | None = None) -> Analysis:
    """Everything an intro needs from a decoded track and its four stems.

    `downbeat_s` overrides the downbeat search with a known bar line (the
    first one in the file, from a beat grid). The tempo is still fitted.
    """
    if bpm is None or bpm <= 0:
        raise ValueError("no tempo: the track has no BPM tag; pass one with "
                         "--bpm")
    instrumental = (parts["drums"] + parts["bass"] + parts["other"]).astype(np.float32)
    kicks, strengths = subbass.detect_kicks(x, rate, parts["drums"])
    fitted = fit_grid(kicks, strengths, rate, bpm)
    if fitted is None:
        raise ValueError("too few kicks to find a grid: this does not look "
                         "like a track with a steady kick drum")
    period, first, coherence = fitted

    first_sound = first_sound_of(x, rate)
    low = _low_band(parts["drums"] + parts["bass"], rate)
    if downbeat_s is not None:
        given = downbeat_s * rate
        n = int(round((given - first) / period))
        phase, confidence, how = n % BEATS_PER_BAR, 1.0, "the beat grid you gave"
    else:
        phase, confidence, how = find_downbeat(low, rate, period, first,
                                               first_sound)
    grid = Grid(bpm=60.0 * rate / period, period=period, first_beat=first,
                coherence=coherence, downbeat_phase=phase,
                confidence=confidence, how=how)

    return _layout(x, instrumental, parts["vocals"], parts["drums"], kicks, rate,
                   grid, first_sound, bass=parts["bass"], other=parts["other"])


def _layout(x: np.ndarray, instrumental: np.ndarray, vocals: np.ndarray,
            drums: np.ndarray, kicks: np.ndarray, rate: int, grid: Grid,
            first_sound: int, bass: np.ndarray | None = None,
            other: np.ndarray | None = None) -> Analysis:
    """Bar lines, join and pickup for a grid whose downbeat phase is decided.
    Split from `analyse` so `rephase` can lay the same track out again with
    another beat as the first of the bar, without separating anything."""
    period, coherence = grid.period, grid.coherence
    first = grid.first_beat
    phase = grid.downbeat_phase
    # The first bar line at or just before the first sound; a vocal that
    # begins ahead of it is a pickup.
    n = int(np.ceil((first_sound - ON_BEAT * period - first) / period))
    while n % BEATS_PER_BAR != phase:
        n += 1
    drums_abs = np.abs(drums.mean(axis=1))
    join, join_found = attack(drums_abs, grid.beat(n), kicks, period, rate)
    join = max(join, 0)
    pickup = max(0, join - first_sound) if join - first_sound > ON_BEAT * period else 0
    pickup = min(pickup, int(grid.bar))

    last = int((len(x) - join) // grid.bar)
    # Bar lines are followed, not computed: each is looked for one bar
    # after the LAST ONE FOUND, so a tempo the fit has slightly wrong (or a
    # drummer who pushes) is re-synchronised every bar instead of piling
    # up. Where no kick is near (a breakdown) the grid carries on from the
    # last real one.
    lines, found = [join], [join_found]
    for _ in range(last):
        line, hit = attack(drums_abs, lines[-1] + grid.bar, kicks, period, rate)
        lines.append(line)
        found.append(hit)
    bar_lines = np.array(lines)
    snapped = np.array(found)

    warnings = []
    if coherence < MIN_COHERENCE:
        warnings.append(
            f"the kicks agree on a grid only {coherence:.2f} (want "
            f"{MIN_COHERENCE:.2f}+): a live or drifting record, so the loop "
            "may not sit on the beat")
    if grid.confidence < DOWNBEAT_CONFIDENCE:
        warnings.append("which beat is the bar's first was a guess from the "
                        "song's start; check the join by ear")
    analysis = Analysis(
        rate=rate, original=x, instrumental=instrumental,
        vocals=vocals, drums=drums, grid=grid,
        first_sound=first_sound, join=join, pickup=pickup,
        bar_lines=bar_lines, snapped=snapped, kicks=kicks,
        envelope=uniform_filter1d(drums_abs, max(1, int(0.003 * rate))),
        warnings=warnings,
        **({} if bass is None else {"bass": bass}),
        **({} if other is None else {"other": other}))
    analysis.suggested_join_bar, analysis.join_reason = suggest_join(analysis)
    return analysis


def rephase(a: Analysis, beats: int) -> Analysis:
    """The same track with the bar lines moved `beats` beats later (negative:
    earlier): another beat is called the first of the bar. For when the
    accents misled the downbeat search. Nothing is separated again."""
    g = a.grid
    moved = Grid(bpm=g.bpm, period=g.period, first_beat=g.first_beat,
                 coherence=g.coherence,
                 downbeat_phase=(g.downbeat_phase + beats) % BEATS_PER_BAR,
                 confidence=1.0, how="set by hand")
    return _layout(a.original, a.instrumental, a.vocals, a.drums, a.kicks,
                   a.rate, moved, a.first_sound, bass=a.bass, other=a.other)


# ------------------------------------------------------------ where it joins

def suggest_join(a: Analysis) -> tuple[int, str]:
    """(bar index, why): the bar line where the song's groove lands.

    A track that opens straight into the groove joins at its first bar, as
    before. One with a long opening of its own (a pad, a fade-in, a soft
    verse before the drop) joins where the opening ends, and the opening is
    cut out: the new intro takes its place.

    The drop is where the DRUMS come in, so it is read off the drum stem's
    level bar by bar, not the whole mix's: a first version judged the mix,
    and a vocal swelling into the drop made the bar before it look like the
    arrival. Where the drum stem has nothing to find (a track with no
    drums), the whole mix is used instead.

    Only a starting point, and meant to be moved: "where the song really
    begins" is a judgement, and this can be fooled by drums that play under
    a long opening, or a drop that is quieter than what led into it.
    """
    lines = a.bar_lines
    bars = len(lines) - 1
    if bars < JOIN_SUSTAIN * 2:
        return 0, "the track is too short to look for a drop"

    def bar_levels(y: np.ndarray) -> np.ndarray:
        mono = y.mean(axis=1).astype(np.float64)
        return np.array([10.0 * np.log10(np.mean(mono[lines[i]:lines[i + 1]] ** 2) + 1e-12)
                         for i in range(bars)])

    mix = bar_levels(a.original)
    drums = bar_levels(a.drums)
    middle = slice(bars // 4, max(bars // 4 + 1, 3 * bars // 4))
    # Drums to read the drop from, unless they are not really there.
    use_drums = float(np.median(drums[middle])) > float(np.median(mix[middle])) - 30.0
    level = drums if use_drums else mix
    body = float(np.median(level[middle]))
    full = level >= body + JOIN_FULL_DB
    arrived = next((i for i in range(bars - JOIN_SUSTAIN + 1)
                    if full[i:i + JOIN_SUSTAIN].all()), None)
    if arrived is None:
        return 0, "nothing holds full level, so the first bar is used"
    if arrived == 0:
        return 0, "the track starts at full level"
    window = range(max(1, arrived - JOIN_LOOKBACK), arrived + 1)
    best = max(window, key=lambda k: level[k] - level[k - 1])
    what = "the drums come in" if use_drums else "the groove reaches full level"
    return int(best), (f"{what} at bar {best} ({lines[best] / a.rate:.1f} s in); "
                       "the opening before it is replaced")


def resolve_join(a: Analysis, join_bar: int) -> tuple[int, int]:
    """(sample of the join, samples of lead-in kept before it) for a bar.

    Bar 0 is the track's first bar, which keeps the lead-in found from the
    song's first sound; any later bar looks for a vocal lead-in on the
    vocal stem. Raises for a bar outside the track."""
    if not 0 <= join_bar < len(a.bar_lines) - 1:
        raise ValueError(f"join bar {join_bar} is outside the track "
                         f"(0 to {len(a.bar_lines) - 2})")
    join = int(a.bar_lines[join_bar])
    return join, (a.pickup if join_bar == 0 else pickup_before(a, join))


def pickup_before(a: Analysis, join: int) -> int:
    """Samples of vocal lead-in to keep ahead of a join partway through the
    song: the original takes over this long before the bar line, so a vocal
    that starts a beat or two ahead of the drop comes in as it was sung.

    Walks back from the join in half-beat steps while the vocal stem there is
    at least PICKUP_SHARE of what it is in the first bar after the join, up
    to PICKUP_STEPS of them. None of it if the song has no vocal there."""
    step = max(1, int(a.grid.period / 2))
    vocal = a.vocals.mean(axis=1).astype(np.float64)

    def rms(lo: int, hi: int) -> float:
        lo, hi = max(0, lo), min(len(vocal), hi)
        return float(np.sqrt(np.mean(vocal[lo:hi] ** 2))) if hi > lo else 0.0

    reference = rms(join, join + int(a.grid.bar))
    if reference <= 1e-6:
        return 0
    kept = 0
    for k in range(1, PICKUP_STEPS + 1):
        if rms(join - k * step, join - (k - 1) * step) >= PICKUP_SHARE * reference:
            kept = k * step
        else:
            break
    return kept


ENVELOPE_PER_SECOND = 50


def envelope(a: Analysis, per_second: int = ENVELOPE_PER_SECOND) -> dict:
    """The finished mix as three bands over time, for drawing the picker.

    Made here, from the same decoded audio the bar lines were found in, so
    a marker on a bar line sits on the transient it names: a picture decoded
    separately by another program can start a few tens of milliseconds
    off (decoders differ about an MP3's priming samples), and at full zoom
    that is visibly a different place.

    Bass is under 200 Hz, treble over 2 kHz, mid between: round numbers for
    a picture, the same split the app's waveform uses. RMS in windows of
    1/per_second, compressed (x ** 0.6) so quiet openings stay visible beside
    loud drops, on one shared 0-255 scale so the bands' balance is true.
    """
    return envelope_of(a.original, a.rate, per_second)


def envelope_of(audio: np.ndarray, rate: int, per_second: int = ENVELOPE_PER_SECOND) -> dict:
    """`envelope` for any stereo audio: the picker uses it on the original,
    the result card on the finished edit, so the two are drawn alike."""
    mono = audio.mean(axis=1).astype(np.float64)
    low = sosfilt(butter(2, 200.0, btype="low", fs=rate, output="sos"), mono)
    high = sosfilt(butter(2, 2000.0, btype="high", fs=rate, output="sos"), mono)
    mid = mono - low - high
    size = max(1, rate // per_second)
    n = len(mono) // size

    def rms(y: np.ndarray) -> np.ndarray:
        return np.sqrt((y[:n * size].reshape(n, size) ** 2).mean(axis=1))

    bands = {"bass": rms(low), "mid": rms(mid), "treble": rms(high)}
    ceiling = max(float(np.percentile(np.maximum.reduce(list(bands.values())), 99.5)), 1e-9)
    scaled = {name: np.clip(np.round(255 * (v / ceiling) ** 0.6), 0, 255).astype(int)
              for name, v in bands.items()}
    return {"per_second": rate / size, "seconds": len(mono) / rate,
            **{name: values.tolist() for name, values in scaled.items()}}


# ------------------------------------------------------------ loop sources

def _db(power: np.ndarray | float) -> np.ndarray | float:
    return 10.0 * np.log10(np.maximum(power, 1e-12))


def refine_length(a: Analysis, bar: int, loop_bars: int) -> tuple[int, float]:
    """Samples from bar line `bar` to the same place `loop_bars` bars later,
    measured the way a repeat will use it.

    Repeating a loop puts its first bar line right after its last one's
    length, so the length that matters is the record's OWN spacing there,
    not a tempo averaged over the song (a drummer who pushes through a
    chorus makes 0.15% of difference, and that was 12 ms of hiccup at each
    seam). It starts from the two bar lines' attack-to-attack distance,
    which is good to a millisecond, and refines it by lining up the drum
    envelope of the loop's first bar with the audio one loop on: where that
    matches best is where the pattern really comes round again, to a
    fraction of a millisecond, because a whole bar of hits is lined up and
    not one kick.

    Also returns how well they matched at that best place (Pearson r, 1 =
    the same bar again): a stretch that does not come round again, a build
    or a fill, has no length that makes its seam land, and it is better
    to know than to loop it.
    """
    start = int(a.bar_lines[bar])
    direct = int(a.bar_lines[bar + loop_bars] - a.bar_lines[bar])
    env = a.envelope
    width = min(int(a.grid.bar), len(env) - start - direct - 1)
    reach = int(0.025 * a.rate)
    if width < a.rate // 4 or start + direct - reach < 0:
        return direct, 0.0
    lo = start + direct - reach
    hi = start + direct + width + reach
    if hi > len(env):
        return direct, 0.0
    first = env[start:start + width]
    later = env[lo:hi]
    corr = fftconvolve(later - later.mean(), (first - first.mean())[::-1],
                       mode="valid")
    if corr.size != 2 * reach + 1 or not np.any(corr > 0):
        return direct, 0.0
    best = int(np.argmax(corr))
    seen = later[best:best + width]
    r = float(np.corrcoef(first, seen)[0, 1]) if seen.std() > 0 and first.std() > 0 else 0.0
    return direct + best - reach, r


def bar_patterns(a: Analysis) -> np.ndarray:
    """Per bar: its rhythm as DEVIATION_SLOTS slots (sixteenth notes, so half
    beats and the offbeats are in it), each the loudest the instrumental gets
    within a few milliseconds of the slot, scaled to the bar's own mean."""
    if "patterns" in a.cache:
        return a.cache["patterns"]
    lines = a.bar_lines
    bars = len(lines) - 1
    pattern = np.zeros((max(bars, 0), DEVIATION_SLOTS))
    if bars >= 1:
        env = uniform_filter1d(np.abs(a.instrumental.mean(axis=1)).astype(np.float64),
                               max(1, int(0.01 * a.rate)))
        half = max(1, int(0.015 * a.rate))
        for i in range(bars):
            length = lines[i + 1] - lines[i]
            for k in range(DEVIATION_SLOTS):
                c = int(lines[i] + k * length / DEVIATION_SLOTS)
                window = env[max(0, c - half):c + half]
                pattern[i, k] = window.max() if window.size else 0.0
        pattern /= pattern.mean(axis=1, keepdims=True) + 1e-12
    a.cache["patterns"] = pattern
    return pattern


def bar_deviation(a: Analysis) -> np.ndarray:
    """Per bar: how far its rhythm is from the groove around it, 0 for the
    same pattern again, about 1 for a bar that is mostly something else.

    Each bar is read as 16 slots (sixteenth notes, so half beats and the
    offbeats between them are in it): the loudest the instrumental gets within
    a few milliseconds of each slot, scaled to the bar's own mean. A bar is
    then compared slot by slot with the MEDIAN of the four bars either side.
    A fill, a break or a walking bass line is a bar that does not look like
    its neighbours; steady groove bars sit at 0.03-0.15 and fills at 0.6-1.0
    (measured on Break My Soul, 2026-10-04). Counting hits did not separate
    them: a groove already full of eighth notes has as many in a fill bar.
    """
    pattern = bar_patterns(a)
    bars = len(pattern)
    if bars < 1:
        return np.zeros(0)
    deviation = np.zeros(bars)
    for i in range(bars):
        near = [j for j in range(max(0, i - 4), min(bars, i + 5)) if j != i]
        if not near:
            continue
        usual = np.median(pattern[near], axis=0)
        deviation[i] = np.abs(pattern[i] - usual).sum() / (np.abs(usual).sum() + 1e-12)
    return deviation


def fill_of(deviation: np.ndarray, i: int, loop_bars: int) -> float:
    """The loop's most unusual bar: its `bar_deviation`. A loop is heard
    several times over, so one fill in it is heard every time."""
    window = deviation[i:i + loop_bars]
    return float(window.max()) if window.size else 0.0


def cost(s: Source) -> float:
    """Lower is a better loop: how much vocal is in it (floored), how badly
    it fails to repeat or holds a fill, and above all how little it sounds
    like the bars the song arrives with: rhythm, tempo, pitch content and
    level (`_reference`). An intro that is louder or busier than the song it
    leads into is a different song glued on. Dimensions are all roughly dB so
    they can be traded."""
    return (max(s.vocal_db, VOCAL_FLOOR_DB) + 0.25 * abs(s.level_db)
            + REPEAT_WEIGHT * (1.0 - max(s.repeat, 0.0))
            + FILL_WEIGHT * max(0.0, s.fill - FILL_OK)
            + FEEL_WEIGHT * s.feel
            + TEMPO_WEIGHT * 100.0 * abs(s.tempo_off)
            + CHROMA_WEIGHT * (1.0 - s.chroma_match)
            + JOIN_LEVEL_WEIGHT * abs(s.level_vs_join_db))


def _bar_powers(a: Analysis) -> dict | None:
    """Per bar: the instrumental's, the vocal's and the drums' power, and
    the track's typical bar for the first and last."""
    lines = a.bar_lines
    bars = len(lines) - 1
    if bars < 1:
        return None

    def power(y: np.ndarray) -> np.ndarray:
        mono = y.mean(axis=1).astype(np.float64)
        return np.array([np.mean(mono[lines[i]:lines[i + 1]] ** 2)
                         for i in range(bars)])

    inst, voc, drm = power(a.instrumental), power(a.vocals), power(a.drums)
    return {"inst": inst, "voc": voc, "drm": drm, "dev": bar_deviation(a),
            "typical_inst": np.median(inst[inst > 0]) if np.any(inst > 0) else 1.0,
            "typical_drm": np.median(drm[drm > 0]) if np.any(drm > 0) else 1.0}


def _reference(a: Analysis, join_bar: int, loop_bars: int) -> dict:
    """What the song sounds like where it arrives: the `loop_bars` bars from
    the join (fewer if the track ends sooner). A loop is judged against these
    bars' rhythm, pitch content, level and bar length."""
    lines = a.bar_lines
    bars = len(lines) - 1
    j = min(max(join_bar, 0), max(bars - 1, 0))
    n = max(1, min(loop_bars, bars - j))
    mono = a.instrumental.mean(axis=1).astype(np.float64)
    return {
        "bar": j, "n": n,
        "pattern": bar_patterns(a)[j:j + n],
        "chroma": bar_chroma(a)[j:j + n],
        "power": float(np.mean(mono[lines[j]:lines[j + n]] ** 2)),
        "bar_len": float(lines[j + n] - lines[j]) / n,
    }


def _compare(a: Analysis, ref: dict, i: int, loop_bars: int, length: int) -> dict:
    """A loop's distance from the reference (see `_reference`)."""
    patterns, chroma = bar_patterns(a), bar_chroma(a)
    k = min(ref["n"], loop_bars, len(patterns) - i)
    feel = float(np.mean([np.abs(patterns[i + t] - ref["pattern"][t]).sum()
                          / (np.abs(ref["pattern"][t]).sum() + 1e-12) for t in range(k)])) if k else 0.0
    match = float(np.mean([chroma[i + t] @ ref["chroma"][t]
                           / (np.linalg.norm(chroma[i + t]) * np.linalg.norm(ref["chroma"][t]) + 1e-12)
                           for t in range(k)])) if k else 1.0
    lines = a.bar_lines
    mono = a.instrumental.mean(axis=1).astype(np.float64)
    power = float(np.mean(mono[lines[i]:lines[i + loop_bars]] ** 2))
    return {"feel": feel, "chroma_match": match,
            "tempo_off": length / loop_bars / ref["bar_len"] - 1.0,
            "level_vs_join_db": float(_db(power / max(ref["power"], 1e-12)))}


def _measure(a: Analysis, powers: dict, i: int, loop_bars: int,
             ref: dict | None = None) -> Source:
    """The loop of `loop_bars` bars starting at bar `i`, measured. Its
    length is the attack-to-attack one until `refine_length` improves it."""
    w = slice(i, i + loop_bars)
    end = i + loop_bars
    vocal_db = float(_db(powers["voc"][w].mean() / max(powers["inst"][w].mean(), 1e-12)))
    return Source(
        bar=i, start=int(a.bar_lines[i]), vocal_db=vocal_db,
        level_db=float(_db(powers["inst"][w].mean() / powers["typical_inst"])),
        drums_db=float(_db(powers["drm"][w].mean() / powers["typical_drm"])),
        vocal_free=vocal_db <= VOCAL_FREE_DB, seconds=a.bar_lines[i] / a.rate,
        length=int(a.bar_lines[end] - a.bar_lines[i]),
        snapped=bool(a.snapped[i] and a.snapped[end]),
        fill=fill_of(powers["dev"], i, loop_bars),
        **({} if ref is None else _compare(a, ref, i, loop_bars,
                                          int(a.bar_lines[end] - a.bar_lines[i]))))


def candidates(a: Analysis, loop_bars: int = DEFAULT_LOOP_BARS,
               count: int = 5, join_bar: int | None = None) -> list[Source]:
    """The best stretches of `loop_bars` bars to loop, best first.

    Measured per bar: the vocal stem's power against the instrumental's,
    and the instrumental's and the drums' against the track's typical bar.
    A stretch qualifies with the drums playing and the body of the record
    there, which keeps a breakdown (where there is no vocal because there
    is no anything) from winning; of those the one with the least vocal in
    it comes first, then the one nearest the typical level, then the one
    that repeats best (see `cost`).

    Judged against the bars the song arrives with at `join_bar` (default:
    the suggested one): a loop that is busier, louder, faster or in another
    key than the song it leads into is rank-ordered down however clean it is.

    Non-overlapping, so the list offers real alternatives to audition and
    not the same four bars shifted by one.
    """
    if loop_bars not in LOOP_BARS:
        raise ValueError(f"loop_bars must be one of {LOOP_BARS}")
    powers = _bar_powers(a)
    bars = len(a.bar_lines) - 1
    if powers is None or bars < loop_bars + 1:
        return []
    ref = _reference(a, a.suggested_join_bar if join_bar is None else join_bar, loop_bars)
    found = [_measure(a, powers, i, loop_bars, ref)
             for i in range(0, bars - loop_bars + 1)]

    def eligible(s: Source) -> bool:
        return s.drums_db >= MIN_DRUMS_DB and s.level_db >= MIN_LEVEL_DB

    # A loop whose two ends are real kicks has a length measured off the
    # record; one whose ends are the grid's guess has the grid's error in
    # it. Prefer the first; fall back only if nothing else is there.
    pool = ([s for s in found if eligible(s) and s.snapped]
            or [s for s in found if eligible(s)] or found)
    pool.sort(key=cost)

    # Shortlist on level and vocal, then refine each one's length and rank
    # again with how well it repeats: a loop that does not come round
    # again is worth ten dB of vocal.
    shortlist: list[Source] = []
    for s in pool:
        if all(abs(s.bar - c.bar) >= loop_bars for c in shortlist):
            shortlist.append(s)
        if len(shortlist) == max(3 * count, 12):
            break
    for s in shortlist:
        s.length, s.repeat = refine_length(a, s.bar, loop_bars)
        s.tempo_off = s.length / loop_bars / ref["bar_len"] - 1.0
    shortlist.sort(key=cost)
    return shortlist[:count]


def source_at(a: Analysis, bar: int, loop_bars: int,
              join_bar: int | None = None) -> Source:
    """The stretch starting `bar` bars after the join, for a hand-picked
    loop: measured like any other, whether or not it would have ranked.
    Raises if it runs off the end."""
    if loop_bars not in LOOP_BARS:
        raise ValueError(f"loop_bars must be one of {LOOP_BARS}")
    if bar < 0 or bar + loop_bars >= len(a.bar_lines):
        raise ValueError(f"bar {bar} with {loop_bars} bars runs past the end "
                         f"of the track ({len(a.bar_lines) - 1} bars after "
                         "the join)")
    ref = _reference(a, a.suggested_join_bar if join_bar is None else join_bar, loop_bars)
    source = _measure(a, _bar_powers(a), bar, loop_bars, ref)
    source.length, source.repeat = refine_length(a, bar, loop_bars)
    source.tempo_off = source.length / loop_bars / ref["bar_len"] - 1.0
    return source


# ---------------------------------------------------------------- rendering

def _fade(n: int) -> tuple[np.ndarray, np.ndarray]:
    """(in, out) equal-power fades of n samples."""
    t = (np.arange(n) + 0.5) / max(n, 1) * (np.pi / 2)
    return np.sin(t), np.cos(t)


def bar_chroma(a: Analysis) -> np.ndarray:
    """Per bar: the instrumental's pitch-class energy (12 values, summing to
    1), from a short STFT folded onto the octave. Coarse on purpose: it says
    whether two bars are in the same key and chord region, not which chord."""
    if "chroma" in a.cache:
        return a.cache["chroma"]
    mono = a.instrumental.mean(axis=1).astype(np.float64)
    size = 4096
    freqs = np.fft.rfftfreq(size, 1.0 / a.rate)
    usable = (freqs > 55) & (freqs < 2000)
    classes = np.round(12 * np.log2(freqs[usable] / 440.0) + 69).astype(int) % 12
    window = np.hanning(size)
    lines = a.bar_lines
    out = np.zeros((len(lines) - 1, 12))
    for i in range(len(out)):
        lo, hi = int(lines[i]), int(lines[i + 1])
        frames = range(lo, max(lo + 1, hi - size), size)
        for start in frames:
            chunk = mono[start:start + size]
            if len(chunk) < size:
                break
            mag = np.abs(np.fft.rfft(chunk * window))[usable]
            out[i] += np.bincount(classes, weights=mag, minlength=12)
    a.cache["chroma"] = out / (out.sum(axis=1, keepdims=True) + 1e-12)
    return a.cache["chroma"]


def suggest_lead_in(a: Analysis, join_bar: int) -> tuple[int, float] | None:
    """(bar, match) for the song's own break or fill to end the intro on, or
    None when the song has none that fits.

    A bar `f` qualifies when the drums come back at least LEAD_IN_JUMP_DB
    louder in the bar after it (a break, a drum roll, a stop before the
    drop) and that bar has the song's body level. Of those, the one whose
    NEXT bar sounds most like the join bar wins: the fill resolves into that
    bar in the song, so it should be one that sounds like where the intro
    is about to go. The bar just before the join counts too, and matches
    itself exactly, so it wins whenever it qualifies: that is the song's own
    way into the drop. Only the instrumental is used, so the vocal that was
    over the break in the song is not in the intro."""
    lines = a.bar_lines
    bars = len(lines) - 1
    if bars < 4 or not 0 <= join_bar < bars:
        return None
    mono = a.drums.mean(axis=1).astype(np.float64)
    level = np.array([10.0 * np.log10(np.mean(mono[lines[i]:lines[i + 1]] ** 2) + 1e-12)
                      for i in range(bars)])
    body = float(np.median(level[bars // 4:max(bars // 4 + 1, 3 * bars // 4)]))
    chroma = bar_chroma(a)
    best = None
    for f in range(1, bars - 1):
        if level[f + 1] - level[f] < LEAD_IN_JUMP_DB or level[f + 1] < body - 6.0:
            continue
        if lines[f] - int(a.grid.bar) < 0:
            continue
        a_, b_ = chroma[f + 1], chroma[join_bar]
        match = float(a_ @ b_ / (np.linalg.norm(a_) * np.linalg.norm(b_) + 1e-12))
        if match >= LEAD_IN_MATCH and (best is None or match > best[1]):
            best = (f, match)
    return best


def render(a: Analysis, bars: int, source: Source,
           loop_bars: int = DEFAULT_LOOP_BARS,
           join_bar: int | None = None,
           lead_in_bar: int | None = None,
           style: str = "full") -> tuple[np.ndarray, dict]:
    """The intro edit: (audio, info). `bars` of the instrumental loop, then
    the original from its pickup / downbeat on.

    Laid out on the original's grid: the attack of the original's first bar
    lands at round(bars * bar) after the edit's own start, so every beat of
    the original sits where the grid says whatever the length. The file
    begins `SEAM_S` early, on the loop's first pre-attack samples faded in,
    so the first kick is whole.

    Every cut is made GUARD_S ahead of the attack it precedes, and
    crossfaded over the SEAM_S before that, so a kick's front is never
    inside a fade.

    `style` is "full" (the whole instrumental every repeat), "beat" (the
    song's own drums and bass under every repeat and nothing else: a groove to
    run the intro on, for a record with no vocal-free stretch of the band) or
    "build": the drums alone first, the bass joining a quarter of the way in and the rest
    of the band half way, the last repeat whole, so the intro arrives at the
    song the way a DJ would bring the elements in. Each is a stem of the song,
    so what comes in is what the song has.

    The loop is resampled to the song's tempo at the join when it differs by
    up to RETUNE_MAX (a live record's loop can be a percent off the bars it
    leads into, which is a step in speed at the join).

    `lead_in_bar` is a bar of the song (see `suggest_lead_in`) laid in as the
    intro's LAST bar in place of the loop's: the song's own break or fill,
    instrumental only, so the intro ends the way the song leads into a drop.
    """
    if bars % loop_bars:
        raise ValueError(f"{bars} bars is not a whole number of "
                         f"{loop_bars}-bar loops")
    # Where the song arrives. Everything of the original before it is cut
    # out and the intro takes its place: the song's own opening is not in
    # the file. None means where the full groove lands (`suggest_join`).
    if join_bar is None:
        join_bar = a.suggested_join_bar
    join, pickup = resolve_join(a, join_bar)
    rate, g = a.rate, a.grid
    bar = g.bar
    seam = max(8, int(SEAM_S * rate))
    guard = int(GUARD_S * rate)
    n = len(a.original)
    lead = seam

    # The intro is as long as its loops are: repeats of the source's own
    # measured length, not of a fitted tempo, so no tempo error can build
    # up across the seams. (It is `bars` bars of the SOURCE's tempo; the
    # song after the join keeps its own.)
    src_unit = source.length or int(round(loop_bars * bar))
    ref = _reference(a, join_bar, loop_bars)
    ratio = ref["bar_len"] * loop_bars / src_unit
    retune = RETUNE_MIN < abs(ratio - 1.0) <= RETUNE_MAX
    unit = int(round(src_unit * ratio)) if retune else src_unit
    repeats = bars // loop_bars
    join_out = repeats * unit                    # grid coordinates; the file
    shift = join_out - join                      # adds `lead` at the end
    total = n + shift
    if style not in ("full", "build", "beat"):
        raise ValueError(f"style must be 'full', 'build' or 'beat', not {style!r}")
    stems = style in ("build", "beat") and len(a.bass) == len(a.instrumental) and len(a.other) == len(a.instrumental)
    bass_in = round(repeats * 0.25)
    other_in = min(round(repeats * 0.5), repeats - 1)
    mono_in = a.instrumental

    def layer(m: int, lo: int, hi: int) -> np.ndarray:
        """Repeat `m`'s audio from the source: the instrumental, or in the
        build style only the stems that have come in by now."""
        if not stems:
            return mono_in[lo:hi].astype(np.float64)
        mix = a.drums[lo:hi].astype(np.float64)
        if style == "beat":
            return mix + a.bass[lo:hi]
        if m >= bass_in:
            mix = mix + a.bass[lo:hi]
        if m >= other_in:
            mix = mix + a.other[lo:hi]
        return mix

    # --- the loop: repeats laid back from the join, each crossfaded into
    # the next over the seam-length of pre-attack audio before its cut.
    starts = [join_out - (repeats - m) * unit for m in range(repeats)] + [join_out]
    loop = np.zeros((join_out + lead, 2), dtype=np.float64)
    cut = max(source.start - guard, 0)           # where each repeat's audio begins
    for m in range(repeats):
        pre_src = min(seam, cut)
        seg = layer(m, cut - pre_src, min(cut + src_unit, n))
        pre = pre_src
        if retune:
            fraction = Fraction(ratio).limit_denominator(4000)
            seg = resample_poly(seg, fraction.numerator, fraction.denominator, axis=0)
            pre = int(round(pre_src * ratio))
        win = np.ones(len(seg))
        if pre:
            win[:pre] = _fade(pre)[0]
        if m < repeats - 1 and len(seg) > seam:
            win[-seam:] = _fade(seam)[1]
        at = starts[m] - guard - pre + lead
        lo = max(0, -at)
        hi = min(len(loop), at + len(seg))
        if hi > at + lo:
            loop[at + lo:hi] += (seg * win[:, None])[lo:hi - at]

    # --- the song's own bar to end on, in place of the loop's last bar.
    if lead_in_bar is not None:
        if not 1 <= lead_in_bar < len(a.bar_lines) - 1:
            raise ValueError(f"lead-in bar {lead_in_bar} is outside the track")
        fb0, fb1 = int(a.bar_lines[lead_in_bar]), int(a.bar_lines[lead_in_bar + 1])
        flen = fb1 - fb0
        if join_out < 2 * flen:
            raise ValueError("the intro is too short to end on a bar of its own")
        stop = join_out - flen - guard + lead     # where the loop gives way
        if stop - seam >= 0 and fb0 - guard >= 0:
            loop[stop - seam:stop] *= _fade(seam)[1][:, None]
            loop[stop:] = 0.0
            pre = min(seam, fb0 - guard)
            seg = mono_in[fb0 - guard - pre:fb1].astype(np.float64)
            win = np.ones(len(seg))
            if pre:
                win[:pre] = _fade(pre)[0]
            at = stop - pre
            hi = min(len(loop), at + len(seg))
            loop[at:hi] += (seg * win[:, None])[:hi - at]

    # --- the hand-over: where the original begins (its pickup, or its
    # downbeat), minus the guard. With room before it, it fades in over a
    # seam while the loop fades out; with none (a track that starts on the
    # kick) it simply begins and the loop has finished.
    o_start = max(0, join - pickup - guard)
    fade_len = min(seam, o_start)
    o0 = o_start - fade_len
    out_o = o_start + shift + lead               # file coordinates
    out = np.zeros((total + lead, 2), dtype=np.float64)
    loop_fade = max(fade_len, int(0.0005 * rate))
    gain = np.ones(len(loop))
    f_in, f_out = _fade(loop_fade)
    gain[out_o - loop_fade:out_o] = f_out
    gain[out_o:] = 0.0
    out[:len(loop)] += loop * gain[:, None]
    tail = a.original[o0:].astype(np.float64)
    window = np.ones(len(tail))
    if fade_len:
        window[:fade_len] = _fade(fade_len)[0]
    at = o0 + shift + lead
    out[at:at + len(tail)] += tail * window[:, None]
    # the start of the file: the loop's first pre-attack samples faded in
    ramp = min(lead, len(out))
    out[:ramp] *= _fade(ramp)[0][:, None]

    info = {
        "bpm": round(60.0 * rate * BEATS_PER_BAR * loop_bars / unit, 3),
        "grid_bpm": round(g.bpm, 3),
        "loop_snapped": source.snapped,
        "loop_repeat": round(source.repeat, 2),
        "bars": bars,
        "loop_bars": loop_bars,
        "seconds_of_intro": round(join_out / rate, 3),
        "intro_samples": int(join_out),
        "style": style if (style == "full" or stems) else "full",
        "retuned_pct": round((ratio - 1.0) * 100.0, 3) if retune else 0.0,
        "tempo_off_pct": round((ratio - 1.0) * 100.0, 3) if not retune else 0.0,
        "lead_seconds": round(lead / rate, 4),
        "join_bar": join_bar,
        "lead_in_bar": lead_in_bar,
        "lead_in_seconds": None if lead_in_bar is None
        else round(float(a.bar_lines[lead_in_bar]) / rate, 3),
        "join_seconds": round(join / rate, 3),
        "pickup_seconds": round(pickup / rate, 3),
        "suggested_join_bar": a.suggested_join_bar,
        "cut_seconds": round(max(0, join - pickup) / rate, 3),
        "source_bar": source.bar,
        "source_seconds": round(source.seconds, 3),
        "source_vocal_db": None if np.isnan(source.vocal_db) else round(source.vocal_db, 1),
        "vocal_free": source.vocal_free,
        "grid_coherence": round(g.coherence, 3),
        "downbeat_from": g.how,
        "warnings": list(a.warnings),
    }
    if source.repeat < MIN_REPEAT:
        info["warnings"].append(
            f"these bars do not repeat in the record (match {source.repeat:.2f}): "
            "a build or a fill, so the seams may not land on the beat")
    if not source.snapped:
        info["warnings"].append(
            "the loop's ends could not be tied to a kick, so its length is "
            "the grid's: listen to the seams")
    if not source.vocal_free:
        info["warnings"].append(
            "no vocal-free stretch to loop: the intro carries some vocal "
            "bleed from the source bars")
    return out.astype(np.float32), info


# ------------------------------------------------------------ files in, out

PREFERRED_SEPARATORS = ("demucs-mlx", "demucs")
# One piece at a time: two at once ran a 16 GB Mac into swap and took 729 s
# for what one at a time does in 30 (scans/separation-speed-2026-09-29).
SEPARATOR_OPTIONS = {"batch": 1, "shifts": 0, "overlap": 0.25}


def release_memory() -> None:
    """Hand back what separating leaves held.

    MLX and PyTorch both keep the GPU buffers a separation used, in a cache,
    in case the next one wants them. For a process that separates once and
    sits waiting for a person that is not a cache, it is several gigabytes of
    a 16 GB Mac held for as long as the session lives. Cleared after every
    separation, and when a session lets its track go."""
    gc.collect()
    try:
        import mlx.core as mx
        mx.clear_cache()
    except Exception:                              # noqa: BLE001 - not installed, or older
        pass
    torch = sys.modules.get("torch")
    if torch is not None:
        try:
            torch.mps.empty_cache()
        except Exception:                          # noqa: BLE001 - no MPS here
            pass


def separate(x: np.ndarray, rate: int, separator: str | None = None) -> dict:
    """The four stems, from MLX where it is there and PyTorch otherwise.
    A failure of the first falls through to the second."""
    have = stems.available()
    order = [separator] if separator else [s for s in PREFERRED_SEPARATORS if s in have]
    if not order:
        raise RuntimeError("no stem separator is installed (Demucs); run "
                           "setup.sh or `pip install demucs`")
    last: Exception | None = None
    try:
        for backend in order:
            try:
                return stems.separate(x, rate, backend, options=SEPARATOR_OPTIONS)
            except Exception as exc:              # noqa: BLE001 - try the next
                last = exc
        raise RuntimeError(f"stem separation failed: {last}")
    finally:
        release_memory()


def default_format(source: Path) -> str:
    return {".mp3": "mp3", ".m4a": "aac", ".aac": "aac"}.get(source.suffix.lower(), "flac")


def default_out_dir() -> Path:
    return Path.home() / "Music" / "LoudnessLab" / "Intro Edits"


def output_path(source: Path, out_dir: Path, bars: int) -> Path:
    return out_dir / f"{source.stem} (Intro {bars})"


def prepare(path: Path, bpm: float | None = None, downbeat_s: float | None = None,
            separator: str | None = None) -> Analysis:
    """Decode, separate and analyse one file."""
    if bpm is None:
        bpm, _ = decode.tempo_with_source(path)
    x = decode.decode(path)
    parts = separate(x, decode.TARGET_RATE, separator)
    return analyse(x, parts, decode.TARGET_RATE, bpm, downbeat_s)


def write_intro(a: Analysis, source_file: Path, audio: np.ndarray, bars: int,
                out_dir: Path, fmt: str | None = None) -> Path:
    """Write the edit beside nothing: into `out_dir`, never over the
    original. The original's Serato cues and beatgrid are NOT carried --
    they describe the track without its intro, and every one of them would
    be `bars` bars early."""
    fmt = fmt or default_format(source_file)
    return write.write(output_path(source_file, out_dir, bars), audio, a.rate,
                       source=source_file, fmt=fmt, keep_markers=False)


# ------------------------------------------------------------------ a session

class NoTrack(RuntimeError):
    """Asked for something that needs a prepared track, and none is held:
    never prepared, or let go after sitting idle. `code` is what a program
    keys on, so it can prepare again and retry instead of reading prose."""
    code = "no_track"


class Session:
    """One separated track held in memory, answering requests.

    Separating is half a minute; everything after it (listing loops,
    rendering a length, rendering another) is seconds. A program that
    drives this one request at a time as separate commands pays the half
    minute on every click, so `loudness-lab intro --serve` keeps a Session
    and talks JSON lines: a request in, events out, the last of which is
    always a `done` or an `error` carrying the request's `id` back.

    One track at a time: its stems are about 600 MB at 48 kHz, and a new
    `prepare` lets the old ones go.
    """

    def __init__(self, out_dir: Path | None = None):
        self.analysis: Analysis | None = None
        self.path: Path | None = None
        self.out_dir = out_dir or default_out_dir()

    def handle(self, request: dict, emit) -> bool:
        """Answer one request through `emit(event_dict)`. Returns False when
        asked to quit. Never raises: a failure is an `error` event, because
        one bad file must not end the session."""
        rid = request.get("id")
        command = request.get("cmd")

        def say(event: str, **fields):
            emit({"event": event, "id": rid, **fields})

        try:
            if command == "quit":
                say("done")
                return False
            if command == "prepare":
                self._prepare(request, say)
            elif command == "sources":
                self._sources(request, say)
            elif command == "release":
                self.release()
                say("released", reason="asked")
            elif command == "rephase":
                a = rephase(self._need(), int(request.get("beats", 1)))
                self.analysis = a
                say("grid", **self._grid_fields(a))
            elif command == "envelope":
                say("envelope", **envelope(self._need(),
                                           int(request.get("per_second", ENVELOPE_PER_SECOND))))
            elif command == "render":
                self._render(request, say)
            else:
                raise ValueError(f"unknown command {command!r}")
            say("done")
        except Exception as exc:                  # noqa: BLE001
            say("error", message=str(exc), code=getattr(exc, "code", None))
        return True

    def release(self) -> None:
        """Let the held track go, with the memory it took. The process stays
        and can prepare another."""
        self.analysis, self.path = None, None
        release_memory()

    def _need(self) -> Analysis:
        if self.analysis is None:
            raise NoTrack("no track is prepared: send `prepare` first")
        return self.analysis

    def _prepare(self, request: dict, say) -> None:
        path = Path(request["path"])
        self.release()                             # let the last one go first
        say("stage", stage="separating", name=path.name)
        a = prepare(path, bpm=request.get("bpm"),
                    downbeat_s=request.get("downbeat"),
                    separator=request.get("separator"))
        self.analysis, self.path = a, path
        say("prepared", path=str(path), name=path.name,
            seconds=round(len(a.original) / a.rate, 3),
            bpm=round(a.grid.bpm, 3), grid_coherence=round(a.grid.coherence, 3),
            **self._grid_fields(a))

    @staticmethod
    def _grid_fields(a: Analysis) -> dict:
        """What the bar lines are, which `prepare` and `rephase` both report."""
        join, pickup = resolve_join(a, a.suggested_join_bar)
        return dict(
            first_bar_seconds=round(a.join / a.rate, 3),
            suggested_join_bar=a.suggested_join_bar,
            join_reason=a.join_reason,
            join_seconds=round(join / a.rate, 3),
            pickup_seconds=round(pickup / a.rate, 3),
            bar_seconds=[round(float(t) / a.rate, 3) for t in a.bar_lines],
            downbeat_from=a.grid.how,
            bars_after_join=len(a.bar_lines) - 1, warnings=list(a.warnings))

    def _sources(self, request: dict, say) -> None:
        a = self._need()
        loop_bars = int(request.get("loop_bars", DEFAULT_LOOP_BARS))
        join_bar = request.get("join_bar")
        found = candidates(a, loop_bars, count=int(request.get("count", 5)),
                           join_bar=None if join_bar is None else int(join_bar))
        say("sources", loop_bars=loop_bars,
            sources=[source_fields(s) for s in found])

    def _render(self, request: dict, say) -> None:
        a = self._need()
        bars = int(request.get("bars", 16))
        loop_bars = int(request.get("loop_bars", DEFAULT_LOOP_BARS))
        join_bar = request.get("join_bar")
        chosen_join = a.suggested_join_bar if join_bar is None else int(join_bar)
        if request.get("source_bar") is not None:
            source = source_at(a, int(request["source_bar"]), loop_bars, chosen_join)
        else:
            found = candidates(a, loop_bars, count=1, join_bar=chosen_join)
            if not found:
                raise ValueError("the track is too short to take a loop from")
            source = found[0]
        say("stage", stage="rendering", name=self.path.name)
        lead_in, match, note = None, None, None
        want = request.get("lead_in")
        if want == "auto":
            found = suggest_lead_in(a, chosen_join)
            if found is None:
                note = ("no break or fill in this song fits as the intro's last bar, "
                        "so it ends on the loop")
            else:
                lead_in, match = found
        elif want is not None:
            lead_in = int(want)
        audio, info = render(a, bars, source, loop_bars, chosen_join, lead_in,
                             request.get("style", "build"))
        info["lead_in_match"] = None if match is None else round(match, 3)
        info["lead_in_note"] = note
        out_dir = Path(request["out"]) if request.get("out") else self.out_dir
        target = write_intro(a, self.path, audio, bars, out_dir,
                             request.get("format"))
        say("intro", **info, source=str(self.path), output=str(target))
        # The finished edit as it will be heard, drawn the way the original
        # is, so the join can be judged in the result and not only before it.
        say("render_envelope", output=str(target), **envelope_of(audio, a.rate))


def source_fields(s: Source) -> dict:
    """A Source as plain JSON."""
    nan = s.vocal_db != s.vocal_db
    return {
        "bar": s.bar,
        "seconds": round(float(s.seconds), 3),
        "vocal_db": None if nan else round(float(s.vocal_db), 1),
        "vocal_free": bool(s.vocal_free),
        "repeat": round(float(s.repeat), 2),
        "snapped": bool(s.snapped),
        "fill": round(float(s.fill), 2),
        "feel": round(float(s.feel), 3),
        "tempo_off": round(float(s.tempo_off), 5),
        "chroma_match": round(float(s.chroma_match), 3),
        "level_vs_join_db": round(float(s.level_vs_join_db), 1),
    }


# ----------------------------------------------------------------- serving

EOF_LINE = object()
TIMED_OUT = object()
# A session that nobody has asked anything of for ten minutes lets its track
# go (about 6 GB on the Mac this was measured on, between the stems, the
# analysis and the GPU's buffers), and after half an hour exits. The app
# starts another when it is next wanted and prepares the track again, which
# is half a minute against a Mac that has been out of memory for the hour
# between.
IDLE_RELEASE_S = 600.0
IDLE_EXIT_S = 1800.0


class FdLines:
    """Lines from a file descriptor, with a timeout on waiting for one.

    `select` on the descriptor and our own buffer, not `for line in
    sys.stdin`: Python's text buffer can hold a line the descriptor no longer
    reports as readable, and a wait that misses it hangs a request."""

    def __init__(self, fd: int):
        self.fd, self.buffer, self.closed = fd, b"", False

    def read(self, timeout: float | None):
        while True:
            if b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                return line.decode("utf-8", errors="replace")
            if self.closed:
                rest, self.buffer = self.buffer, b""
                return rest.decode("utf-8", errors="replace") if rest else EOF_LINE
            ready, _, _ = select.select([self.fd], [], [], timeout)
            if not ready:
                return TIMED_OUT
            chunk = os.read(self.fd, 65536)
            if chunk:
                self.buffer += chunk
            else:
                self.closed = True


class IterLines:
    """The same, over an iterable of lines (no timeout can occur)."""

    def __init__(self, lines):
        self.lines = iter(lines)

    def read(self, timeout: float | None):
        return next(self.lines, EOF_LINE)


def serve(session: Session, source, emit, release_after: float | None = IDLE_RELEASE_S,
          exit_after: float | None = IDLE_EXIT_S, clock=time.monotonic) -> None:
    """Answer requests from `source` until it ends, `quit`, or sitting idle
    for `exit_after`. After `release_after` idle the held track is let go
    (an event says so); either may be None to turn it off."""
    last = clock()
    while True:
        idle = clock() - last
        waits = []
        if release_after is not None and session.analysis is not None:
            waits.append(release_after - idle)
        if exit_after is not None:
            waits.append(exit_after - idle)
        line = source.read(max(0.0, min(waits)) if waits else None)
        if line is EOF_LINE:
            return
        if line is TIMED_OUT:
            idle = clock() - last
            if exit_after is not None and idle >= exit_after:
                emit({"event": "exit", "id": None, "reason": "idle"})
                return
            if (release_after is not None and session.analysis is not None
                    and idle >= release_after):
                session.release()
                emit({"event": "released", "id": None, "reason": "idle"})
            continue
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as exc:
            emit({"event": "error", "id": None, "message": f"not JSON: {exc}"})
            continue
        keep_going = session.handle(request, emit)
        last = clock()                      # idle is counted from the answer, not the ask
        if not keep_going:
            return
