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
