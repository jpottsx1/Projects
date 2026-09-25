"""Putting dynamic range back into a master that had it taken out.

"Over-compressed" is three different injuries, and they want three
different repairs. Treating them as one knob is why a plain broadband
expander pumps:

  peak truncation   flat tops, where the limiter ran out of room
                    measured by clip_runs, repaired by `declip` -- the only
                    stage here that RECOVERS anything, because the shape of
                    the surviving waveform says where the peak was going

  micro-dynamics    the attack of a kick or a snare flattened by a fast
                    limiter, over milliseconds
                    measured by crest (true peak minus integrated loudness,
                    the peak-to-loudness ratio), repaired by `restore_transients`

  macro-dynamics    the verse against the chorus, the breakdown against the
                    drop, over bars
                    measured by LRA, repaired by `restore_range`

Nothing but de-clipping recovers information. These two reshape what
survived, which is worth doing and worth being honest about: a compressor
that took 8 dB off a chorus did not record what it removed, so what comes
back is a plausible shape rather than the original one.

Separating the two timescales is what keeps it from pumping. One gain
trying to serve both has to be fast enough for a snare and slow enough for
a chorus, and the compromise is audible as breathing. Two gains, each slow
or fast enough to be inaudible in its own right, are not.

A caution for DJ use, which is what this project is for: macro range is
the one to be careful with. A track that drops 8 LU in the breakdown
disappears under the next record. The drop hitting harder comes mostly
from the quiet part being pulled DOWN and the whole file then being
levelled back up -- which is why `restore_range` only ever attenuates.
"""

from __future__ import annotations

import numpy as np
from scipy.signal import butter, sosfiltfilt

from . import bs1770

# --- macro -----------------------------------------------------------------

DEFAULT_TARGET_LRA = 7.0
# How far the quiet parts may be pulled down. A cap rather than an estimate:
# past a few dB the intro of a record stops being quiet and starts being
# missing, and there is no measurement that says where that is.
MAX_ATTENUATION_DB = 6.0
# Close enough to the target to leave alone, matching the 0.5 dB the sub
# stage uses for the same purpose. Measured need for it: CD2 of the 1999
# corpus sits at LRA 6.49 against a target of 7.0, which is a stretch of
# 0.079 -- half a decibel at the quietest point of the record. That is not
# a restoration, it is arithmetic, and reporting it as work done makes the
# stage look like it acted when it did not.
RANGE_MARGIN_LU = 0.5
# The gain may move this fast and no faster. A 3 s window already smooths
# heavily; this is the second guard, and it is what separates "the mix
# breathes" from "the breakdown is quieter".
SLEW_DB_PER_S = 1.5

# --- micro -----------------------------------------------------------------

DEFAULT_TRANSIENT_DB = 3.0
# Envelope corners. A butterworth low-pass on the rectified signal settles
# in roughly 1/(2*pi*f): 80 Hz is about 2 ms, fast enough to follow a beater
# click; 6 Hz is about 26 ms, slow enough to sit still through one.
FAST_HZ = 80.0
SLOW_HZ = 6.0
# Where the fast envelope stands this far above the slow one, the full
# amount is applied. Below it, proportionally less, so a sustained note gets
# nothing and an onset gets all of it.
TRANSIENT_REF_DB = 6.0
# The gain curve itself is smoothed, or its own edges are a click.
GAIN_SMOOTH_HZ = 300.0
# Below this the slow envelope is room tone, tape hiss or the gap between
# tracks. Emphasising its "transients" is emphasising noise.
SILENCE_FLOOR_DBFS = -60.0
# A track already this peaky was not squashed, whatever era it is from.
MIN_CREST_DB = 12.0


def _envelope(signal: np.ndarray, rate: int, hz: float) -> np.ndarray:
    """Zero-phase envelope of a rectified signal.

    filtfilt, not filt, for the reason `subbass._envelope` gives: a causal
    envelope lags the attack by tens of milliseconds, and a gain that late
    emphasises the tail of a transient rather than its front -- which is
    audibly the opposite of what a transient shaper is for.
    """
    return sosfiltfilt(butter(2, hz, btype="low", fs=rate, output="sos"),
                       np.abs(signal))


def _hold(values: np.ndarray, keep: np.ndarray) -> np.ndarray:
    """Carry the last gated value across a gap; leave the head at zero.

    A block below the absolute gate has no loudness, so it has no gain of
    its own, and the two ends of the track want opposite answers.

    A gap in the MIDDLE -- a breakdown that drops to a noise floor -- takes
    the attenuation either side of it. Snapping it to zero would be a lift
    in the middle of the quietest bar in the record, which is both audible
    and backwards.

    The run BEFORE the first gated block is different: it is what comes
    before the programme starts, and the stage has no business touching it.
    Carrying the first gated value back over it does not work either, and
    the reason is the window: a 3 s block straddling the boundary reads
    several dB low, so back-filling paints the quietest block of the
    transition across the whole opening. Measured, that put 4.7 dB of
    attenuation on the front of a track whose first four seconds were a
    noise floor at -85 dBFS.
    """
    if not keep.any():
        return np.zeros_like(values)
    index = np.where(keep, np.arange(keep.size), -1)
    np.maximum.accumulate(index, out=index)
    head = index < 0
    out = values[np.where(head, 0, index)]
    out[head] = 0.0
    return out


def _slew(gain: np.ndarray, db_per_s: float, hop_s: float) -> np.ndarray:
    """Bound how fast the gain may move, without making it late.

    Forwards and backwards, taking whichever is higher. A forward-only
    limiter trails the music: the attenuation arrives after the breakdown
    has started and, worse, is still there for the first moment of the drop.
    Running it both ways and keeping the larger value bounds the rate just
    as tightly -- the maximum of two Lipschitz curves has the same constant
    -- while erring towards not attenuating, so the gain is already back up
    when the drop lands.

    When this matters is worth being precise about, because on most
    material it does not. The gain is a scaled copy of a 3 s moving
    average, so its slope is roughly stretch * step / 3 s; on a mildly
    squashed track that comes out under the limit and the limiter never
    binds at all. Measured on a 9 dB breakdown at the default settings,
    forwards-only and both-ways differ by 0.07 dB -- nothing.

    It is the badly squashed records this stage is FOR that bind it. On a
    fixture measuring 0.93 LU asked to reach 12, forwards-only sat 6 dB
    behind at the drop and took seven seconds to recover; both ways was
    within 1 dB in one. That case is the whole reason the second pass is
    here, and the reason it is not deleted as unused machinery.
    """
    step = max(db_per_s * hop_s, 1e-9)
    forward = gain.copy()
    for i in range(1, forward.size):
        forward[i] = min(max(gain[i], forward[i - 1] - step), forward[i - 1] + step)
    backward = gain.copy()
    for i in range(backward.size - 2, -1, -1):
        backward[i] = min(max(gain[i], backward[i + 1] - step), backward[i + 1] + step)
    return np.maximum(forward, backward)


def _blank_range(note: str | None = None) -> dict:
    return {"applied": False, "lra_before": None, "lra_after": None,
            "target_lra": None, "max_attenuation_db": 0.0,
            "mean_attenuation_db": 0.0, "capped": False, "note": note}


def restore_range(x: np.ndarray, rate: int,
                  target_lra: float = DEFAULT_TARGET_LRA,
                  max_attenuation_db: float = MAX_ATTENUATION_DB,
                  slew_db_per_s: float = SLEW_DB_PER_S,
                  margin_lu: float = RANGE_MARGIN_LU) -> tuple[np.ndarray, dict]:
    """Pull the quiet passages down until the track's loudness range reaches
    `target_lra`. Returns the audio and a report.

    Down, never up. The loud passages of a loudness-war master have no
    headroom left -- that is what made it one -- so a stage that tried to
    raise them would clip or be trimmed straight back. Anchoring at the 95th
    percentile and attenuating everything below it leaves the loudest
    moments exactly as they were and costs the track some average loudness,
    which the levelling that ends the chain gives back. The drop is louder
    afterwards in absolute terms; what changed is what sits around it.
    """
    if target_lra <= 0:
        return x, _blank_range("no range target asked for")
    centres, loudness, mean_square = bs1770.short_term_series(x, rate)
    if loudness.size < 2:
        return x, _blank_range("too short to measure a loudness range")

    keep = loudness > bs1770.ABS_GATE
    if keep.sum() < 2:
        return x, _blank_range("nothing above the absolute gate")
    # The same relative gate EBU Tech 3342 uses, so the LRA this is aimed at
    # is the LRA that gets reported.
    first = mean_square[keep].mean(axis=0) @ bs1770.WEIGHTS
    keep &= loudness > (bs1770.OFFSET + 10.0 * np.log10(first)
                        + bs1770.REL_GATE_LRA)
    values = loudness[keep]
    if values.size < 2:
        return x, _blank_range("nothing above the relative gate")

    top = float(np.percentile(values, 95))
    lra = top - float(np.percentile(values, 10))
    report = _blank_range()
    report["lra_before"] = lra
    report["target_lra"] = target_lra
    if lra >= target_lra - abs(margin_lu):
        report["note"] = (f"already {lra:.1f} LU, within {abs(margin_lu):.1f} "
                          f"of the target")
        return x, report

    # How much wider everything below the anchor has to sit.
    stretch = target_lra / lra - 1.0
    gain = np.zeros_like(loudness)
    gain[keep] = np.clip((loudness[keep] - top) * stretch,
                         -abs(max_attenuation_db), 0.0)
    gain = _slew(_hold(gain, keep), slew_db_per_s, bs1770.SHORT_HOP_S)

    times = np.arange(x.shape[0]) / rate
    # Held flat beyond the first and last block centre rather than
    # extrapolated: np.interp does that by default, and extrapolating a gain
    # curve off the end of the music is inventing a fade.
    per_sample = np.interp(times, centres, gain)
    y = (x * (10.0 ** (per_sample / 20.0))[:, None]).astype(x.dtype)

    _, after_l, after_ms = bs1770.short_term_series(y, rate)
    deepest = float(-gain.min())
    capped = deepest >= abs(max_attenuation_db) - 1e-9
    report.update({
        "applied": True,
        "lra_after": bs1770.loudness_range(after_ms, after_l),
        "max_attenuation_db": deepest,
        "mean_attenuation_db": float(-gain.mean()),
        "capped": capped,
    })
    if capped:
        # Said rather than silently delivered: the target was not reached,
        # and a caller that raised the target expecting more should be told
        # the limit is the cap and not the setting.
        report["note"] = (f"the {abs(max_attenuation_db):.0f} dB floor was "
                          f"reached; the target needed more")
    return y, report


def _blank_transient(note: str | None = None) -> dict:
    return {"applied": False, "amount_db": 0.0, "crest_before": None,
            "crest_after": None, "max_lift_db": 0.0, "lifted_fraction": 0.0,
            "lufs_change_db": 0.0, "peak_change_db": 0.0, "note": note}


def restore_transients(x: np.ndarray, rate: int,
                       amount_db: float = DEFAULT_TRANSIENT_DB,
                       min_crest_db: float = MIN_CREST_DB,
                       ref_db: float = TRANSIENT_REF_DB,
                       fast_hz: float = FAST_HZ,
                       slow_hz: float = SLOW_HZ) -> tuple[np.ndarray, dict]:
    """Give the attacks back their edge. Returns the audio and a report.

    Two envelopes of the same signal, one that can follow a beater click and
    one that cannot. Where the fast one stands above the slow one there is
    an onset, and only there is any gain applied. A sustained note gives the
    two envelopes the same value and therefore no gain at all, which is the
    property that separates this from an expander: it cannot turn a quiet
    passage down, so it cannot breathe.

    The gain is computed from the mono sum and applied to both channels, so
    nothing moves in the stereo image.

    Crest is the measurement -- this is the stage that should move it.
    `subbass.shape_attacks` deliberately does not: a band-limited change
    lasting eight milliseconds leaves the track's peak-to-loudness ratio
    where it found it, and that was the right answer for a stage meant to
    touch only the kick. This one is broadband and meant to change the
    track's dynamic character, so a crest that does not move means it did
    nothing.
    """
    report = _blank_transient()
    if amount_db <= 0:
        report["note"] = "no transient emphasis asked for"
        return x, report

    before = bs1770.measure(x, rate)
    report["crest_before"] = before["crest_db"]
    if before["crest_db"] is not None and before["crest_db"] >= min_crest_db:
        report["note"] = (f"crest is already {before['crest_db']:.1f} dB -- "
                          f"peaky enough, nothing was flattened")
        return x, report

    mono = x.mean(axis=1)
    fast = _envelope(mono, rate, fast_hz)
    slow = _envelope(mono, rate, slow_hz)
    # A floor on the divisor rather than an epsilon: the ratio of two tiny
    # numbers is noise amplified, and this stage would then find transients
    # in the hiss between tracks.
    floor = 10.0 ** (SILENCE_FLOOR_DBFS / 20.0)
    with np.errstate(divide="ignore", invalid="ignore"):
        above = 20.0 * np.log10(np.maximum(fast, floor)
                                / np.maximum(slow, floor))
    above = np.nan_to_num(above, nan=0.0, posinf=0.0, neginf=0.0)
    lift = amount_db * np.clip(above / max(ref_db, 1e-6), 0.0, 1.0)
    lift[slow < floor] = 0.0
    lift = sosfiltfilt(butter(2, GAIN_SMOOTH_HZ, btype="low", fs=rate,
                              output="sos"), lift)
    # filtfilt can overshoot a step by a few percent; the cap keeps the
    # promise the amount makes, and clipping at zero keeps it from ever
    # turning anything DOWN, which is the expander behaviour being avoided.
    lift = np.clip(lift, 0.0, amount_db)

    y = (x * (10.0 ** (lift / 20.0))[:, None]).astype(x.dtype)
    after = bs1770.measure(y, rate)
    report.update({
        "applied": True,
        "amount_db": float(amount_db),
        "crest_after": after["crest_db"],
        "max_lift_db": float(lift.max()),
        # The statistic that says this shaped transients rather than
        # gaining the file. A steady tone reads 0.006 -- its own onset at
        # sample zero and nothing else -- where `max_lift_db` reads the
        # full amount and sounds alarming.
        "lifted_fraction": float((lift > 0.5).mean()),
        "lufs_change_db": _delta(after["lufs_i"], before["lufs_i"]),
        "peak_change_db": _delta(after["true_peak_dbtp"],
                                 before["true_peak_dbtp"]),
    })
    return y, report


def _delta(after: float | None, before: float | None) -> float:
    if after is None or before is None:
        return 0.0
    return float(after - before)


def summarise(range_reports: list[dict], transient_reports: list[dict]) -> str:
    """What the two stages did across a batch, for the end of a run."""
    lines = ["DYNAMICS  (what came back, and what was already there)",
             "-" * 78]
    done = [r for r in range_reports if r.get("applied")]
    if not range_reports:
        lines.append("  Range: not asked for.")
    elif not done:
        lines.append(f"  Range: no track needed it -- all {len(range_reports)} "
                     f"already at or above the target.")
    else:
        before = np.median([r["lra_before"] for r in done])
        after = [r["lra_after"] for r in done if r["lra_after"] is not None]
        pulled = np.median([r["max_attenuation_db"] for r in done])
        lines.append(f"  Range: {len(done)} of {len(range_reports)} widened. "
                     f"LRA {before:.1f} -> "
                     + (f"{np.median(after):.1f} LU median, " if after else "? , ")
                     + f"quiet passages pulled down {pulled:.1f} dB at most.")
        lines.append("    The loudest moments were not touched. The levelling "
                     "at the end of the")
        lines.append("    chain puts the average back, so the drop ends up "
                     "louder than it started.")
    done = [r for r in transient_reports if r.get("applied")]
    if not transient_reports:
        lines.append("  Attack: not asked for.")
    elif not done:
        lines.append(f"  Attack: no track needed it -- all "
                     f"{len(transient_reports)} were already peaky enough.")
    else:
        pairs = [(r["crest_before"], r["crest_after"]) for r in done
                 if r["crest_before"] is not None and r["crest_after"] is not None]
        if pairs:
            gained = np.median([a - b for b, a in pairs])
            lines.append(f"  Attack: {len(done)} of {len(transient_reports)} "
                         f"shaped. Crest {np.median([b for b, _ in pairs]):.1f} "
                         f"-> {np.median([a for _, a in pairs]):.1f} dB "
                         f"({gained:+.1f}).")
            lines.append("    Crest is the measurement here, unlike the kick "
                         "punch: a broadband")
            lines.append("    change that leaves it where it found it did "
                         "nothing.")
        else:
            lines.append(f"  Attack: {len(done)} shaped, crest unmeasurable.")
    return "\n".join(lines)
