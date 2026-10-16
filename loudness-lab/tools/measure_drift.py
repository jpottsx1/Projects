#!/usr/bin/env python3
"""How far does a live drummer drift, and could a new beat follow it?

The question behind it (Jeff, 2026-10-16): on a 1960s/70s record with a
live drummer, could the drums and bass be replaced by a modern sampled
rhythm section that follows the original drummer's tempo, so the new beat
stays locked to the old vocals and instruments? Nothing of that is built.
This measures what it would rest on, per track:

    tempo     the tempo of every bar, read off beats FOLLOWED on the drum
              stem one at a time (`intro.follow`, the intro's bar-follower
              run a beat at a time), not off a global tempo: lowest,
              highest, the spread, the largest step from one bar to the
              next, and how far single beats are pushed or pulled
    lock      how many beats (and bar lines) sat on a real drum onset and
              how many were carried on from the last one, the longest
              stretch with none (a stop, a breakdown), and how often the
              beat had to be found again after one
    held by   which onsets held each beat: the kick, then the snare where
              no kick was near, then anything on the drum stem. A 60s kick
              is often quiet or missing; the snare's 2 and 4 then carry it
    bleed     drum-like transient energy left in the "other" and "vocals"
              stems (cymbals and room on old recordings): what would still
              be heard under a replaced beat
    bass      whether the bassline tracker (`bassline.track`) finds a
              steady note in each bar, how many, how much it flickers,
              and how far the record sits off concert pitch

    python3 tools/measure_drift.py <folder or file> [<folder> ...]

Separates with Demucs through the same shared cache as everything else
(`stems.SHARED_CACHE`), so a song is separated once whichever tool runs
first. What this tool adds to the cache is its bleed envelopes; a song
separated before by another tool is separated once more to get them.

Tested on synthetic tracks with a drift put in by hand
(tests/test_measure_drift.py). Not yet run on Jeff's records.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from scipy.ndimage import median_filter
from scipy.signal import butter, find_peaks, sosfiltfilt, stft

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from loudnesslab import bassline, intro, stems, subbass  # noqa: E402

RATE = 48000
BEATS_PER_BAR = intro.BEATS_PER_BAR

# Onsets other than the kick's. The snare's body (180-250 Hz) and rattle
# are above the kick band, and the drum part the cache keeps is 8 kHz, so
# 3.5 kHz is as high as anything can be read back. The whole kit is the
# kick band to that.
SNARE_BAND_HZ = (180.0, 3500.0)
KIT_BAND_HZ = (30.0, 3500.0)
ONSET_SPACING_S = 0.06          # a sixteenth at 250 BPM
SAME_HIT_S = 0.03
SOURCES = ("kick", "snare", "kit")

# Where the tempo is looked for when there is no tag, or the tag is not
# within TAG_AGREES of what the onsets say at 1/2, 1 or 2 times it.
BPM_RANGE = (80.0, 160.0)
TAG_AGREES = 0.04

# Tempo per bar: a straight line through the onsets the beats were found
# on, over BAR_WINDOW bars either side of the bar (so 3 bars of 13 beats):
# a single beat pushed 20 ms moves a bar read off its own 5 beats by 1%,
# which is the drummer's feel and not the tempo. SMOOTH_BARS either side
# is the drift itself (lowest, highest, spread). JITTER_BEATS either side
# is the line a single beat's push or pull is read against.
BAR_WINDOW = 1
SMOOTH_BARS = 4
MIN_FOUND = 6
JITTER_BEATS = 4

# Bleed: STFT frames, and the median filters that split each frame into
# what is steady (along time) and what is a transient (along frequency),
# as Fitzgerald's harmonic/percussive split. A hit is the frames within
# HIT_FRAMES of a drum onset. What counts as bleed is the transient energy
# that FOLLOWS the drums: a stem's transient energy at the hits, less what
# it has between them over as many frames. A steady noise has transients
# by that split too, as many between hits as on them, and nets nothing.
FRAME_RATE = 100
FFT_SIZE = 1024
HPSS_FRAMES = 17
HPSS_BINS = 17
HIT_FRAMES = 2
BLEED_STEMS = ("drums", "other", "vocals")
BLEED_KEYS = tuple(f"drift_percussive_{name}" for name in BLEED_STEMS)

# Bass: a bar has a clear note when a note is found over at least
# CLEAR_SHARE of it; a note is one the bar holds for at least NOTE_SHARE;
# a run of one note shorter than FLICKER_S is the tracker, not a player.
CLEAR_SHARE = 0.5
NOTE_SHARE = 0.125
FLICKER_S = 0.06


# ------------------------------------------------------------------ onsets

def band_onsets(drums: np.ndarray, rate: int, band: tuple[float, float],
                spacing_s: float = ONSET_SPACING_S) -> np.ndarray:
    """Onsets in `band` of the drum part, found the way `detect_kicks` finds
    kicks (a fast envelope rising well above a slow one, walked back to the
    start of the attack), only in another band."""
    mono = drums.mean(axis=1) if drums.ndim == 2 else drums
    filtered = sosfiltfilt(butter(4, band, btype="band", fs=rate, output="sos"),
                           mono.astype(np.float64))
    fast = subbass._envelope(filtered, rate, 60.0)
    slow = subbass._envelope(filtered, rate, 3.0)
    if not np.any(fast > 0):
        return np.array([], dtype=int)
    floor = float(np.percentile(fast, 90)) * 1e-3 + 1e-12
    onset = (fast / (slow + floor)) * (fast > 0.15 * float(np.percentile(fast, 95)))
    peaks, _ = find_peaks(onset, height=subbass.ONSET_RATIO,
                          distance=max(1, int(spacing_s * rate)))
    return np.sort(subbass._backtrack(peaks, fast, rate)) if peaks.size else peaks


def onsets_of(x: np.ndarray, drums: np.ndarray, rate: int) -> dict[str, np.ndarray]:
    """Kicks, snares and anything on the drum part. The kicks are what the
    sub stage keeps by weight (`select_kicks`, no tag, so no grid): on a
    drum part the kick detector also fires on snares, and a beat "held by
    the kick" that was a snare would say the kick holds where it does not."""
    found, strengths = subbass.detect_kicks(x, rate, drums)
    kicks, _, _ = subbass.select_kicks(drums, rate, found, strengths, None)
    kicks = np.sort(kicks)
    # A kick's click and its upper harmonics are in the snare's band too:
    # what is there within SAME_HIT_S of a kick is that kick.
    snare = band_onsets(drums, rate, SNARE_BAND_HZ)
    if kicks.size and snare.size:
        nearest = np.abs(snare[:, None] - kicks[None, :]).min(axis=1)
        snare = snare[nearest > SAME_HIT_S * rate]
    return {"kick": kicks, "snare": snare,
            "kit": band_onsets(drums, rate, KIT_BAND_HZ)}


def estimate_bpm(onsets: np.ndarray, rate: int, n: int) -> float | None:
    """The beat the onsets repeat at most, in BPM_RANGE: autocorrelation of
    an onset train at FRAME_RATE, each lag also given half the score of its
    double (a beat repeats at two beats too, an off-beat hat does not)."""
    if onsets.size < 16:
        return None
    train = np.zeros(n * FRAME_RATE // rate + 1)
    np.add.at(train, (onsets * FRAME_RATE // rate).astype(int), 1.0)
    train = np.convolve(train, [0.25, 0.5, 1.0, 0.5, 0.25], mode="same")
    spec = np.fft.rfft(train - train.mean(), 2 * train.size)
    ac = np.fft.irfft(np.abs(spec) ** 2)[:train.size]
    lo = int(60.0 * FRAME_RATE / BPM_RANGE[1])
    hi = int(np.ceil(60.0 * FRAME_RATE / BPM_RANGE[0]))
    lags = np.arange(lo, hi + 1)
    score = ac[lags] + 0.5 * ac[np.minimum(2 * lags, ac.size - 1)]
    best = int(lags[np.argmax(score)])
    if 0 < best < ac.size - 1:
        a, b, c = ac[best - 1], ac[best], ac[best + 1]
        bend = a - 2 * b + c
        best = best + (0.5 * (a - c) / bend if bend < 0 else 0.0)
    return 60.0 * FRAME_RATE / best


def tempo_hint(estimate: float | None, tag: float | None) -> tuple[float | None, str]:
    """The tempo to look for beats at, and where it came from: the tag (or
    half or double it) when it agrees with the onsets, else the onsets."""
    if tag and estimate:
        for m in (1.0, 2.0, 0.5):
            if abs(tag * m - estimate) <= TAG_AGREES * estimate:
                return tag * m, ("the tag" if m == 1.0 else
                                 f"the tag x{m:g}")
        return estimate, f"the onsets (the tag, {tag:g}, does not fit them)"
    if estimate:
        return estimate, "the onsets (no tag)"
    return tag, "the tag (too few onsets to check it)"


# ------------------------------------------------------------- the beats

def follow_beats(drums: np.ndarray, onsets: dict[str, np.ndarray], rate: int,
                 bpm: float) -> dict | None:
    """Every beat from the drums' first to their last, followed one at a
    time on the drum part, and which onsets held each one."""
    on_beat = np.union1d(onsets["kick"], onsets["snare"])
    fitted = intro.fit_grid(on_beat, np.ones(on_beat.size), rate, bpm)
    if fitted is None:
        fitted = intro.fit_grid(onsets["kit"], np.ones(onsets["kit"].size), rate, bpm)
    period = fitted[0] if fitted is not None else 60.0 * rate / bpm
    start = None
    for c in (on_beat if on_beat.size else onsets["kit"]):
        if intro.relock(float(c), on_beat if on_beat.size else onsets["kit"],
                        period) == float(c):
            start = int(c)
            break
    if start is None:
        return None
    last = max(int(o[-1]) for o in onsets.values() if o.size)
    count = int((last - start) / period + 0.5)
    drums_abs = np.abs(drums.mean(axis=1) if drums.ndim == 2 else drums)
    # Where the first beat's attack really begins, as every later one is
    # placed (`attack`): the onset alone reads it some ms early or late.
    first_by = 0 if start in set(onsets["kick"].tolist()) else 1
    start, _ = intro.attack(drums_abs, start, onsets[SOURCES[first_by]] if
                            onsets[SOURCES[first_by]].size else on_beat, period, rate)
    beats, found, held = intro.follow(
        drums_abs, start, count, period, period, rate,
        snap_to=tuple(onsets[s] for s in SOURCES),
        relock_to=(on_beat, onsets["kit"]))
    found[0], held[0] = True, first_by
    alone = {}
    for name in SOURCES:
        _, hit, _ = intro.follow(drums_abs, start, count, period, period, rate,
                                 snap_to=(onsets[name],))
        alone[name] = float(hit[1:].mean()) if count else 0.0
    # Only up to the last beat that sat on something: after the drums stop,
    # carrying on is not losing the beat.
    end = int(np.nonzero(found)[0][-1]) + 1
    return {"period": period, "beats": beats[:end], "found": found[:end],
            "held": held[:end], "alone": alone}


def downbeat_phase(beats: np.ndarray, low: np.ndarray, period: float) -> tuple[int, float]:
    """Which beat (index % 4) starts a bar, by the low end's accents at the
    followed beats (as `intro.find_downbeat`, at the real beats instead of a
    fixed grid), and how clearly."""
    span = max(1, int(0.4 * period))
    csum = np.concatenate([[0.0], np.cumsum(low)])
    at = np.clip(beats.astype(int), 0, low.size - 1)
    energy = (csum[np.minimum(at + span, low.size)] - csum[at]) / span
    loud = energy > 0.5 * np.median(energy)
    scores = np.array([energy[(np.arange(at.size) % BEATS_PER_BAR == p) & loud].mean()
                       if np.any((np.arange(at.size) % BEATS_PER_BAR == p) & loud) else 0.0
                       for p in range(BEATS_PER_BAR)])
    order = np.argsort(scores)[::-1]
    best, second = scores[order[0]], scores[order[1]]
    return int(order[0]), float((best - second) / best) if best > 0 else 0.0


def _slope(index: np.ndarray, at: np.ndarray) -> float:
    return float(np.polyfit(index, at, 1)[0])


def tempo_curve(beats: np.ndarray, found: np.ndarray, phase: int, rate: int,
                window_bars: int) -> np.ndarray:
    """BPM for each bar (bar k starts at beat phase + 4k), from a line
    through the found beats `window_bars` bars either side; NaN with fewer
    than MIN_FOUND of them."""
    index = np.arange(beats.size)
    bars = max(0, (beats.size - 1 - phase) // BEATS_PER_BAR)
    out = np.full(bars, np.nan)
    for k in range(bars):
        lo = phase + (k - window_bars) * BEATS_PER_BAR
        hi = phase + (k + 1 + window_bars) * BEATS_PER_BAR
        pick = (index >= lo) & (index <= hi) & found
        if pick.sum() >= MIN_FOUND:
            out[k] = 60.0 * rate / _slope(index[pick], beats[pick].astype(np.float64))
    return out


def push_pull_ms(beats: np.ndarray, found: np.ndarray, rate: int) -> np.ndarray:
    """Each found beat against the line through the found beats
    JITTER_BEATS either side of it (itself left out), in ms; NaN where too
    few. Early is negative."""
    index = np.arange(beats.size)
    out = np.full(beats.size, np.nan)
    at = beats.astype(np.float64)
    for i in np.nonzero(found)[0]:
        pick = (np.abs(index - i) <= JITTER_BEATS) & found & (index != i)
        if pick.sum() >= 4:
            slope, intercept = np.polyfit(index[pick], at[pick], 1)
            out[i] = (at[i] - (slope * i + intercept)) / rate * 1000
    return out


def longest_unlocked(found: np.ndarray) -> tuple[int, int]:
    """(beats, index of its first beat) of the longest run of beats carried
    on with no onset."""
    best, best_at, run = 0, 0, 0
    for i, hit in enumerate(found):
        run = 0 if hit else run + 1
        if run > best:
            best, best_at = run, i - run + 1
    return best, best_at


# ------------------------------------------------------------------ bleed

def percussive_envelope(y: np.ndarray, rate: int) -> np.ndarray:
    """Per frame at FRAME_RATE, the energy in the transient part of `y`."""
    mono = (y.mean(axis=1) if y.ndim == 2 else y).astype(np.float32)
    hop = rate // FRAME_RATE
    # Centred frames (scipy's default padding): frame j is sample j * hop.
    _, _, spec = stft(mono, fs=rate, nperseg=FFT_SIZE, noverlap=FFT_SIZE - hop)
    power = np.abs(spec) ** 2
    steady = median_filter(power, size=(1, HPSS_FRAMES))
    sharp = median_filter(power, size=(HPSS_BINS, 1))
    return (power * (sharp > steady)).sum(axis=0).astype(np.float32)


def bleed_envelopes(parts: dict[str, np.ndarray], rate: int) -> dict[str, np.ndarray]:
    return {key: percussive_envelope(parts[name], rate)
            for key, name in zip(BLEED_KEYS, BLEED_STEMS)}


def bleed(envelopes: dict[str, np.ndarray], hits: np.ndarray, rate: int,
          span: tuple[int, int]) -> dict[str, dict]:
    """For "other" and "vocals": the transient energy in them that follows
    the drums, against the drum part's own, in dB (None: none follows them);
    and the share of their transient energy on the hits, beside the share of
    frames that are hits (what it would be by chance). Over `span`
    (samples), where the drums play."""
    drums = envelopes[BLEED_KEYS[0]].astype(np.float64)
    lo = max(0, span[0] * FRAME_RATE // rate)
    hi = min(drums.size, span[1] * FRAME_RATE // rate + 1)
    near = np.zeros(drums.size, dtype=bool)
    for f in (hits * FRAME_RATE // rate).astype(int):
        near[max(0, f - HIT_FRAMES):f + HIT_FRAMES + 1] = True
    near = near[lo:hi]

    def following(e: np.ndarray) -> float:
        if not near.any() or near.all():
            return 0.0
        return max(0.0, float(e[near].sum() - e[~near].mean() * near.sum()))

    reference = following(drums[lo:hi])
    out = {}
    for key, name in zip(BLEED_KEYS[1:], BLEED_STEMS[1:]):
        e = np.zeros(hi - lo)
        got = envelopes[key].astype(np.float64)[lo:hi]
        e[:got.size] = got
        locked, energy = following(e), e.sum()
        out[name] = {
            "db": (float(10 * np.log10(locked / reference))
                   if locked > 0 and reference > 0 else None),
            "on_hits": float(e[near].sum() / energy) if energy > 0 else None,
            "chance": float(near.mean()) if near.size else 0.0,
        }
    return out


# ------------------------------------------------------------------ bass

def bass_per_bar(bass: np.ndarray, rate: int, bar_lines: np.ndarray) -> dict:
    """What `bassline.track` hears in each bar: the record's tuning against
    concert pitch, then per bar the share with a note, the notes held, and
    how much of the voiced time is runs too short to be playing."""
    f0, _ = bassline.track(bass, rate)
    voiced = f0 > 0
    if not voiced.any() or bar_lines.size < 2:
        return {"tuning_cents": None, "bars": 0, "clear": 0.0,
                "notes_median": None, "flicker": None, "notes": []}
    semis = 12 * np.log2(np.where(voiced, f0, 1.0) / 440.0) + 69
    # A record off concert pitch (tape speed) sits between two semitones,
    # and rounding there flips between them: the offset is taken out first.
    angle = np.exp(2j * np.pi * semis[voiced])
    tuning = float(np.angle(angle.mean()) / (2 * np.pi))
    note = np.where(voiced, np.round(semis - tuning), -1).astype(int)
    # Runs of one note, for the flicker.
    short = np.zeros(note.size, dtype=bool)
    change = np.flatnonzero(np.diff(note)) + 1
    edges = np.concatenate([[0], change, [note.size]])
    for a, b in zip(edges[:-1], edges[1:]):
        if note[a] >= 0 and (b - a) < FLICKER_S * bassline.FRAME_RATE:
            short[a:b] = True
    frames = (bar_lines * bassline.FRAME_RATE // rate).astype(int)
    clear, counts, held = 0, [], []
    for a, b in zip(frames[:-1], frames[1:]):
        bar = note[a:min(b, note.size)]
        if bar.size == 0:
            held.append([])
            continue
        share = float((bar >= 0).mean())
        values, n = np.unique(bar[bar >= 0], return_counts=True)
        notes = [int(v) for v, c in zip(values, n) if c >= NOTE_SHARE * bar.size]
        held.append(notes)
        if share >= CLEAR_SHARE:
            clear += 1
            counts.append(len(notes))
    bars = frames.size - 1
    return {"tuning_cents": tuning * 100, "bars": bars,
            "clear": clear / bars if bars else 0.0,
            "notes_median": float(np.median(counts)) if counts else None,
            "flicker": float(short[voiced].mean()), "notes": held}


# --------------------------------------------------------------- a track

def measure(x: np.ndarray, parts: dict[str, np.ndarray], rate: int,
            tag: float | None = None) -> dict:
    """Everything the report says about one track. `parts` holds "drums"
    and "bass" (as long as `x`) and the bleed envelopes (`BLEED_KEYS`)."""
    drums = parts["drums"]
    onsets = onsets_of(x, drums, rate)
    estimate = estimate_bpm(np.union1d(onsets["kick"], onsets["snare"]), rate, x.shape[0])
    if estimate is None:
        estimate = estimate_bpm(onsets["kit"], rate, x.shape[0])
    hint, hint_from = tempo_hint(estimate, tag)
    out = {"tag": tag, "estimate": estimate, "hint": hint, "hint_from": hint_from,
           "seconds": x.shape[0] / rate, "onsets": {k: int(v.size) for k, v in onsets.items()}}
    if hint is None:
        out["failed"] = "no tempo: too few drum onsets, and no tag"
        return out
    followed = follow_beats(drums, onsets, rate, hint)
    if followed is None or followed["beats"].size < 3 * BEATS_PER_BAR:
        out["failed"] = "no steady beat found on the drum part"
        return out
    beats, found, held = followed["beats"], followed["found"], followed["held"]
    low = intro._low_band(drums + parts["bass"], rate)
    phase, confidence = downbeat_phase(beats, low, followed["period"])
    per_bar = tempo_curve(beats, found, phase, rate, BAR_WINDOW)
    smooth = tempo_curve(beats, found, phase, rate, SMOOTH_BARS)
    jitter = push_pull_ms(beats, found, rate)
    bar_lines = beats[phase::BEATS_PER_BAR]
    lines_found = found[phase::BEATS_PER_BAR]
    run, run_at = longest_unlocked(found)
    n_snap = len(SOURCES)
    shares = {name: float((held == i).mean()) for i, name in enumerate(SOURCES)}
    shares["relocked"] = float((held >= n_snap).mean())
    shares["none"] = float((held < 0).mean())
    steps = np.abs(np.diff(per_bar)) / per_bar[:-1] * 100
    valid = np.isfinite(smooth)
    out.update({
        "beats": beats, "found": found, "held": held, "phase": phase,
        "downbeat_confidence": confidence, "period": followed["period"],
        "per_bar": per_bar, "smooth": smooth, "push_pull": jitter,
        "bar_lines": bar_lines, "lines_found": lines_found,
        "alone": followed["alone"], "shares": shares,
        "longest_unlocked_beats": run, "longest_unlocked_at": int(beats[run_at]) if run else None,
        "relocks": int((held >= n_snap).sum()),
        "start_bpm": float(smooth[valid][0]) if valid.any() else None,
        "end_bpm": float(smooth[valid][-1]) if valid.any() else None,
        "min_bpm": float(np.nanmin(smooth)) if valid.any() else None,
        "max_bpm": float(np.nanmax(smooth)) if valid.any() else None,
        "spread_pct": (float((np.nanmax(smooth) - np.nanmin(smooth)) / np.nanmedian(smooth) * 100)
                       if valid.any() else None),
        "largest_step_pct": float(np.nanmax(steps)) if np.isfinite(steps).any() else None,
        "largest_step_bar": int(np.nanargmax(steps)) + 1 if np.isfinite(steps).any() else None,
        "push_pull_median_ms": float(np.nanmedian(np.abs(jitter))) if np.isfinite(jitter).any() else None,
        "push_pull_p90_ms": float(np.nanpercentile(np.abs(jitter), 90)) if np.isfinite(jitter).any() else None,
    })
    if all(k in parts for k in BLEED_KEYS):
        out["bleed"] = bleed({k: parts[k] for k in BLEED_KEYS}, onsets["kit"], rate,
                             (int(beats[0]), int(beats[-1])))
    out["bass"] = bass_per_bar(parts["bass"], rate, bar_lines)
    return out


# ---------------------------------------------------------------- report

def _clock(samples: float, rate: int) -> str:
    s = samples / rate
    return f"{int(s // 60)}:{s % 60:04.1f}"


def describe(r: dict, name: str, rate: int = RATE) -> str:
    """One track, as the report prints it."""
    tag = f"tag {r['tag']:g}" if r.get("tag") else "no tag"
    est = f"onsets say {r['estimate']:.1f}" if r.get("estimate") else "no tempo in the onsets"
    lines = [f"{name}  ({tag}; {est}; looked for at {r['hint']:.1f} from {r['hint_from']})"
             if r.get("hint") else f"{name}  ({tag}; {est})"]
    if r.get("failed"):
        lines.append(f"    not measured: {r['failed']}")
        return "\n".join(lines)
    bars = r["per_bar"].size
    lines.append(
        f"    tempo: {r['start_bpm']:.1f} at the start, {r['end_bpm']:.1f} at the end; "
        f"{r['min_bpm']:.1f}-{r['max_bpm']:.1f} BPM over {bars} bars, spread "
        f"{r['spread_pct']:.1f}%; largest bar-to-bar step {r['largest_step_pct']:.1f}% "
        f"(bar {r['largest_step_bar']})")
    if r["push_pull_median_ms"] is not None:
        lines.append(f"    single beats off the local tempo: median {r['push_pull_median_ms']:.1f} ms, "
                     f"90% within {r['push_pull_p90_ms']:.1f} ms")
    found, beats = r["found"], r["beats"]
    lock = (f"    lock: {int(found.sum())} of {found.size} beats on a drum onset "
            f"({found.mean():.0%}), {int((~found).sum())} carried on; bar lines "
            f"{int(r['lines_found'].sum())} of {r['lines_found'].size}")
    if r["longest_unlocked_beats"]:
        n = r["longest_unlocked_beats"]
        lock += (f"; longest with no lock {n} beats ({n / BEATS_PER_BAR:.1f} bars) "
                 f"from {_clock(r['longest_unlocked_at'], rate)}")
    lock += f"; found again {r['relocks']} times"
    lines.append(lock)
    if r["downbeat_confidence"] < intro.DOWNBEAT_CONFIDENCE:
        lines.append(f"    bars counted from beat {r['phase'] + 1} of the first, a guess: the low "
                     f"end accents no beat clearly ({r['downbeat_confidence']:.2f}); the bass "
                     "per bar may be half a bar out")
    s, a = r["shares"], r["alone"]
    lines.append(
        f"    held by: kick {s['kick']:.0%}, snare {s['snare']:.0%}, rest of the kit "
        f"{s['kit']:.0%}, found again after a gap {s['relocked']:.0%}, nothing {s['none']:.0%}. "
        f"Followed alone: the kick holds {a['kick']:.0%} of beats, the snare "
        f"{a['snare']:.0%}, the whole kit {a['kit']:.0%} -- {held_verdict(r)}")
    if r.get("bleed"):
        parts = []
        for stem, b in r["bleed"].items():
            if b["db"] is None:
                parts.append(f"{stem}: none that follows the drums")
            else:
                parts.append(f"{stem} {b['db']:+.0f} dB, {b['on_hits']:.0%} of it on drum hits "
                              f"({b['chance']:.0%} by chance)")
        lines.append("    drum bleed (transient energy following the drums, against the drum part's): " + "; ".join(parts))
    else:
        lines.append("    drum bleed: not measured (no bleed envelopes kept)")
    b = r["bass"]
    if b["tuning_cents"] is None:
        lines.append("    bass: no notes found")
    else:
        lines.append(
            f"    bass: a clear note in {b['clear']:.0%} of bars, "
            + (f"median {b['notes_median']:g} notes a bar" if b["notes_median"] is not None
               else "no bar with a clear note")
            + f"; {b['flicker']:.0%} of the notes' time flickers (runs under "
            f"{FLICKER_S * 1000:.0f} ms); {b['tuning_cents']:+.0f} cents off concert pitch")
    return "\n".join(lines)


HELD_ENOUGH = 0.9


def held_verdict(r: dict) -> str:
    """Which onsets were needed for nine beats in ten of those found."""
    s = r["shares"]
    found = 1.0 - s["none"]
    if found < 0.8:
        return "the beat was lost for long stretches"
    if s["kick"] >= HELD_ENOUGH * found:
        return "the kick held"
    if s["kick"] + s["snare"] >= HELD_ENOUGH * found:
        return "kick and snare between them held"
    return "the rest of the kit was needed"


def summary(results: list[tuple[str, dict]], title: str) -> str:
    done = [r for _, r in results if not r.get("failed")]
    lines = [f"{title}: {len(results)} tracks, {len(done)} measured"]
    if not done:
        return "\n".join(lines)

    def spread(key, fmt="{:.1f}"):
        v = np.array([r[key] for r in done if r.get(key) is not None], dtype=float)
        if not v.size:
            return "-"
        return (fmt.format(np.median(v)) + " median, "
                + fmt.format(v.min()) + "-" + fmt.format(v.max()))

    lines.append(f"  tempo spread %: {spread('spread_pct')}")
    lines.append(f"  largest bar-to-bar step %: {spread('largest_step_pct')}")
    lines.append(f"  beat push/pull, median ms: {spread('push_pull_median_ms')}")
    locked = np.array([r["found"].mean() * 100 for r in done])
    lines.append(f"  beats on an onset %: {np.median(locked):.0f} median, "
                 f"{locked.min():.0f}-{locked.max():.0f}")
    gaps = np.array([r["longest_unlocked_beats"] / BEATS_PER_BAR for r in done])
    lines.append(f"  longest stretch with no lock, bars: {np.median(gaps):.1f} median, "
                 f"{gaps.max():.1f} at most; {int((gaps >= 2).sum())} tracks with 2 bars or more")
    verdicts: dict[str, int] = {}
    for r in done:
        verdicts[held_verdict(r)] = verdicts.get(held_verdict(r), 0) + 1
    lines.append("  " + "; ".join(f"{v}: {n}" for v, n in verdicts.items()))
    for stem in BLEED_STEMS[1:]:
        v = np.array([r["bleed"][stem]["db"] for r in done
                      if r.get("bleed") and r["bleed"][stem]["db"] is not None])
        if v.size:
            lines.append(f"  drum bleed in {stem}, dB: {np.median(v):+.0f} median, "
                         f"{v.min():+.0f} to {v.max():+.0f}")
    clear = np.array([r["bass"]["clear"] * 100 for r in done if r["bass"]["tuning_cents"] is not None])
    if clear.size:
        lines.append(f"  bars with a clear bass note %: {np.median(clear):.0f} median, "
                     f"{clear.min():.0f}-{clear.max():.0f}")
    return "\n".join(lines)


# ---------------------------------------------------------- separation

def parts_for(x: np.ndarray, backend: str, cache: Path) -> tuple[dict, bool]:
    """({"drums", "bass", *BLEED_KEYS}, whether it was all kept already).
    A first run keeps what it separated and reads it back the same way a
    second run will, so the two report the same numbers."""
    kept = stems.load_extra(cache, x, BLEED_KEYS)
    report = stems.load_report_parts(cache, x, RATE)
    hit = kept is not None and report is not None
    if not hit:
        parts = stems.separate(x, RATE, backend)
        stems.store_kick_source(cache, x, RATE, parts["drums"],
                                [parts["vocals"], parts["other"]], bass=parts["bass"])
        stems.keep_extra(cache, x, bleed_envelopes(parts, RATE))
        del parts
        kept = stems.load_extra(cache, x, BLEED_KEYS)
        report = stems.load_report_parts(cache, x, RATE)
    return {**report, **kept}, hit


def measure_files(paths: list[Path], backend: str = "demucs",
                  cache: Path = stems.SHARED_CACHE) -> int:
    from loudnesslab import decode
    decode.require_tools()
    folders = []
    for path in paths:
        files = decode.find_audio(path) if path.is_dir() else [path]
        folders.append((path, files))
    everything = []
    for folder, files in folders:
        print(f"\n== {folder}  ({len(files)} tracks)\n", flush=True)
        results = []
        for path in files:
            try:
                x = decode.decode(path, RATE)
                parts, hit = parts_for(x, backend, cache)
                tag, _ = decode.tempo_with_source(path)
                r = measure(x, parts, RATE, tag)
            except Exception as e:  # one bad file is not a failed run
                r = {"failed": f"{type(e).__name__}: {e}"}
                print(f"{path.name}\n    not measured: {r['failed']}\n", flush=True)
                results.append((path.name, r))
                continue
            print(describe(r, path.name) + ("" if hit else "\n    (separated now; kept for next time)")
                  + "\n", flush=True)
            results.append((path.name, r))
        print(summary(results, folder.name), flush=True)
        everything += results
    if len(folders) > 1:
        print("\n" + summary(everything, "Every folder"), flush=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("paths", nargs="+", type=Path, help="folders or tracks")
    parser.add_argument("--backend", default="demucs", choices=stems.BACKENDS)
    parser.add_argument("--cache", type=Path, default=stems.SHARED_CACHE)
    args = parser.parse_args()
    return measure_files(args.paths, args.backend, args.cache)


if __name__ == "__main__":
    sys.exit(main())
