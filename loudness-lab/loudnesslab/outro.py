"""Outro edits: a track that ends cold, or fades out, given an outro made from itself.

The mirror of `intro`. A song that fades away, or stops dead, leaves a DJ
nowhere to mix out. This keeps the original up to a bar line where its
groove ends, and runs a loop of the song's own instrumental from there, so
the mix has room and the song leaves the way it was heading:

    [ the original, untouched ][ loop of the instrumental, tiled to N bars ]

It leans on everything `intro` already does and does not repeat it: the same
separation, the same grid (`intro.Analysis`), the same ranked loops
(`intro.candidates`) and the same seam handling. What is new is the mirror
of each step:

    exit     where the song leaves (`suggest_exit`): the end of the last
             stretch that holds the body of the record's level, so a fade-out
             is replaced from where it starts to fall, and a cold ending
             from the bar its final groove stops.
    tail     a vocal that rings on past the exit bar (a held last note) is
             kept (`tail_after`): the loop takes over after it, on the grid.
    loop     ranked against the bars BEFORE the exit, not the ones after a
             join: it should sound like what the song was just playing.
    hand-in  in the stem styles the loop's drums and bass fade in under the
             song's last bar, so the loop arrives as a groove already
             running.
    ending   the loop stops on a bar line, or fades over its last bars.

Unlike an intro, the original is not moved: the file's first `exit` samples
ARE the original's. Its Serato cues and beatgrid are still not carried (a
cue after the exit would point into the loop), the same as for an intro.
"""

from __future__ import annotations

from fractions import Fraction
from pathlib import Path

import numpy as np
from scipy.signal import resample_poly

from . import intro, write
from .intro import (Analysis, Source, _fade, _reference, GUARD_S, JOIN_FULL_DB,
                    JOIN_LOOKBACK, JOIN_SUSTAIN, MIN_REPEAT, PICKUP_SHARE,
                    PICKUP_STEPS, RETUNE_MAX, RETUNE_MIN, SEAM_S, LENGTHS,
                    LOOP_BARS, DEFAULT_LOOP_BARS, BEATS_PER_BAR)

# "full": the whole instrumental every repeat. "beat": the song's own drums and
# bass only, a groove to mix out on. "strip": the band leaves the way "build"
# brings it in: the whole instrumental first, then the rest of the band goes,
# then the bass, and the drums play the last repeat alone.
STYLES = ("full", "beat", "strip")

# Bars of the loop's drums and bass faded in under the song's last bar in the
# stem styles, so the loop arrives as a groove already running.
HANDIN_BARS = intro.HANDOVER_BARS

# The least of the original that must come before the exit.
MIN_EXIT_BAR = 2

# What the new material may peak at. The loop is the instrumental's stems summed,
# which can run louder than the mix they came from (measured: a loop peaking at
# 1.09 from a record whose own peak is 0.94), and an encoder overshoots a little
# more. Only the new material is brought down: the original is never touched.
CEILING = 0.97

# The bar lines are followed from the start of the track and keep their lock
# on the kicks only while each is within a tenth of a beat of where the last
# one says it should be (`intro.snap`). A record whose tempo wanders, or that
# has a break without kicks in it, loses the lock and the grid carries on at
# a fixed tempo from there: measured on a six-minute dance record, 144 of its
# 199 bar lines were more than 40 ms from a kick, and the last were 0.4 of a
# beat off. The end of the track is where that has built up, and it is where
# an outro leaves, so the exit is aligned to the kicks it is actually near.
ALIGN_BARS = 16               # the kicks of this many bars before the exit are read
ALIGN_MIN_KICKS = 8
ALIGN_MIN_COHERENCE = 0.5     # how firmly those kicks must agree on one phase
ALIGN_MIN_SHIFT_S = 0.025     # less than this and the grid's own line is as good


# ---------------------------------------------------------------- the exit

def suggest_exit(a: Analysis) -> tuple[int, str]:
    """(bar line, why): where the song's groove ends.

    The mirror of `intro.suggest_join`. The bar lines run from the first bar
    to the last whole bar of the file; `bar_lines[k]` is where bar k begins,
    and the exit is a bar LINE: the original is kept up to it and the loop
    begins on it.

    It is the end of the last stretch of bars that hold the body of the
    record's level (the drums' where there are drums to read, else the whole
    mix's). A fade-out is therefore replaced from the bar it starts to fall;
    a record that holds full level to its last bar exits at its last bar
    line, and the person is told so, because a cold ending usually has a
    final hit the loop should come in after, or before. Of the bars just
    after that stretch, the one with the biggest drop in level is taken, so a
    record that stops dead is cut at the stop and not a bar early.

    A starting point, meant to be moved: where a song "really leaves" is a
    judgement.
    """
    lines = a.bar_lines
    bars = len(lines) - 1
    if bars < JOIN_SUSTAIN * 2:
        return bars, "the track is too short to look for where it leaves"

    def bar_levels(y: np.ndarray) -> np.ndarray:
        mono = y.mean(axis=1).astype(np.float64)
        return np.array([10.0 * np.log10(np.mean(mono[lines[i]:lines[i + 1]] ** 2) + 1e-12)
                         for i in range(bars)])

    mix = bar_levels(a.original)
    drums = bar_levels(a.drums)
    middle = slice(bars // 4, max(bars // 4 + 1, 3 * bars // 4))
    use_drums = float(np.median(drums[middle])) > float(np.median(mix[middle])) - 30.0
    level = drums if use_drums else mix
    body = float(np.median(level[middle]))
    full = level >= body + JOIN_FULL_DB
    last = next((i for i in range(bars - 1, JOIN_SUSTAIN - 2, -1)
                 if full[i - JOIN_SUSTAIN + 1:i + 1].all()), None)
    if last is None:
        return bars, "nothing holds full level, so the end of the track is used"
    if last >= bars - 1:
        return bars, "the track holds full level to its last bar, so it exits there"
    window = range(last + 1, min(bars, last + 1 + JOIN_LOOKBACK))
    best = max(window, key=lambda k: level[k - 1] - level[k])
    what = "the drums fall away" if use_drums else "the groove falls from full level"
    return int(best), (f"{what} after bar {best - 1} ({lines[best] / a.rate:.1f} s in); "
                       "the rest of the song is replaced")


def aligned_exit(a: Analysis, exit_bar: int) -> int:
    """The sample the outro leaves the song at: the exit bar line, moved onto
    the kicks it is really near if the bar lines have drifted from them.

    The kicks of the `ALIGN_BARS` bars before the exit are read against the
    line (a circular mean of where each falls in a beat); if they agree on
    one phase (`ALIGN_MIN_COHERENCE`) and it is more than `ALIGN_MIN_SHIFT_S`
    from the line, the exit is moved by that much, onto the real kick's
    attack (`intro.attack`, the same as every bar line that did lock). The
    move is under half a beat, so it is the same beat of the bar as before.
    Otherwise the grid's own line stands."""
    line = int(a.bar_lines[exit_bar])
    cached = a.cache.get(("aligned_exit", exit_bar))
    if cached is not None:
        return cached
    period = a.grid.period
    kicks = a.kicks
    window = kicks[(kicks >= line - int(ALIGN_BARS * a.grid.bar)) & (kicks < line)]
    result = line
    if window.size >= ALIGN_MIN_KICKS:
        z = np.exp(2j * np.pi * (window - line) / period).mean()
        shift = float(np.angle(z)) / (2 * np.pi) * period
        if abs(z) >= ALIGN_MIN_COHERENCE and abs(shift) > ALIGN_MIN_SHIFT_S * a.rate:
            drums_abs = a.cache.get("drums_abs")
            if drums_abs is None:
                drums_abs = a.cache["drums_abs"] = np.abs(a.drums.mean(axis=1))
            # Where the kick would be, on the beat the kicks keep: often past
            # the last real one (the exit is where the music ends), so it is
            # extrapolated, not looked for. A bar line sits on a kick's
            # ATTACK, which the detector's onset follows by a few milliseconds;
            # that lag is read off the last kicks there are.
            lags = [int(kick) - intro.attack(drums_abs, kick, kicks, period, a.rate)[0]
                    for kick in window[-8:]]
            lag = int(np.median(lags)) if lags else 0
            result = int(min(max(round(line + shift - lag), 0), len(a.original)))
    a.cache[("aligned_exit", exit_bar)] = result
    return result


def resolve_exit(a: Analysis, exit_bar: int) -> tuple[int, int]:
    """(sample the song leaves at, samples of vocal tail kept after it).

    Raises for a bar line outside the track or with too little before it."""
    last = len(a.bar_lines) - 1
    if not MIN_EXIT_BAR <= exit_bar <= last:
        raise ValueError(f"exit bar {exit_bar} is outside the track "
                         f"({MIN_EXIT_BAR} to {last})")
    exit_ = aligned_exit(a, exit_bar)
    return exit_, tail_after(a, exit_)


def tail_after(a: Analysis, exit_: int) -> int:
    """Samples of vocal to keep past the exit, so a held last note rings out
    over the loop's first beats instead of being cut mid-word.

    The mirror of `intro.pickup_before`: walks forward from the exit in
    half-beat steps while the vocal stem there is at least PICKUP_SHARE of
    what it is in the bar before the exit, up to PICKUP_STEPS of them. None
    if the song has no vocal there."""
    step = max(1, int(a.grid.period / 2))
    vocal = a.vocals.mean(axis=1).astype(np.float64)

    def rms(lo: int, hi: int) -> float:
        lo, hi = max(0, lo), min(len(vocal), hi)
        return float(np.sqrt(np.mean(vocal[lo:hi] ** 2))) if hi > lo else 0.0

    reference = rms(exit_ - int(a.grid.bar), exit_)
    if reference <= 1e-6:
        return 0
    kept = 0
    for k in range(1, PICKUP_STEPS + 1):
        if rms(exit_ + (k - 1) * step, exit_ + k * step) >= PICKUP_SHARE * reference:
            kept = k * step
        else:
            break
    return kept


# ------------------------------------------------------------ loop sources

def _reference_bar(exit_bar: int, loop_bars: int) -> int:
    """The bar `intro.candidates` should read as "where the song is", so the
    loop is judged against the `loop_bars` bars just BEFORE the exit."""
    return max(exit_bar - loop_bars, 0)


def candidates(a: Analysis, loop_bars: int = DEFAULT_LOOP_BARS, count: int = 5,
               exit_bar: int | None = None) -> list[Source]:
    """The best stretches of `loop_bars` bars to loop, best first, judged
    against the bars the song plays up to the exit."""
    exit_bar = a.suggested_exit_bar if exit_bar is None else exit_bar
    return intro.candidates(a, loop_bars, count, join_bar=_reference_bar(exit_bar, loop_bars))


def source_at(a: Analysis, bar: int, loop_bars: int, exit_bar: int | None = None) -> Source:
    """A hand-picked stretch, measured like any other."""
    exit_bar = a.suggested_exit_bar if exit_bar is None else exit_bar
    return intro.source_at(a, bar, loop_bars, join_bar=_reference_bar(exit_bar, loop_bars))


# --------------------------------------------------------------- rendering

def render(a: Analysis, bars: int, source: Source,
           loop_bars: int = DEFAULT_LOOP_BARS,
           exit_bar: int | None = None,
           style: str = "full",
           handin: float = HANDIN_BARS,
           fade_bars: float = 0.0) -> tuple[np.ndarray, dict]:
    """The outro edit: (audio, info). The original up to the exit (and its
    vocal tail), then `bars` bars of the instrumental loop.

    Laid on the original's grid, with no shift: the file's first samples are
    the original's, and the loop's repeats begin on the exit bar line, each
    `unit` samples (the loop's own measured length, resampled to the song's
    tempo at the exit when it differs by up to RETUNE_MAX) after the last.

    Every cut is made GUARD_S ahead of the attack it precedes and crossfaded
    over the SEAM_S before that, as in `intro.render`. The hand-over from the
    original to the loop is made at the exit plus the vocal tail: the
    original fades out and the loop fades in over the same few milliseconds,
    the loop's beat having been running on the grid since the exit bar line.

    `style` is "full", "beat" or "strip" (see `STYLES`). In the stem styles
    `handin` bars of the loop's drums and bass fade in under the song's last
    bar. `fade_bars` fades the whole outro away over its last bars; 0 stops
    it on the bar line.
    """
    if style not in STYLES:
        raise ValueError(f"style must be one of {', '.join(STYLES)}, not {style!r}")
    if bars % loop_bars:
        raise ValueError(f"{bars} bars is not a whole number of {loop_bars}-bar loops")
    if exit_bar is None:
        exit_bar = a.suggested_exit_bar
    exit_, tail = resolve_exit(a, exit_bar)
    rate, g = a.rate, a.grid
    bar = g.bar
    seam = max(8, int(SEAM_S * rate))
    guard = int(GUARD_S * rate)
    n = len(a.original)

    src_unit = source.length or int(round(loop_bars * bar))
    ref = _reference(a, _reference_bar(exit_bar, loop_bars), loop_bars)
    ratio = ref["bar_len"] * loop_bars / src_unit
    retune = RETUNE_MIN < abs(ratio - 1.0) <= RETUNE_MAX
    unit = int(round(src_unit * ratio)) if retune else src_unit
    repeats = bars // loop_bars
    end = exit_ + repeats * unit                  # the file's length, on the grid
    stems = (style in ("beat", "strip") and len(a.bass) == len(a.instrumental)
             and len(a.other) == len(a.instrumental))
    bass_in = round(repeats * 0.25)
    other_in = min(round(repeats * 0.5), repeats - 1)

    def layer(m: int, lo: int, hi: int) -> np.ndarray:
        """Repeat `m` from the source: the instrumental, or in the stem styles
        the stems still playing at this point."""
        if not stems:
            return a.instrumental[lo:hi].astype(np.float64)
        mix = a.drums[lo:hi].astype(np.float64)
        if style == "beat":
            return mix + a.bass[lo:hi]
        # strip: "build" backwards, counted from the last repeat.
        back = repeats - 1 - m
        if back >= bass_in:
            mix = mix + a.bass[lo:hi]
        if back >= other_in:
            mix = mix + a.other[lo:hi]
        return mix

    cut = max(source.start - guard, 0)             # where each repeat's audio begins
    # Repeat m begins at the grid's exit + m * unit; m = -1 is the one before.
    starts = {m: exit_ + m * unit for m in range(-1, repeats + 1)}

    def lay(pick, first: int, count: int, size: int) -> np.ndarray:
        """Repeats `first` .. `first + count - 1` of `pick(m, lo, hi)` placed
        on the grid in a buffer of `size` samples."""
        buf = np.zeros((size, 2), dtype=np.float64)
        for m in range(first, first + count):
            pre_src = min(seam, cut)
            seg = pick(m, cut - pre_src, min(cut + src_unit, n))
            pre = pre_src
            if retune:
                fraction = Fraction(ratio).limit_denominator(4000)
                seg = resample_poly(seg, fraction.numerator, fraction.denominator, axis=0)
                pre = int(round(pre_src * ratio))
            win = np.ones(len(seg))
            if pre:
                win[:pre] = _fade(pre)[0]
            if m < first + count - 1 and len(seg) > seam:
                win[-seam:] = _fade(seam)[1]
            at = starts[m] - guard - pre
            lo = max(0, -at)
            hi = min(size, at + len(seg))
            if hi > at + lo:
                buf[at + lo:hi] += (seg * win[:, None])[lo:hi - at]
        return buf

    loop = lay(layer, 0, repeats, end)
    loop_peak = float(np.abs(loop[exit_:]).max()) if end > exit_ else 0.0
    loop_gain = min(1.0, CEILING / loop_peak) if loop_peak > 0 else 1.0
    loop *= loop_gain

    # Where the original gives way to the loop: the exit plus its vocal tail,
    # a guard ahead of the attack there. The loop has been on the grid since
    # the exit; it is simply not heard until now.
    x_end = min(exit_ + tail - guard, n)
    fade_len = min(seam, x_end)
    out = np.zeros((end, 2), dtype=np.float64)
    gate = np.zeros(end)
    gate[x_end:] = 1.0
    if fade_len:
        gate[x_end - fade_len:x_end] = _fade(fade_len)[0]
    out += loop * gate[:, None]
    original = a.original[:x_end].astype(np.float64)
    window = np.ones(len(original))
    if fade_len:
        window[-fade_len:] = _fade(fade_len)[1]
    out[:x_end] += original * window[:, None]

    # The hand-in: the loop's drums and bass, fading in under the song's last
    # stretch and handing over to the loop proper at x_end.
    hand_bars = handin if stems else 0.0
    if hand_bars > 0:
        def beat_only(m: int, lo: int, hi: int) -> np.ndarray:
            return a.drums[lo:hi].astype(np.float64) + a.bass[lo:hi]
        hand = lay(beat_only, -1, 2, end)
        h = min(int(round(hand_bars * unit / loop_bars)), x_end)
        if h > 0:
            ramp_up = np.sin(np.linspace(0.0, np.pi / 2, h, endpoint=False)) ** 2
            added = hand[x_end - h:x_end] * ramp_up[:, None]
            kept = out[x_end - h:x_end]
            # Under a loud master there may be no room to double the drums and
            # bass: take the most of them that fits, down to none.
            over = (np.sign(kept) == np.sign(added)) & (np.abs(kept) + np.abs(added) > CEILING)
            if over.any():
                room = (CEILING - np.abs(kept[over])) / np.maximum(np.abs(added[over]), 1e-12)
                added = added * float(np.clip(room.min(), 0.0, 1.0))
            out[x_end - h:x_end] += added

    # The ending: a fade over the last bars, or a stop a few milliseconds long
    # so the last sample is not a click.
    stop = end - guard
    fade_samples = int(round(fade_bars * unit / loop_bars)) if fade_bars > 0 else 0
    fade_samples = min(fade_samples, repeats * unit)
    if fade_samples > 0:
        ramp = np.cos(np.linspace(0.0, np.pi / 2, fade_samples, endpoint=False)) ** 2
        out[end - fade_samples:] *= ramp[:, None]
    elif stop - seam >= 0:
        out[stop - seam:stop] *= _fade(seam)[1][:, None]
        out[stop:] = 0.0

    # The seam itself (an equal-power crossfade of two full-level signals) can
    # reach past full scale for a few milliseconds; hold it there.
    edge = slice(max(0, x_end - max(fade_len, 1)), min(end, x_end + max(fade_len, 1)))
    np.clip(out[edge], -1.0, 1.0, out=out[edge])

    info = {
        "bpm": round(60.0 * rate * BEATS_PER_BAR * loop_bars / unit, 3),
        "grid_bpm": round(g.bpm, 3),
        "loop_snapped": source.snapped,
        "loop_repeat": round(source.repeat, 2),
        "bars": bars,
        "loop_bars": loop_bars,
        "seconds_of_outro": round(repeats * unit / rate, 3),
        "outro_samples": int(repeats * unit),
        "style": style if (style == "full" or stems) else "full",
        "handin_bars": hand_bars,
        "fade_bars": fade_bars,
        "loop_gain_db": round(20.0 * float(np.log10(max(loop_gain, 1e-9))), 2),
        "retuned_pct": round((ratio - 1.0) * 100.0, 3) if retune else 0.0,
        "tempo_off_pct": round((ratio - 1.0) * 100.0, 3) if not retune else 0.0,
        "exit_bar": exit_bar,
        "exit_seconds": round(exit_ / rate, 3),
        "exit_moved_ms": round((exit_ - int(a.bar_lines[exit_bar])) / rate * 1000.0, 1),
        "tail_seconds": round(tail / rate, 3),
        "suggested_exit_bar": a.suggested_exit_bar,
        "cut_seconds": round(max(0, n - exit_ - tail) / rate, 3),
        "source_bar": source.bar,
        "source_seconds": round(source.seconds, 3),
        "source_vocal_db": None if np.isnan(source.vocal_db) else round(source.vocal_db, 1),
        "vocal_free": source.vocal_free,
        "grid_coherence": round(g.coherence, 3),
        "downbeat_from": g.how,
        "warnings": list(a.warnings),
    }
    if abs(info["exit_moved_ms"]) > 1000 * ALIGN_MIN_SHIFT_S:
        info["warnings"].append(
            f"the bar lines had drifted {abs(info['exit_moved_ms']):.0f} ms from the kicks by "
            "the exit, so it was moved onto the beat; listen to the exit")
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
            "no vocal-free stretch to loop: the outro carries some vocal "
            "bleed from the source bars")
    return out.astype(np.float32), info


# ----------------------------------------------------------------- writing

def default_out_dir() -> Path:
    return Path.home() / "Music" / "LoudnessLab" / "Outro Edits"


def output_path(source: Path, out_dir: Path, bars: int, label: str = "") -> Path:
    """`label` (a style, say) keeps two outros of the same length from
    overwriting each other."""
    return out_dir / f"{source.stem} (Outro {bars}{' ' + label if label else ''})"


def write_outro(a: Analysis, source_file: Path, audio: np.ndarray, bars: int,
                out_dir: Path, fmt: str | None = None, label: str = "") -> Path:
    """Write the edit into `out_dir`, never over the original. The original's
    Serato cues and beatgrid are not carried: a cue after the exit would
    point into the loop."""
    fmt = fmt or intro.default_format(source_file)
    return write.write(output_path(source_file, out_dir, bars, label), audio, a.rate,
                       source=source_file, fmt=fmt, keep_markers=False)
