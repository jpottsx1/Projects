"""Putting back peaks that were clipped before the file reached us.

About a third of the 1970s disco material measured for this project carries
runs of consecutive samples pinned at full scale. That is not loudness, it is
a flat top where a peak used to be, and the flat top IS the distortion: a
clipped waveform is the original plus a family of odd harmonics, which is why
heavily clipped material sounds hard and small rather than loud.

Nothing can recover what was thrown away. What can be done is to put back a
plausible peak -- the arc the signal was already on when it ran out of
headroom -- and then test whether that arc is closer to the truth than the
flat top is. That test is the reason to believe any of this, and it is in
tests/test_declip.py: clean audio is clipped deliberately, restored, and the
reconstruction error measured against the known original. If restoring did
not beat leaving it alone, the test would fail.

Method is a cubic Hermite arc across each run, taking the value and slope of
the audio on both shoulders. It is chosen for a property that matters more
here than sophistication does: it is self-limiting. On a genuinely clipped
peak it arcs up to very close to the true peak -- within 0.1 dB on a clipped
sine. On a peak that merely touched full scale without clipping, the
shoulders are already turning over, so the arc it draws is the peak that is
already there and it changes the audio by thousandths of a decibel. A false
detection therefore costs almost nothing, which is the only basis on which
this is safe to run across a library.

Two honest limits.

Restoration raises the peak above full scale by definition, so this returns
audio that may exceed 1.0 and leaves the trim to the caller: the levelling
stage that follows should make that decision once rather than twice. This is
also why de-clipping has to run FIRST in the chain -- it needs the file
before anything has attenuated it, and everything after it has to fit under
the peak it restores.

And a limiter is not a clipper. Where a master was squashed rather than
clipped, the shoulders are squashed too, the run never appears, and there is
nothing here to find. This addresses hard clipping, which is what the flat
runs in the database are. Related: MP3 decoding moves every sample slightly,
so a CD master clipped at full scale arrives with its flat tops no longer
quite flat. Detection on decoded audio therefore finds fewer runs than the
original had. Under-counting is the right way to be wrong.
"""

from __future__ import annotations

import numpy as np

# Matches bs1770.count_clipping, so that what the reports call a clipping run
# and what this restores are the same thing.
CLIP_THRESHOLD = 0.9995

# count_clipping reports runs of 4 or more because it is answering "was this
# master clipped". Two consecutive samples at the ceiling already carry
# distortion and already have shoulders to arc between, and the self-limiting
# property above means a short run wrongly picked up is close to a no-op, so
# restoration starts lower than reporting does.
MIN_RUN = 2

# How close to the ceiling a sample has to be for the run either side of it
# to count as one damaged span rather than two peaks. See _merge_near.
MERGE_TOLERANCE = 0.0002

SHOULDER = 3           # samples each side, for the value and the slope
MAX_RUN_MS = 10.0      # longer than a clipped peak can plausibly be
MAX_RESTORE_DB = 6.0   # hard cap on how far one peak may be lifted

REFUSALS = ("too_long", "at_edge", "shoulder_clipped", "nothing_to_add")


def _runs_of(mask: np.ndarray, min_run: int) -> list[tuple[int, int]]:
    padded = np.concatenate([[False], mask, [False]])
    edges = np.flatnonzero(padded[1:] != padded[:-1])
    return [(int(start), int(end))
            for start, end in zip(edges[0::2], edges[1::2])
            if end - start >= min_run]


def _merge_near(runs: list[tuple[int, int]], channel: np.ndarray, sign: int,
                gap: int, floor: float) -> list[tuple[int, int]]:
    """Join runs separated by less than `gap` samples into one damaged span.

    A flat top that arrives through MPEG does not arrive flat: the encoder
    ripples it, so one clipped peak can read as three or four runs a sample
    or two apart. Treated separately each has the next sitting in its
    shoulder, there is no clean audio to take a slope from, and all of them
    get refused.

    Which makes joining them up tempting, and the measurements say be careful
    -- because a sample BELOW the threshold was never clipped, so it is the
    truth, and arcing over it replaces a real value with a guess. Restoring
    programme material driven past full scale, encoded at 320 kbps, decoded,
    and scored against the original that went in:

        gap samples must reach   +1 dB over   +3 dB over   +6 dB over
        (never join)                 +1.28        +0.44        +0.19
        0.9993  (this)               +1.31        +0.58        +0.28
        0.9990                       +0.56        +0.77        +0.42
        0.9985                       +0.57        +0.87        +0.46
        (always join)                -0.11        +0.87        +0.47

    dB of improvement over leaving the clipping alone, taken before the
    shoulder slopes were allowed to flatten rather than refuse; that change
    lifted every figure in the table without reordering it, and the tolerance
    was left at the conservative end rather than re-tuned around it.
    Joining freely buys
    heavy clipping a little and costs light clipping everything it had, so
    the count of runs restored is a vanity metric and was never the thing to
    maximise. Only a threshold this tight wins in every column, and what it
    says is narrow and defensible: join across a sample only where it sits
    within a handful of 16-bit steps of the ceiling and so carries no
    information that could be lost.

    Runs are joined only where the samples between share the run's sign, so
    the fill can never push a sample through zero.
    """
    merged: list[list[int]] = []
    for start, end in runs:
        if merged and start - merged[-1][1] < gap:
            between = channel[merged[-1][1]:start] * sign
            if between.size == 0 or np.all(between >= floor):
                merged[-1][1] = end
                continue
        merged.append([start, end])
    return [(start, end) for start, end in merged]


def find_runs(channel: np.ndarray, threshold: float = CLIP_THRESHOLD,
              min_run: int = MIN_RUN,
              merge_gap: int = SHOULDER) -> list[tuple[int, int, int]]:
    """[(start, end, sign)] for each span of samples pinned at the ceiling.

    Positive and negative spans are found separately, so one can never
    straddle a sign change and be handed to the arc as a single peak.
    """
    runs = []
    for sign in (1, -1):
        found = _runs_of(channel * sign >= threshold, min_run)
        runs += [(start, end, sign)
                 for start, end in _merge_near(found, channel, sign, merge_gap,
                                               threshold - MERGE_TOLERANCE)]
    return sorted(runs)


def _slope(values: np.ndarray, at_end: bool) -> float:
    """Slope per sample at the outer end of a shoulder.

    A quadratic through the shoulder, differentiated. At the default shoulder
    of three samples this is exactly the three-point derivative; a wider
    shoulder smooths it, which is what noisy real material wants and what a
    clean synthetic fixture does not need.
    """
    index = np.arange(values.size, dtype=np.float64)
    fit = np.polyfit(index, values, min(2, values.size - 1))
    return float(np.polyval(np.polyder(fit), index[-1] if at_end else 0.0))


def _hermite(width: int, y_a: float, m_a: float, y_b: float, m_b: float,
             count: int) -> np.ndarray:
    """Cubic Hermite across a gap of `width`, at its `count` interior points.

    Matching value AND slope at both shoulders is the point: a least-squares
    fit through the surrounding samples would leave a step at each end of the
    run, and a step in a waveform is a click.
    """
    u = np.arange(1, count + 1, dtype=np.float64) / width
    u2, u3 = u * u, u * u * u
    return ((2 * u3 - 3 * u2 + 1) * y_a
            + (u3 - 2 * u2 + u) * width * m_a
            + (-2 * u3 + 3 * u2) * y_b
            + (u3 - u2) * width * m_b)


def _restore_channel(channel: np.ndarray, rate: int, tally: dict,
                     threshold: float, max_restore_db: float, shoulder: int,
                     max_run_ms: float, min_run: int) -> np.ndarray | None:
    """One channel. Returns None if nothing was changed, so that a track with
    no clipping comes back as the very same array it went in as."""
    out = None
    longest = max(min_run, int(max_run_ms * rate / 1000.0))
    runs = find_runs(channel, threshold, min_run, shoulder)
    # Which samples belong to a run, so a shoulder can be judged against the
    # runs themselves rather than against the raw threshold. A lone sample
    # grazing the ceiling is not a flat top and must not veto its neighbour:
    # checking the threshold instead cost about a third of all restorations
    # on MP3-decoded material, where grazing samples are everywhere.
    damaged = np.zeros(channel.size, dtype=bool)
    for start, end, _ in runs:
        damaged[start:end] = True
    for start, end, sign in runs:
        tally["runs"] += 1
        length = end - start
        if length > longest:
            tally["too_long"] += 1
            continue
        before, after = start - 1, end
        if before - shoulder + 1 < 0 or after + shoulder > channel.size:
            tally["at_edge"] += 1
            continue
        span = slice(before - shoulder + 1, before + 1)
        beyond = slice(after, after + shoulder)
        if damaged[span].any() or damaged[beyond].any():
            # The shoulder is itself inside a run -- another clipped span a
            # sample or two away. Its slope would describe a flat top rather
            # than the approach to a peak, and an arc built on it is fiction.
            tally["shoulder_clipped"] += 1
            continue
        left, right = channel[span], channel[beyond]

        # A peak climbs into its run and drops out of it. Where a shoulder
        # does not, its slope is dropped rather than the run being refused:
        # the arc is then drawn from whichever side is still informative, and
        # if neither is, the Hermite flattens to a line between the two
        # endpoints, nothing exceeds the audio, and it falls out below as
        # nothing_to_add. So the degenerate case still refuses itself.
        #
        # Refusing outright was the first version, and on lossless fixtures
        # the two are indistinguishable -- the guard never fires, because a
        # smooth waveform above the ceiling with clean samples either side
        # has nowhere else to be. On MP3 it fires constantly, because the
        # codec's ripple flips the sign of a three-point slope at will, and
        # refusing there threw away half the improvement: +1.34 dB became
        # +2.02, +0.68 became +1.15, +0.26 became +0.42, measured against the
        # audio that went into the encoder.
        rising = _slope(left, at_end=True)
        falling = _slope(right, at_end=False)
        if rising * sign <= 0 or falling * sign >= 0:
            rising = rising if rising * sign > 0 else 0.0
            falling = falling if falling * sign < 0 else 0.0
            tally["flattened"] += 1

        arc = _hermite(after - before, float(channel[before]), rising,
                       float(channel[after]), falling, length)
        # Clipping can only ever have made a sample smaller, so the truth is
        # at least what survived. Work in the excess over what is there, and
        # a reconstruction that dips below the input simply adds nothing.
        signed = channel[start:end] * sign
        excess = np.maximum(arc * sign - signed, 0.0)
        if excess.max() <= 0:
            tally["nothing_to_add"] += 1
            continue

        peak = float(signed.max())
        ceiling = peak * 10 ** (max_restore_db / 20)
        reached = float((signed + excess).max())
        if reached > ceiling and reached > peak:
            excess *= (ceiling - peak) / (reached - peak)
        excess = np.minimum(excess, np.maximum(ceiling - signed, 0.0))

        if out is None:
            out = channel.copy()
        # Added to the sample rather than replacing it, so the restoration
        # can only ever move away from zero.
        out[start:end] = channel[start:end] + sign * excess
        tally["restored"] += 1
        tally["samples"] += length
    return out


def restore(x: np.ndarray, rate: int, threshold: float = CLIP_THRESHOLD,
            max_restore_db: float = MAX_RESTORE_DB, shoulder: int = SHOULDER,
            max_run_ms: float = MAX_RUN_MS,
            min_run: int = MIN_RUN) -> tuple[np.ndarray, dict]:
    """Arc back over every clipped run. Returns the audio and what was done.

    The audio it returns MAY EXCEED FULL SCALE -- a restored peak is taller
    than the ceiling it hit, that being the whole idea -- so the caller owns
    making room for it. `headroom_db` in the report is how much attenuation
    that takes.

    Channels are handled independently, because clipping is: one channel can
    run out of headroom while the other has plenty.
    """
    if x.ndim != 2:
        raise ValueError(f"expected (n, channels), got {x.shape}")
    if shoulder < 2:
        raise ValueError(f"shoulder must be at least 2 samples, got {shoulder}")

    tally = {"runs": 0, "restored": 0, "samples": 0, "flattened": 0}
    tally.update({reason: 0 for reason in REFUSALS})

    work = x.astype(np.float64)
    restored = [_restore_channel(work[:, c], rate, tally, threshold,
                                 max_restore_db, shoulder, max_run_ms, min_run)
                for c in range(x.shape[1])]
    if all(channel is None for channel in restored):
        return x, _report(x, x, tally)

    out = np.column_stack([work[:, c] if channel is None else channel
                           for c, channel in enumerate(restored)])
    return out.astype(x.dtype), _report(x, out, tally)


def _report(before: np.ndarray, after: np.ndarray, tally: dict) -> dict:
    peak_before = float(np.abs(before).max()) if before.size else 0.0
    peak_after = float(np.abs(after).max()) if after.size else 0.0
    report = dict(tally)
    report["refused"] = sum(tally[reason] for reason in REFUSALS)
    report["peak_before_dbfs"] = _db(peak_before)
    report["peak_after_dbfs"] = _db(peak_after)
    report["restored_db"] = (0.0 if peak_before <= 0 or peak_after <= 0
                             else float(20 * np.log10(peak_after / peak_before)))
    report["headroom_db"] = (0.0 if peak_after <= 1.0
                             else float(20 * np.log10(peak_after)))
    return report


def _db(value: float) -> float:
    return float(20 * np.log10(value)) if value > 0 else float("-inf")


def summarise(reports: list[dict]) -> str:
    """What the de-clipper did across a batch, and what it declined to do."""
    acted = [r for r in reports if r["runs"]]
    if not acted:
        return ("  CLIPPING  no runs of samples at full scale in any track.\n"
                "  Either the masters have headroom, or -- for material that "
                "came through\n  MP3 -- the encoder moved the flat tops off "
                "the ceiling where they could\n  still be seen. This finds "
                "hard clipping only; a limiter leaves no run.")
    runs = sum(r["runs"] for r in acted)
    fixed = sum(r["restored"] for r in acted)
    lifts = [r["restored_db"] for r in acted if r["restored"]]
    lines = ["CLIPPING", "-" * 78,
             f"  {len(acted)} of {len(reports)} track(s) carried clipped runs; "
             f"{fixed} of {runs} run(s) restored."]
    if lifts:
        lines.append(f"  Peak lifted by {float(np.median(lifts)):+.2f} dB "
                     f"median, {max(lifts):+.2f} dB at most. That headroom "
                     f"comes back out")
        lines.append("  in the levelling, so nothing here makes a file louder.")
    refusals = {reason: sum(r[reason] for r in acted) for reason in REFUSALS}
    named = {
        "too_long": "too long to be a peak",
        "at_edge": "at the very start or end of the file",
        "shoulder_clipped": "no clean shoulder to arc from",
        "nothing_to_add": "already as tall as the arc",
    }
    declined = [f"{count} {named[reason]}"
                for reason, count in refusals.items() if count]
    if declined:
        lines.append(f"  Left alone: {'; '.join(declined)}.")
    flattened = sum(r.get("flattened", 0) for r in acted)
    if flattened:
        lines.append(f"  {flattened} run(s) had a shoulder that was not "
                     f"turning over, and were arced from the other side only.")
    return "\n".join(lines)
