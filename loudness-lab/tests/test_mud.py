"""The mud cut (loudnesslab/mud.py): 200-400 Hz out by the amount asked,
deepest where the band builds up, nothing in the sparse passages, nothing
outside the band -- Jeff's early-seventies records measured 3 dB above
his disco reference there (median, 4.8 at most)."""

from __future__ import annotations

import unittest

import numpy as np
from scipy.signal import butter, sosfiltfilt

from loudnesslab import mud
from tests.test_subbass import RATE, programme


def band_db(x: np.ndarray, low: float, high: float) -> float:
    sos = butter(4, [low, high], btype="band", fs=RATE, output="sos")
    y = sosfiltfilt(sos, np.asarray(x, dtype=np.float64), axis=0)
    return float(10 * np.log10(np.mean(y * y) + 1e-30))


def half_muddy(seconds: float = 16.0) -> np.ndarray:
    """Thick in 200-400 Hz for the first half, as mixed in the second."""
    x, _ = programme(seconds=seconds)
    thick = sosfiltfilt(butter(2, [200, 400], btype="band", fs=RATE, output="sos"),
                        x, axis=0)
    y = x.copy()
    y[: x.shape[0] // 2] += 1.5 * thick[: x.shape[0] // 2]
    return y.astype(np.float32)


class TestTheCut(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.x = half_muddy()
        cls.half = cls.x.shape[0] // 2

    def test_the_band_comes_down_by_what_was_asked(self):
        for amount in (1.0, 3.0, 5.0):
            with self.subTest(amount=amount):
                y, report = mud.clear(self.x, RATE, amount)
                self.assertTrue(report["applied"])
                self.assertAlmostEqual(report["measured_db"], -amount, delta=0.05)
                self.assertAlmostEqual(band_db(y, 200, 400) - band_db(self.x, 200, 400),
                                       -amount, delta=0.05)

    def test_it_follows_the_build_up(self):
        """Measured: asked 3, the thick half came down 3.8 and the sparse
        half 0.14 -- a fixed cut would have taken 3 out of both."""
        y, _ = mud.clear(self.x, RATE, 3.0)
        h = self.half
        thick = band_db(y[:h], 200, 400) - band_db(self.x[:h], 200, 400)
        sparse = band_db(y[h:], 200, 400) - band_db(self.x[h:], 200, 400)
        self.assertLess(thick, -3.3)
        self.assertGreater(sparse, -0.5)

    def test_nothing_outside_the_band_moves(self):
        y, _ = mud.clear(self.x, RATE, 5.0)
        for low, high in ((31.5, 120.0), (1000.0, 4000.0), (6000.0, 16000.0)):
            with self.subTest(band=(low, high)):
                self.assertAlmostEqual(band_db(y, low, high), band_db(self.x, low, high),
                                       delta=0.05)

    def test_it_cannot_click(self):
        """The cut moves over 400 ms windows: from one sample to the next
        the output differs from the input's own step by almost nothing."""
        y, _ = mud.clear(self.x, RATE, 5.0)
        jump = np.abs(np.diff(y[:, 0].astype(np.float64) - self.x[:, 0]))
        self.assertLess(float(jump.max()), 0.01)

    def test_a_track_thick_throughout_takes_what_is_asked(self):
        """The first version left each track's own least-built-up 30%
        alone, so a track thick throughout -- a master EQ'd once, most of
        these -- could not lose more than 4.8 dB whatever was asked."""
        x, _ = programme(seconds=8.0)
        thick = sosfiltfilt(butter(2, [200, 400], btype="band", fs=RATE,
                                   output="sos"), x, axis=0)
        muddy = (x + 1.5 * thick).astype(np.float32)
        y, report = mud.clear(muddy, RATE, 8.0)
        self.assertAlmostEqual(report["measured_db"], -8.0, delta=0.1)
        self.assertGreater(report["cutting"], 0.6)

    def test_nothing_asked_nothing_done(self):
        y, report = mud.clear(self.x, RATE, 0.0)
        self.assertIs(y, self.x)
        self.assertFalse(report["applied"])

    def test_a_mono_track_is_handled(self):
        y, report = mud.clear(self.x[:, 0], RATE, 2.0)
        self.assertEqual(y.shape, self.x[:, 0].shape)
        self.assertAlmostEqual(report["measured_db"], -2.0, delta=0.05)


if __name__ == "__main__":
    unittest.main()
