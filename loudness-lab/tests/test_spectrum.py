"""Spectrum tests: band layout, known spectra, and the low-end diagnostics."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import numpy as np
from scipy.signal import butter, sosfilt, sosfiltfilt

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from loudnesslab import spectrum  # noqa: E402

RATE = 48000
SECONDS = 12


def by_band(rows: list[dict]) -> dict:
    return {row["band_hz"]: row for row in rows}


def pink(n: int, seed: int = 0) -> np.ndarray:
    """Band-limited pink noise, 20 Hz to 20 kHz.

    The band limiting matters: an unbounded 1/f spectrum puts most of its
    energy below the audio band, which would swamp the broadband figure that
    shape_db is measured against.
    """
    rng = np.random.default_rng(seed)
    white = rng.standard_normal(n)
    freqs = np.fft.rfftfreq(n, 1 / RATE)
    weights = np.zeros_like(freqs)
    band = (freqs >= 20.0) & (freqs <= 20000.0)
    weights[band] = 1.0 / np.sqrt(freqs[band])
    out = np.fft.irfft(np.fft.rfft(white) * weights, n=n)
    return out / np.abs(out).max() * 0.5


class TestKnownSpectra(unittest.TestCase):
    def test_pink_noise_is_flat_across_bands(self):
        """Pink noise has equal power per octave, so every 1/3-octave band
        should read the same level. This is the calibration check for the
        band-power normalisation."""
        signal = pink(RATE * SECONDS)
        rows = spectrum.analyse(np.stack([signal, signal], axis=1), RATE)
        levels = [r["ltas_db"] for r in rows if 40 <= r["band_hz"] <= 10000]
        self.assertLess(max(levels) - min(levels), 1.5)

    def test_white_noise_rises_one_db_per_third_octave(self):
        """Each 1/3-octave band is 2^(1/3) times wider than the last, so
        white noise gains about 1 dB per band."""
        rng = np.random.default_rng(1)
        signal = rng.standard_normal(RATE * SECONDS) * 0.1
        rows = spectrum.analyse(np.stack([signal, signal], axis=1), RATE)
        levels = np.array([r["ltas_db"] for r in rows
                           if 100 <= r["band_hz"] <= 10000])
        slope = np.polyfit(np.arange(levels.size), levels, 1)[0]
        self.assertAlmostEqual(slope, 1.0, delta=0.2)

    def test_tone_lands_in_its_own_band(self):
        t = np.arange(RATE * 4) / RATE
        signal = 0.5 * np.sin(2 * np.pi * 1000 * t)
        rows = by_band(spectrum.analyse(np.stack([signal, signal], axis=1), RATE))
        loudest = max(rows.values(), key=lambda r: r["ltas_db"])
        self.assertEqual(loudest["band_hz"], 1000.0)

    def test_shape_is_independent_of_level(self):
        """shape_db must describe the spectrum, not the volume."""
        signal = pink(RATE * SECONDS)
        quiet = np.stack([signal, signal], axis=1) * 0.1
        loud = quiet * 8
        a = by_band(spectrum.analyse(quiet, RATE))
        b = by_band(spectrum.analyse(loud, RATE))
        for band in a:
            if a[band]["shape_db"] is not None and b[band]["shape_db"] is not None:
                self.assertAlmostEqual(a[band]["shape_db"], b[band]["shape_db"],
                                       delta=0.2, msg=f"{band} Hz")


class TestBandConstants(unittest.TestCase):
    def test_report_band_selections_exist_in_the_band_table(self):
        """A hardcoded 32.0 matches nothing: the nominal centre is 31.5."""
        from loudnesslab import report
        for band in report.LOW_SHAPE_BANDS:
            self.assertIn(band, spectrum.BAND_CENTRES, f"{band} Hz")
        self.assertTrue(report.LOW_SHAPE_BANDS)

    def test_low_band_cutoff_selects_real_bands(self):
        low = [b for b in spectrum.BAND_CENTRES
               if b <= spectrum.LOW_BAND_MAX_HZ]
        self.assertEqual(low[-1], 315.0)
        self.assertEqual(len(low), 13)


class TestLowEndDiagnostics(unittest.TestCase):
    def _two_channel_pink(self) -> np.ndarray:
        return np.stack([pink(RATE * SECONDS, 2), pink(RATE * SECONDS, 3)], axis=1)

    def test_mono_bass_is_detected(self):
        """Summing the low end to mono must collapse side energy there while
        leaving the rest of the spectrum wide -- the vinyl-cut signature."""
        wide = self._two_channel_pink()
        # Zero-phase, so `wide - low` is a true complementary high-pass. With
        # a one-pass filter the phase shift leaves a stereo residue in the
        # bass and the mono-ing does not take.
        low = sosfiltfilt(butter(4, 200, btype="low", fs=RATE, output="sos"),
                          wide, axis=0)
        mono_bass = (wide - low) + low.mean(axis=1, keepdims=True)

        before = by_band(spectrum.analyse(wide, RATE))
        after = by_band(spectrum.analyse(mono_bass, RATE))
        self.assertLess(after[80.0]["side_mid_db"], before[80.0]["side_mid_db"] - 15)
        self.assertGreater(after[2000.0]["side_mid_db"],
                           before[2000.0]["side_mid_db"] - 1.0)

    def test_width_is_withheld_where_the_band_is_empty(self):
        """A band with nothing in it holds filter residue, which reads as
        wide. Reporting that would invert the mono-bass signal, so it must
        come back as None instead."""
        signal = self._two_channel_pink()
        filtered = sosfilt(butter(8, 120, btype="high", fs=RATE, output="sos"),
                           signal, axis=0)
        rows = by_band(spectrum.analyse(filtered, RATE))
        self.assertIsNone(rows[20.0]["side_mid_db"])
        self.assertIsNotNone(rows[500.0]["side_mid_db"])

    def test_missing_sub_shows_up_as_reduced_shape(self):
        signal = self._two_channel_pink()
        rolled_off = sosfilt(butter(4, 45, btype="high", fs=RATE, output="sos"),
                             signal, axis=0)
        full = by_band(spectrum.analyse(signal, RATE))
        thin = by_band(spectrum.analyse(rolled_off, RATE))
        self.assertLess(thin[25.0]["shape_db"], full[25.0]["shape_db"] - 10)
        self.assertAlmostEqual(thin[1000.0]["shape_db"], full[1000.0]["shape_db"],
                               delta=1.0)

    def test_steady_tone_modulates_less_than_a_varying_one(self):
        """p90 - p10 is the content-versus-noise discriminator."""
        t = np.arange(RATE * SECONDS) / RATE
        steady = 0.4 * np.sin(2 * np.pi * 80 * t)
        varying = steady * (0.5 + 0.5 * np.sign(np.sin(2 * np.pi * 0.5 * t)))
        a = by_band(spectrum.analyse(np.stack([steady] * 2, axis=1), RATE))[80.0]
        b = by_band(spectrum.analyse(np.stack([varying] * 2, axis=1), RATE))[80.0]
        self.assertLess(a["p90_db"] - a["p10_db"], b["p90_db"] - b["p10_db"])

    def test_mono_source_reports_no_width(self):
        signal = pink(RATE * 4)
        rows = spectrum.analyse(np.stack([signal, signal], axis=1), RATE,
                                source_is_mono=True)
        self.assertTrue(all(r["side_mid_db"] is None for r in rows))

    def test_too_short_returns_nothing(self):
        self.assertEqual(spectrum.analyse(np.zeros((1000, 2), np.float32), RATE), [])


if __name__ == "__main__":
    unittest.main()
