"""Is this kick a drum machine? Two measurements that should say so.

A LinnDrum, a DMX, an 808 or a sampler plays the same recording on every
kick, exactly on its grid. A drummer does neither. If that difference
shows plainly on real records, the sub stage can treat a machine track
differently: find the kick by matching its sound rather than by guessing
at each hit, trust the repeating pattern, and build the sub from the kick
itself. This module only measures; nothing processes on it yet.

- `kick_template`: line the kicks up to the sample and average them. How
  closely each kick matches that average is `similarity` -- a machine's
  kicks are copies of one sample, a drummer's are not.
- `grid_jitter_ms`: how far each (sample-aligned) kick lands from the
  local grid. A sequencer is exact; a drummer is not, by milliseconds.
"""

from __future__ import annotations

import numpy as np
from scipy.signal import butter, sosfiltfilt

# The band the kicks are compared in: the body and the beater click, not
# the hats and cymbals that sit over some of them.
BAND_HZ = (30.0, 2000.0)
WINDOW_S = 0.05                 # the attack and body of a kick
MAX_SHIFT_S = 0.003             # how far an onset may be moved to line up
SAMPLE = 200                    # kicks enough for an average


def _aligned(band: np.ndarray, starts: np.ndarray, length: int, shift: int,
             template: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Each window moved by up to `shift` samples to best match `template`.
    Returns (windows, the move applied to each)."""
    windows, moves = [], []
    for s in starts:
        best, best_score = 0, -np.inf
        for d in range(-shift, shift + 1):
            seg = band[s + d:s + d + length]
            if seg.size < length:
                continue
            score = float(np.dot(seg, template))
            if score > best_score:
                best, best_score = d, score
        windows.append(band[s + best:s + best + length])
        moves.append(best)
    return np.array(windows), np.array(moves)


def kick_template(drums: np.ndarray, rate: int, kicks: np.ndarray
                  ) -> tuple[np.ndarray, np.ndarray, np.ndarray] | None:
    """(template, similarity per kick, sample-aligned onsets), or None.

    The kicks are lined up to the sample against their own average, twice,
    since the detector's onsets are a few milliseconds loose. Similarity
    is the cosine between each aligned kick and the average: 1 when it is
    the same recording, lower as the hits differ.
    """
    mono = drums.mean(axis=1).astype(np.float64) if drums.ndim == 2 else drums
    band = sosfiltfilt(butter(4, BAND_HZ, btype="band", fs=rate, output="sos"), mono)
    length = int(WINDOW_S * rate)
    shift = int(MAX_SHIFT_S * rate)
    usable = kicks[(kicks > shift) & (kicks + length + shift < band.size)]
    if usable.size < 8:
        return None
    if usable.size > SAMPLE:
        usable = usable[np.linspace(0, usable.size - 1, SAMPLE).astype(int)]

    windows = np.array([band[s:s + length] for s in usable])
    template = np.median(windows, axis=0)
    moves = np.zeros(usable.size, dtype=int)
    for _ in range(2):
        if not np.any(template):
            return None
        windows, moves = _aligned(band, usable, length, shift, template)
        template = windows.mean(axis=0)
    norms = np.linalg.norm(windows, axis=1) * np.linalg.norm(template)
    similarity = np.where(norms > 0, windows @ template / np.maximum(norms, 1e-30), 0.0)
    return template, similarity, usable + moves


def grid_jitter_ms(onsets: np.ndarray, rate: int, bpm: float,
                   step: int = 1, window_beats: int = 8) -> float | None:
    """Median distance, in ms, from each onset to its local grid.

    The grid is the tag's `step` subdivision, placed from the onsets within
    `window_beats` either side (their circular mean), so slow tempo drift
    is followed and only hit-to-hit timing is left.
    """
    if onsets.size < 8 or not bpm or bpm <= 0:
        return None
    period = 60.0 / bpm * rate / step
    phase = (onsets / period) % 1.0
    angle = np.exp(2j * np.pi * phase)
    reach = window_beats * period * step
    offsets = []
    for i, k in enumerate(onsets):
        near = np.abs(onsets - k) <= reach
        centre = np.angle(angle[near].mean()) / (2 * np.pi)
        offset = (phase[i] - centre + 0.5) % 1.0 - 0.5
        offsets.append(abs(offset) * period / rate * 1000)
    return float(np.median(offsets))


# "Does this hit sound like the kick?" -- asked of every hit, machine or
# drummer. On the 1988 and 1990 reports the tracks that went wrong were the
# ones whose kept "kicks" did not sound alike (Domino Dancing 0.69, Tell It
# to My Heart 0.75, What Time Is Love 0.47, against 0.97-0.99 on the clean
# ones): percussion, toms and stabs heavy enough to pass the weight filter.
#
# Compared only in the kick's own band, so a snare landing on a kick does
# not make it a different sound. Measured on the synthetic kit, in 30-120
# Hz: a kick again 1.00, with a LinnDrum-style snare on top 1.00, with a
# noise snare 0.96; toms 0.12-0.41 (the lowest, 64 Hz, the highest), a
# scratch 0.26, a clap 0.05, a snare alone 0.19. At 30-250 Hz the kick
# with the thumping snare fell to 0.85.
SOUND_BAND_HZ = (30.0, 120.0)
SOUND_RATE = 2000               # all that band needs, and 24x less to compare
SOUND_WINDOW_S = 0.06           # the kick's body
# How far a hit may be moved to line up: more than half a cycle of the
# lowest kick, 12.5 ms at 40 Hz. At 3 ms, a kick whose onset the detector
# placed 8 ms early -- as a snare or clap on top of it can make it --
# matched its own copy at -0.34, half a cycle out. That split
# four-on-the-floor records into "kicks on 1 and 3" and "kicks on 2 and
# 4" and kept one: Vogue 89 -> 58 kicks a minute, Push It 110 -> 57,
# Pump Up the Volume 98 -> 52 (1988/1990 reports). At 12 ms the non-kicks
# on the synthetic kit match at 0.19-0.50 and a scratch at 0.67.
SOUND_SHIFT_S = 0.012
SOUND_SAMPLE = 200              # hits enough to learn the sound from
# Between the scratch's 0.67 at that shift and the kick under a loud
# snare's 0.91; clean records' kept kicks read 0.93-0.98 at the 10th
# percentile.
MIN_SOUND_MATCH = 0.8


def _sound_windows(drums: np.ndarray, rate: int, hits: np.ndarray,
                   shift: int) -> tuple[np.ndarray, np.ndarray]:
    """Per hit, the kick-band window at each shift -- (hits, shifts, length),
    unit-normalised -- and which hits had room for one."""
    from scipy.signal import resample_poly
    mono = drums.mean(axis=1) if drums.ndim == 2 else drums
    band = sosfiltfilt(butter(4, SOUND_BAND_HZ, btype="band", fs=rate,
                              output="sos"), np.asarray(mono, dtype=np.float64))
    low = resample_poly(band, SOUND_RATE, rate)
    at = np.round(hits * SOUND_RATE / rate).astype(int)
    length = int(SOUND_WINDOW_S * SOUND_RATE)
    room = (at - shift >= 0) & (at + shift + length <= low.size)
    offsets = np.arange(-shift, shift + 1)
    idx = at[room, None, None] + offsets[None, :, None] + np.arange(length)[None, None, :]
    windows = low[idx]
    norms = np.linalg.norm(windows, axis=2, keepdims=True)
    return windows / np.maximum(norms, 1e-30), room


def sounds_like_the_kick(drums: np.ndarray, rate: int, hits: np.ndarray,
                         shifts: bool = False):
    """(keep, match): which hits sound like the track's kick, and how much.

    The kick's sound is learned from the hits themselves: the one that
    sounds like the most others (a match of MIN_SOUND_MATCH or better) is
    taken as the kick, those that sound like it are averaged into a
    template, and every hit is scored against that. So the kick is the
    most common sound among the hits heavy enough to be one -- it need not
    be the heaviest. A first version took it from the heaviest half, and a
    low tom that rang longer than the kick, half as often, became the
    template; that is `test_a_tom_as_heavy_as_the_kick_is_not_the_kick`.
    Nor need it be most of the hits, only the largest group of alike ones.

    Fewer than 8 hits, or none with room either side: everything is kept,
    as there is nothing to learn a sound from.

    With `shifts`, a third array: how far (ms) each hit was moved to line
    up best. A hit at the limit (SOUND_SHIFT_S) may have wanted further.
    """
    keep = np.ones(hits.size, dtype=bool)
    match = np.ones(hits.size)
    moved = np.zeros(hits.size)
    done = (lambda: (keep, match, moved)) if shifts else (lambda: (keep, match))
    if hits.size < 8:
        return done()
    shift = int(round(SOUND_SHIFT_S * SOUND_RATE))
    windows, room = _sound_windows(drums, rate, hits, shift)
    if windows.shape[0] < 8:
        return done()
    centred = windows[:, shift]
    sample = np.arange(windows.shape[0])
    if sample.size > SOUND_SAMPLE:
        sample = sample[np.linspace(0, sample.size - 1, SOUND_SAMPLE).astype(int)]
    # Pairwise, over the shifts: how much each sampled hit sounds like each.
    pair = np.einsum("isl,jl->ijs", windows[sample], centred[sample]).max(axis=2)
    alike = pair >= MIN_SOUND_MATCH
    kick = int(np.argmax(alike.sum(axis=0)))
    like = sample[alike[:, kick]]
    # Line each up to that hit before averaging, or the template blurs.
    best = np.argmax(windows[like] @ centred[sample[kick]], axis=1)
    template = windows[like, best].mean(axis=0)
    unit = template / max(float(np.linalg.norm(template)), 1e-30)
    every = windows @ unit
    scored = every.max(axis=1)
    match[room] = scored
    moved[room] = (np.argmax(every, axis=1) - shift) * 1000.0 / SOUND_RATE
    keep[room] = scored >= MIN_SOUND_MATCH
    return done()
