"""The body lift (loudnesslab/body.py): 63-160 Hz up by the amount asked,
evenly, nothing from 400 Hz up -- Jeff's 80s batch measured 4-8 dB under
MODERN DANCE in 80-125 Hz after the sub (2026-10-12)."""

from __future__ import annotations

import argparse
import unittest

import numpy as np
from scipy.signal import butter, sosfiltfilt

from loudnesslab import body, cli, report
from tests.test_subbass import RATE, programme


def band_db(x: np.ndarray, low: float, high: float) -> float:
    sos = butter(4, [low, high], btype="band", fs=RATE, output="sos")
    y = sosfiltfilt(sos, np.asarray(x, dtype=np.float64), axis=0)
    return float(10 * np.log10(np.mean(y * y) + 1e-30))


class TestTheLift(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.x, _ = programme(seconds=12.0)

    def test_the_band_goes_up_by_what_was_asked(self):
        for amount in (1.0, 3.0, 6.0):
            with self.subTest(amount=amount):
                y, done = body.boost(self.x, RATE, amount)
                self.assertTrue(done["applied"])
                self.assertAlmostEqual(done["measured_db"], amount, delta=0.05)
                self.assertAlmostEqual(
                    band_db(y, body.LOW_HZ, body.HIGH_HZ)
                    - band_db(self.x, body.LOW_HZ, body.HIGH_HZ), amount, delta=0.05)

    def test_it_is_even_across_the_middle_of_the_band(self):
        """Measured on noise at 6 dB: 80 Hz +6.4, 100 +6.5, 125 +6.4."""
        y, _ = body.boost(self.x, RATE, 6.0)
        lifts = [band_db(y, c / 1.12, c * 1.12) - band_db(self.x, c / 1.12, c * 1.12)
                 for c in (80.0, 100.0, 125.0)]
        self.assertLess(max(lifts) - min(lifts), 1.0)

    def test_nothing_from_400_hz_up_moves(self):
        y, _ = body.boost(self.x, RATE, 6.0)
        for low, high in ((400.0, 1000.0), (1000.0, 4000.0), (6000.0, 16000.0)):
            with self.subTest(band=(low, high)):
                self.assertAlmostEqual(band_db(y, low, high), band_db(self.x, low, high),
                                       delta=0.3)

    def test_it_is_capped(self):
        _, done = body.boost(self.x, RATE, 40.0)
        self.assertEqual(done["amount_db"], body.MAX_BOOST_DB)
        self.assertAlmostEqual(done["measured_db"], body.MAX_BOOST_DB, delta=0.1)

    def test_nothing_asked_nothing_done(self):
        y, done = body.boost(self.x, RATE, 0.0)
        self.assertIs(y, self.x)
        self.assertFalse(done["applied"])

    def test_a_mono_track_is_handled(self):
        mono = self.x[:, 0].copy()
        y, done = body.boost(mono, RATE, 3.0)
        self.assertEqual(y.shape, mono.shape)
        self.assertAlmostEqual(done["measured_db"], 3.0, delta=0.05)


class TestTheSizing(unittest.TestCase):
    """Per track against the reference over 63-160 Hz, a band over it not
    paying off one under, capped at --body."""

    class Rows:
        def __init__(self, shapes):
            self.shapes = shapes
        def execute(self, *_):
            return self
        def fetchall(self):
            return [{"band_hz": b, "shape_db": v} for b, v in self.shapes.items()]

    curve = {b: -10.0 for b in report.BODY_SHAPE_BANDS}

    def size(self, shapes, body_db=6.0, auto=True):
        args = argparse.Namespace(body=body_db, auto=auto)
        return cli._body_for(args, self.Rows(shapes), "t.mp3", self.curve)

    def test_the_bands_are_63_to_160(self):
        self.assertEqual(report.BODY_SHAPE_BANDS, (63.0, 80.0, 100.0, 125.0, 160.0))

    def test_a_thin_track_gets_its_shortfall(self):
        amount, why = self.size({b: -14.0 for b in report.BODY_SHAPE_BANDS})
        self.assertAlmostEqual(amount, 4.0)
        self.assertIsNone(why)

    def test_a_band_over_does_not_pay_off_one_under(self):
        shapes = {63.0: -2.0, 80.0: -15.0, 100.0: -15.0, 125.0: -10.0, 160.0: -10.0}
        amount, _ = self.size(shapes)
        self.assertAlmostEqual(amount, (5.0 + 5.0) / 5)

    def test_capped_at_the_setting(self):
        amount, _ = self.size({b: -30.0 for b in report.BODY_SHAPE_BANDS}, body_db=6.0)
        self.assertEqual(amount, 6.0)

    def test_a_full_track_gets_none_and_says_why(self):
        amount, why = self.size({b: -9.0 for b in report.BODY_SHAPE_BANDS})
        self.assertEqual(amount, 0.0)
        self.assertIn("63-160 Hz", why)

    def test_off_is_off_and_without_auto_it_is_as_set(self):
        self.assertEqual(self.size({}, body_db=0.0), (0.0, None))
        self.assertEqual(self.size({}, body_db=3.0, auto=False), (3.0, None))


if __name__ == "__main__":
    unittest.main()
