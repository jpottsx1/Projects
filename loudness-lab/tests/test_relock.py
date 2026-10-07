"""Bar lines that lose the kicks and find them again.

The lines are followed bar by bar; a stretch with no kicks that ends with the
groove back off the grid by more than a tenth of a beat used to leave every
line after it off the kicks for good."""

from __future__ import annotations

import unittest

import numpy as np

from tests.test_intro import BAR, BPM, RATE, song
from loudnesslab import intro


def lost_lock_song(late_s: float, bars_a: int = 24, gap_bars: int = 4, bars_b: int = 28):
    """A kickless gap, and the groove comes back `late_s` seconds off the grid."""
    xa, pa, _ = song(bars=bars_a, breakdown=range(0, 0), vocal_bars=(range(0, 0),))
    xb, pb, _ = song(bars=bars_b, breakdown=range(0, 0), vocal_bars=(range(0, 0),))
    a_len = int(bars_a * BAR * RATE)
    gap = np.zeros((int((gap_bars * BAR + late_s) * RATE), 2), np.float32)

    def cat(ya, yb):
        return np.concatenate([ya[:a_len], gap, yb])
    return cat(xa, xb), {k: cat(pa[k], pb[k]) for k in pa}


def offset_ms(a, i: int) -> float:
    """Bar line i minus the nearest kick, in ms."""
    line = int(a.bar_lines[i])
    k = a.kicks[np.argmin(np.abs(a.kicks - line))]
    return (line - int(k)) / RATE * 1000


class TestBarLinesRelock(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.a = intro.analyse(*lost_lock_song(0.20), RATE, BPM)
        # the last line with a kick still to come; the song ends in a silent tail
        cls.end = int(np.nonzero(cls.a.bar_lines <= cls.a.kicks[-1])[0][-1])

    def test_the_track_has_a_kickless_gap_to_cross(self):
        self.assertEqual(self.a.kicks[np.abs(self.a.kicks - self.a.bar_lines[25]) < 2 * RATE].size, 0)

    def test_the_last_bar_line_is_on_a_kick(self):
        self.assertLess(abs(offset_ms(self.a, self.end)), 40)

    def test_every_line_after_the_gap_is_on_a_kick(self):
        for i in range(28, self.end + 1):
            self.assertLess(abs(offset_ms(self.a, i)), 40, f"bar {i}")

    def test_snapped_only_where_a_kick_is(self):
        for i in range(self.end + 1):
            if self.a.snapped[i]:
                self.assertLess(abs(offset_ms(self.a, i)), 40, f"bar {i}")

    def test_the_gap_itself_carries_on_unsnapped(self):
        self.assertFalse(self.a.snapped[25:28].any())


class TestWhichKickIsBeatOne(unittest.TestCase):
    period = BAR * RATE / 4
    comb = 1000.0 + period * np.arange(8)

    def test_a_kick_with_no_groove_around_it_is_not_taken(self):
        self.assertIsNone(intro.relock(1000.0 + 0.3 * self.period, np.array([1000.0]), self.period))

    def test_the_kick_within_half_a_beat_on_the_groove_is_taken(self):
        self.assertEqual(intro.relock(1000.0 - 0.3 * self.period, self.comb, self.period), 1000.0)
        self.assertEqual(intro.relock(self.comb[3] + 0.4 * self.period, self.comb, self.period), self.comb[3])

    def test_nothing_within_half_a_beat_means_no_answer(self):
        self.assertIsNone(intro.relock(self.comb[-1] + 3 * self.period, self.comb, self.period))


class TestLockedTracksUnchanged(unittest.TestCase):
    def test_a_locked_track_keeps_its_lines(self):
        x, p, _ = song()
        a = intro.analyse(x, p, RATE, BPM)
        for i in range(len(a.bar_lines)):
            if a.snapped[i]:
                self.assertLess(abs(offset_ms(a, i)), 40)


if __name__ == "__main__":
    unittest.main()
