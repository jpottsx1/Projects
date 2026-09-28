"""The level check's verdicts: what a file reading short of the target is
told, since 'short' alone cannot say whether that was on purpose."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import check_levels as c  # noqa: E402


class Verdict(unittest.TestCase):
    def v(self, name="song.mp3", level=-16.0, peak=-3.0):
        return c.verdict(name, level, peak, target=-16.0, ceiling=-1.0)

    def test_at_the_target_is_levelled(self):
        self.assertEqual(self.v(level=-16.2), c.LEVELLED)

    def test_short_with_its_peak_at_the_ceiling_was_held_on_purpose(self):
        self.assertEqual(self.v(level=-17.5, peak=-1.0), c.HELD)

    def test_short_with_room_to_spare_was_not_levelled(self):
        self.assertEqual(self.v(level=-22.0, peak=-8.0), c.NOT)

    def test_louder_than_the_target_is_said(self):
        self.assertEqual(self.v(level=-9.0, peak=0.0), c.LOUD)

    def test_a_pair_is_a_pair_whatever_it_reads(self):
        self.assertEqual(self.v("song -- B sub+5.mp3", level=-16.0), c.PAIR)
        self.assertEqual(self.v("song -- A original.mp3", level=-22.0), c.PAIR)


if __name__ == "__main__":
    unittest.main()
