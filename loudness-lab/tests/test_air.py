"""The exciter: the one stage here that invents rather than restores.

Held to a higher standard than the others precisely because of that. A
restoration can be judged against the measurement that motivated it; this
one cannot, so what it can be judged on is that it does what it says --
the amount is the amount, the content is genuinely new, and the artefacts
a naive implementation would produce are not there.
"""

from __future__ import annotations

import unittest

import numpy as np
from scipy.signal import butter, resample_poly, sosfiltfilt

from loudnesslab import air

from tests.test_subbass import RATE, programme


def band_db(x: np.ndarray, low: float, high: float) -> float:
    sos = butter(4, [low, min(high, RATE * 0.49)], btype="band",
                 fs=RATE, output="sos")
    filtered = sosfiltfilt(sos, x, axis=0)
    return float(10 * np.log10(np.mean(filtered * filtered) + 1e-30))


def codec_cut(x: np.ndarray, at: float = 16000.0) -> np.ndarray:
    """A low-bitrate encode: everything above `at` simply gone.

    The case the stage exists for, and the one the library actually
    contains -- `Disco Music` measures a 27 dB cliff across 16k to 20k.
    """
    return sosfiltfilt(butter(8, at, btype="low", fs=RATE, output="sos"),
                       x, axis=0).astype(np.float32)


class TestTheAmountIsTheAmount(unittest.TestCase):
    """A mix control that means "some" is how an exciter ends up used at
    three times the depth intended. This one is normalised to a measured
    band, so the number on it is the number that happens."""

    @classmethod
    def setUpClass(cls):
        x, _ = programme(seconds=8.0)
        cls.cut = codec_cut(x)
        cls.full = x.astype(np.float32)

    def test_the_band_rises_by_what_was_asked_for(self):
        for amount in (0.5, 1.0, 3.0, 6.0):
            with self.subTest(amount=amount):
                y, report = air.excite(self.cut, RATE, amount_db=amount)
                self.assertTrue(report["applied"])
                measured = band_db(y, air.BAND_LOW_HZ, air.BAND_HIGH_HZ) \
                    - band_db(self.cut, air.BAND_LOW_HZ, air.BAND_HIGH_HZ)
                self.assertAlmostEqual(measured, amount, delta=0.05)
                self.assertAlmostEqual(report["measured_db"], amount, delta=0.05)

    def test_the_cross_term_is_solved_and_not_assumed_away(self):
        """Dry and wet are correlated, so the addition is not incoherent.

        The second harmonic of 4-8 kHz material lands at 8-16 kHz, where
        the source already is. How much that matters depends on the drive:
        at the default it is a 0.07 dB error, at drive 3 it is 0.55 dB.
        Tested on the outcome rather than on the correlation, because the
        correlation is only a reason and the accuracy is the promise.
        """
        for drive in (air.DRIVE, 3.0):
            with self.subTest(drive=drive):
                y, report = air.excite(self.cut, RATE, amount_db=3.0,
                                       drive=drive)
                self.assertAlmostEqual(report["measured_db"], 3.0, delta=0.02)

                # What assuming incoherence would have delivered instead.
                dry = air._band(self.cut, RATE, air.BAND_LOW_HZ, air.BAND_HIGH_HZ)
                wet = air._band(y - self.cut, RATE, air.BAND_LOW_HZ,
                                air.BAND_HIGH_HZ)
                before = float(np.mean(dry * dry))
                added = float(np.mean(wet * wet))
                cross = float(np.mean(dry * wet))
                naive = np.sqrt(before * (10 ** 0.3 - 1) / added)
                got = before + 2 * naive * cross + naive * naive * added
                if drive == 3.0:
                    # Visibly wrong here, which is what the solve is for.
                    self.assertLess(10 * np.log10(got / before), 2.7)

    def test_it_works_on_a_track_that_was_not_cut_at_all(self):
        y, report = air.excite(self.full, RATE, amount_db=2.0)
        self.assertAlmostEqual(report["measured_db"], 2.0, delta=0.05)
        self.assertIsNot(y, self.full)


class TestItGeneratesRatherThanBoosts(unittest.TestCase):
    """The whole argument for the stage. A shelf multiplies what is in the
    band; where a codec emptied it, that is noise and nothing else."""

    def test_content_appears_where_the_source_had_none(self):
        x, _ = programme(seconds=8.0)
        cut = codec_cut(x)
        before = band_db(cut, 16000.0, 22000.0)
        y, _ = air.excite(cut, RATE, amount_db=3.0)
        after = band_db(y, 16000.0, 22000.0)
        self.assertGreater(after - before, 10.0)

    def test_a_high_shelf_cannot_do_the_same(self):
        """Measured side by side, because this is the claim the stage rests
        on and it should not be taken on trust."""
        x, _ = programme(seconds=8.0)
        cut = codec_cut(x)
        before = band_db(cut, 16000.0, 22000.0)
        sos = butter(2, 8000.0, btype="high", fs=RATE, output="sos")
        shelved = (cut + sosfiltfilt(sos, cut, axis=0)
                   * (10 ** (3 / 20) - 1)).astype(np.float32)
        excited, _ = air.excite(cut, RATE, amount_db=3.0)
        self.assertLess(band_db(shelved, 16000.0, 22000.0) - before, 4.0)
        self.assertGreater(band_db(excited, 16000.0, 22000.0) - before, 10.0)

    def test_the_new_content_is_harmonically_related_to_the_source(self):
        """Not noise. A 7 kHz tone should come back with energy at 14 kHz
        and 21 kHz, which is what makes it read as detail rather than
        hiss."""
        t = np.arange(int(RATE * 2)) / RATE
        tone = np.column_stack([0.4 * np.sin(2 * np.pi * 7000 * t)] * 2
                               ).astype(np.float32)
        y, _ = air.excite(tone, RATE, amount_db=6.0, tune_hz=3500.0)
        added = y - tone
        spectrum = np.abs(np.fft.rfft(added[:, 0] * np.hanning(added.shape[0])))
        hz = np.fft.rfftfreq(added.shape[0], 1 / RATE)

        def at(freq):
            i = int(np.argmin(np.abs(hz - freq)))
            return float(spectrum[max(0, i - 12):i + 12].max())

        peak = float(spectrum.max())
        self.assertGreater(at(14000.0) / peak, 0.1)      # second harmonic
        self.assertGreater(at(21000.0) / peak, 0.01)     # third


class TestAliasing(unittest.TestCase):
    """The engineering problem the stage actually has.

    A non-linearity makes harmonics without end, and every one above
    Nyquist folds back down as an inharmonic product -- grit, landing in
    exactly the region being polished. This is what the 4x oversampling is
    for and it is expensive enough to be worth proving.
    """

    def _folded(self, y: np.ndarray, f0: float) -> float:
        spectrum = np.abs(np.fft.rfft(y[:, 0] * np.hanning(y.shape[0])))
        hz = np.fft.rfftfreq(y.shape[0], 1 / RATE)
        spectrum = spectrum / spectrum.max()

        def at(freq):
            i = int(np.argmin(np.abs(hz - freq)))
            return float(spectrum[max(0, i - 12):i + 12].max())

        # 5th harmonic of 7 kHz is 35 kHz, which folds to 13 kHz -- not a
        # multiple of anything in the signal.
        return 20 * np.log10(at(RATE - 5 * f0) + 1e-12)

    def test_the_folded_products_are_sixty_dB_down_on_not_oversampling(self):
        f0 = 7000.0
        t = np.arange(int(RATE * 2)) / RATE
        tone = 0.5 * np.sin(2 * np.pi * f0 * t)
        stereo = np.column_stack([tone, tone]).astype(np.float32)

        def shaped(signal):
            return np.tanh(air.DRIVE * signal + air.BIAS) - np.tanh(air.BIAS)

        naive = np.column_stack([shaped(tone)] * 2)
        good = np.column_stack(
            [resample_poly(shaped(resample_poly(tone, air.OVERSAMPLE, 1)),
                           1, air.OVERSAMPLE)] * 2)
        self.assertLess(self._folded(good, f0), self._folded(naive, f0) - 40.0)
        # And what the stage itself produces is at the good end.
        excited, _ = air.excite(stereo, RATE, amount_db=6.0)
        self.assertLess(self._folded(excited - stereo, f0), -60.0)


class TestRefusals(unittest.TestCase):

    def test_asking_for_nothing_does_nothing(self):
        x, _ = programme(seconds=4.0)
        y, report = air.excite(x.astype(np.float32), RATE, amount_db=0.0)
        self.assertFalse(report["applied"])
        np.testing.assert_array_equal(y, x.astype(np.float32))

    def test_a_track_with_nothing_up_there_is_declined(self):
        """There is no exciting a band with no source material below it --
        what the stage would be generating from is the noise floor."""
        t = np.arange(int(RATE * 4)) / RATE
        bass = np.column_stack([0.5 * np.sin(2 * np.pi * 60 * t)] * 2
                               ).astype(np.float32)
        y, report = air.excite(bass, RATE, amount_db=3.0)
        self.assertFalse(report["applied"])
        self.assertIn("harmonics from", report["note"])
        np.testing.assert_array_equal(y, bass)

    def test_silence_stays_silent(self):
        quiet = np.zeros((RATE, 2), dtype=np.float32)
        y, report = air.excite(quiet, RATE, amount_db=6.0)
        self.assertFalse(report["applied"])
        np.testing.assert_array_equal(y, quiet)


class TestWhatItCosts(unittest.TestCase):
    """Reported rather than hidden, because both of these decide whether a
    setting is usable."""

    def test_loudness_barely_moves(self):
        """The famous property of an exciter: the perceived change is out
        of all proportion to the energy added."""
        x, _ = programme(seconds=8.0)
        _, report = air.excite(codec_cut(x), RATE, amount_db=3.0)
        self.assertLess(abs(report["lufs_change_db"]), 0.2)

    def test_the_peak_cost_is_reported(self):
        """It is not small. Harmonics are generated from the source, so
        they land on its peaks, and the file goes above full scale -- the
        levelling that ends the chain is what takes it back out."""
        x, _ = programme(seconds=8.0)
        _, report = air.excite(codec_cut(x), RATE, amount_db=3.0)
        self.assertGreater(report["peak_change_db"], 1.0)

    def test_nothing_below_the_tune_frequency_is_touched(self):
        """The harmonic path is high-passed twice. An asymmetric curve
        rectifies, so it makes DC and difference tones BELOW the tune
        frequency, and those are the ones that sound like distortion."""
        x, _ = programme(seconds=8.0)
        cut = codec_cut(x)
        y, _ = air.excite(cut, RATE, amount_db=6.0, tune_hz=3500.0)
        for low, high in ((31.5, 200.0), (200.0, 1000.0), (1000.0, 2500.0)):
            with self.subTest(band=(low, high)):
                self.assertAlmostEqual(band_db(y, low, high),
                                       band_db(cut, low, high), delta=0.15)

    def test_the_stage_adds_no_DC_of_its_own(self):
        """An asymmetric curve rectifies, so the shaped signal carries a
        large DC offset before the high-pass takes it out.

        Measured on what the stage ADDED, not on the output: the fixture
        has its own offset of 1.6e-03, and an earlier version of this test
        measured that instead and failed the stage for it.
        """
        x, _ = programme(seconds=8.0)
        cut = codec_cut(x)
        y, _ = air.excite(cut, RATE, amount_db=6.0)
        self.assertLess(abs(float(np.mean(y - cut))), 1e-6)


if __name__ == "__main__":
    unittest.main()
