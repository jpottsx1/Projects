"""How well a finished edit keeps the beat, read back off the file itself.

An intro or outro is laid on a grid the analysis believes in. Whether the
kicks really land where they should across each seam is a different
question, and the only honest answer is the finished audio: find its kicks,
and at every place two pieces of audio meet ask

    - where the beats BEFORE it say the next ones should fall, and how far
      the beats after it actually are from there (`offset_ms`: a slip, or a
      flam where both play at once), and
    - whether the beats after it come at the same rate (`tempo_step_pct`).

Nothing here knows how the edit was made. It reads a file and a list of
places to look, so it measures the edit and not the plan for it.
"""

from __future__ import annotations

import numpy as np

from . import subbass

# A slip this large at a seam or the join is called out. Measured on the
# test tracks (exact grids, so every slip found is the detector's own
# jitter): under 1 ms at every seam. A DJ hears a kick 5 ms late as a smear
# before hearing it as late, so that is where it starts to matter.
SLIP_WARN_MS = 5.0
# A tempo step this large across the join is called out: 0.5% is about
# 0.6 BPM at 120, which drifts a sixteenth of a beat in four bars.
TEMPO_WARN_PCT = 0.5
# Kicks either side of a meeting point that are read: four bars.
WINDOW_BEATS = 16
# Of those after it, how many are averaged for the slip. Few, so a tempo
# difference has not had time to move them.
SLIP_KICKS = 4
MIN_KICKS = 4
# On a whole mix the detector also fires on the bass and the hats, at every
# eighth note, about a fifth as strong as the kick (Night Fever: 0.04-0.18
# against 0.49-0.70). Only hits at least this share of the strongest in the
# window are counted as kicks.
STRONG = 0.35


def _strong(kicks: np.ndarray, strengths: np.ndarray) -> np.ndarray:
    if kicks.size == 0:
        return kicks
    top = float(np.percentile(strengths, 90))
    return kicks[strengths >= STRONG * top]


def _fit(kicks: np.ndarray, period: float, anchor: float) -> tuple[float, float] | None:
    """(period, phase) fitted to the kicks that sit on a beat counted from
    `anchor`, or None with too few. A syncopated kick between beats is
    left out rather than allowed to bend the line."""
    if kicks.size < MIN_KICKS:
        return None
    # Fitted, then fitted again with the beat it found: a loop resampled to
    # another tempo has beats a percent off `period`, which over four bars is
    # enough to count the wrong kicks as on the beat. We Are Family's loop,
    # resampled 1.1%, read 29 ms at its seams with the song's beat and 10.5
    # with its own (2026-10-09).
    slope, intercept = period, anchor
    for _ in range(3):
        index = np.round((kicks - intercept) / slope)
        residual = kicks - (intercept + index * slope)
        on = np.abs(residual) <= 0.2 * period
        if on.sum() < MIN_KICKS or np.unique(index[on]).size < 2:
            return None
        slope, intercept = np.polyfit(index[on], kicks[on].astype(np.float64), 1)
        slope, intercept = float(slope), float(intercept)
    # Counted from the kick nearest the anchor, as callers expect.
    shift = np.round((anchor - intercept) / slope)
    return slope, intercept + shift * slope


def meeting(kicks: np.ndarray, strengths: np.ndarray, at: int, period: float,
            rate: int, after_from: int | None = None) -> dict | None:
    """The beat across one meeting point at sample `at`: the attack of the
    first beat that belongs to the audio after it.

    `after_from` starts the kicks counted as "after" later than `at`, for an
    outro, whose original runs on past the exit bar line for its vocal tail
    before the loop is heard. None when there are too few kicks either side
    to say (a breakdown, a cold start)."""
    half = 0.5 * period
    start_after = (at if after_from is None else after_from) - half
    lo, hi = at - WINDOW_BEATS * period - half, start_after + WINDOW_BEATS * period + period
    near = (kicks >= lo) & (kicks < hi)
    found, power = kicks[near], strengths[near]
    side_b = found < at - half
    side_a = found >= start_after
    before = _strong(found[side_b], power[side_b])
    after = _strong(found[side_a], power[side_a])
    if before.size < MIN_KICKS or after.size < 2:
        return None
    anchor = float(found[side_b][np.argmax(power[side_b])])
    fit_b = _fit(before, period, anchor)
    if fit_b is None:
        return None
    p_b, phase_b = fit_b
    index = np.round((after - phase_b) / p_b)
    residual = after - (phase_b + index * p_b)
    on = np.abs(residual) <= 0.25 * period
    if on.sum() < 2:
        return None
    slip = float(np.median(residual[on][:SLIP_KICKS]))
    step = None
    fit_a = _fit(after[on], p_b, float(after[on][0]))
    if fit_a is not None:
        step = fit_a[0] / p_b - 1.0
        # With a line through the kicks on each side, the slip is how far
        # apart the two lines are AT the meeting point: where the beat lands,
        # apart from any change of tempo after it. The median of the first
        # kicks after it mixes the two in: Jungle Love's opening has a kick
        # every other beat, so its first four span eight beats, and a song a
        # little slower than its intro read as 26 ms late though its first
        # kick landed on the beat (2026-10-09).
        p_a, phase_a = fit_a
        beat = phase_b + np.round((at - phase_b) / p_b) * p_b
        anchor = float(after[on][0])
        slip = float(phase_a + np.round((beat - anchor) / p_b) * p_a - beat)
    return {
        "offset_ms": round(slip / rate * 1000.0, 2),
        "tempo_step_pct": None if step is None else round(step * 100.0, 3),
        "kicks_before": int(before.size),
        "kicks_after": int(on.sum()),
    }


def check(audio: np.ndarray, rate: int, period: float,
          places: list[tuple[str, int, int | None]], what: str) -> tuple[dict, list[str]]:
    """(report, warnings) for a finished edit.

    `places` is (name, sample, after_from) for every seam and the join or
    exit, in file samples. `what` names the edge ("join" or "exit") the way
    the report and the warnings should."""
    kicks, strengths = subbass.detect_kicks(audio, rate)
    return check_kicks(kicks, strengths, rate, period, places, what)


def check_kicks(kicks: np.ndarray, strengths: np.ndarray, rate: int, period: float,
                places: list[tuple[str, int, int | None]], what: str) -> tuple[dict, list[str]]:
    """`check`, from kicks already found: (sample, strength) pairs laid out
    the way the edit lays out the audio they came from."""
    order = np.argsort(kicks)
    kicks, strengths = kicks[order], strengths[order]
    seams, edge = [], None
    for name, at, after_from in places:
        found = meeting(kicks, strengths, at, period, rate, after_from)
        entry = {"name": name, "seconds": round(at / rate, 3),
                 **(found or {"offset_ms": None, "tempo_step_pct": None,
                              "kicks_before": 0, "kicks_after": 0})}
        if name == what:
            edge = entry
        else:
            seams.append(entry)
    measured = [s["offset_ms"] for s in seams if s["offset_ms"] is not None]
    report = {
        f"{what}_offset_ms": None if edge is None else edge["offset_ms"],
        f"{what}_tempo_step_pct": None if edge is None else edge["tempo_step_pct"],
        "worst_seam_ms": max(measured, key=abs) if measured else None,
        "seams": seams,
        "edge": edge,
    }
    warnings = []
    if edge is not None and edge["offset_ms"] is not None and abs(edge["offset_ms"]) > SLIP_WARN_MS:
        late = "late" if edge["offset_ms"] > 0 else "early"
        warnings.append(f"the beat lands {abs(edge['offset_ms']):.0f} ms {late} at the {what}")
    if edge is not None and edge["tempo_step_pct"] is not None \
            and abs(edge["tempo_step_pct"]) > TEMPO_WARN_PCT:
        faster = "slower" if edge["tempo_step_pct"] > 0 else "faster"
        side = "song" if what == "join" else "outro"
        warnings.append(f"the {side} runs {abs(edge['tempo_step_pct']):.1f}% {faster} "
                        f"after the {what}")
    bad = [s for s in seams if s["offset_ms"] is not None and abs(s["offset_ms"]) > SLIP_WARN_MS]
    if bad:
        worst = max(bad, key=lambda s: abs(s["offset_ms"]))
        warnings.append(f"the beat slips at {len(bad)} loop seam{'s' if len(bad) > 1 else ''} "
                        f"(up to {abs(worst['offset_ms']):.0f} ms)")
    if edge is not None and edge["offset_ms"] is None:
        warnings.append(f"too few kicks either side of the {what} to measure it: listen to it")
    return report, warnings
