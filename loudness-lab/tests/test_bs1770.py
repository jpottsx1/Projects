"""Loudness engine tests, including a cross-check against ffmpeg's ebur128.

The cross-check is the important one: it is what licenses using this module
as the reference the Swift port gets validated against.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from loudnesslab import bs1770  # noqa: E402

RATE = 48000
HAVE_FFMPEG = shutil.which("ffmpeg") is not None


def write_wav(path: Path, x: np.ndarray) -> None:
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(4)
        handle.setframerate(RATE)
        scaled = np.clip(x.astype(np.float64), -1, 1) * 2147483000.0
        handle.writeframes(scaled.astype("<i4").tobytes())


def ffmpeg_ebur128(path: Path) -> dict:
    out = subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "info", "-i", str(path),
         "-af", "ebur128=peak=true", "-f", "null", "-"],
        capture_output=True, text=True,
    ).stderr
    summary = out[out.rfind("Summary:"):]

    def grab(label: str) -> float | None:
        match = re.search(rf"\b{label}:\s*(-?\d+\.?\d*)", summary)
        return float(match.group(1)) if match else None

    return {"lufs_i": grab("I"), "lra": grab("LRA"), "true_peak": grab("Peak")}


def stereo(signal: np.ndarray) -> np.ndarray:
    return np.stack([signal, signal], axis=1).astype(np.float32)


def sine(freq: float, seconds: float, amplitude: float) -> np.ndarray:
    t = np.arange(int(seconds * RATE)) / RATE
    return amplitude * np.sin(2 * np.pi * freq * t)


class TestInvariants(unittest.TestCase):
    def test_gain_shifts_loudness_by_the_same_amount(self):
        base = stereo(sine(1000, 10, 0.2))
        quiet = bs1770.measure(base)["lufs_i"]
        loud = bs1770.measure(base * (10 ** (6 / 20)))["lufs_i"]
        self.assertAlmostEqual(loud - quiet, 6.0, places=2)

    def test_trailing_silence_is_gated_out(self):
        """Doubling a track's length with silence must not halve its loudness.

        Gating cannot make the two results identical: the blocks straddling
        the boundary are part tone, part silence, so they sit a few dB down
        and still pass the -10 LU relative gate. That residue is under
        0.1 dB, against the ~3 dB an ungated mean would lose.
        """
        music = stereo(sine(1000, 10, 0.2))
        padded = np.concatenate([music, np.zeros((RATE * 10, 2), np.float32)])
        clean = bs1770.measure(music)["lufs_i"]
        with_silence = bs1770.measure(padded)["lufs_i"]
        self.assertAlmostEqual(clean, with_silence, delta=0.1)
        self.assertGreater(with_silence, clean - 0.5)

    def test_true_peak_is_at_least_sample_peak(self):
        result = bs1770.measure(stereo(sine(997, 5, 0.9)))
        self.assertGreaterEqual(result["true_peak_dbtp"],
                                result["sample_peak_dbfs"] - 0.01)

    def test_intersample_peak_exceeds_sample_peak(self):
        # A tone near Nyquist/4 with a phase offset overshoots between samples.
        t = np.arange(RATE) / RATE
        signal = 0.99 * np.sin(2 * np.pi * 11025 * t + np.pi / 4)
        result = bs1770.measure(stereo(signal))
        self.assertGreater(result["true_peak_dbtp"], result["sample_peak_dbfs"])

    def test_percentiles_are_ordered(self):
        loud = stereo(sine(1000, 8, 0.5))
        quiet = stereo(sine(1000, 8, 0.1))
        result = bs1770.measure(np.concatenate([quiet, loud]))
        self.assertLessEqual(result["s_p10"], result["s_p50"])
        self.assertLessEqual(result["s_p50"], result["s_p95"])
        self.assertLessEqual(result["s_p95"], result["s_max"])

    def test_clipping_runs_are_detected(self):
        signal = sine(100, 2, 1.6)  # overdriven, so it flat-tops when clipped
        clipped, runs = bs1770.count_clipping(stereo(np.clip(signal, -1, 1)))
        self.assertGreater(clipped, 0)
        self.assertGreater(runs, 0)

    def test_clean_signal_has_no_clipping(self):
        clipped, runs = bs1770.count_clipping(stereo(sine(100, 2, 0.5)))
        self.assertEqual((clipped, runs), (0, 0))

    def test_silence_yields_nulls_not_infinities(self):
        result = bs1770.measure(np.zeros((RATE * 5, 2), np.float32))
        self.assertIsNone(result["lufs_i"])
        self.assertIsNone(result["sample_peak_dbfs"])

    def test_non_48k_is_rejected(self):
        with self.assertRaises(ValueError):
            bs1770.k_weight(np.zeros((100, 2)), 44100)


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg not installed")
class TestAgainstFfmpeg(unittest.TestCase):
    """ffmpeg prints to 0.1 dB, so 0.15 dB is the tightest honest tolerance."""

    TOLERANCE = 0.15

    def _compare(self, signal: np.ndarray) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "case.wav"
            write_wav(path, signal)
            reference = ffmpeg_ebur128(path)
            ours = bs1770.measure(signal)
        self.assertIsNotNone(reference["lufs_i"], "could not parse ffmpeg output")
        self.assertAlmostEqual(ours["lufs_i"], reference["lufs_i"],
                               delta=self.TOLERANCE, msg="integrated loudness")
        self.assertAlmostEqual(ours["true_peak_dbtp"], reference["true_peak"],
                               delta=0.5, msg="true peak")
        if reference["lra"] is not None and ours["lra"] is not None:
            self.assertAlmostEqual(ours["lra"], reference["lra"],
                                   delta=0.5, msg="loudness range")

    def test_sine(self):
        self._compare(stereo(sine(1000, 15, 0.25)))

    def test_pink_noise(self):
        rng = np.random.default_rng(0)
        white = rng.standard_normal(RATE * 15)
        spectrum = np.fft.rfft(white)
        freqs = np.maximum(np.fft.rfftfreq(white.size, 1 / RATE), 1.0)
        pink = np.fft.irfft(spectrum / np.sqrt(freqs), n=white.size)
        self._compare(stereo(pink / np.abs(pink).max() * 0.5))

    def test_two_level_programme(self):
        quiet = sine(220, 8, 0.05)
        loud = sine(220, 8, 0.5)
        self._compare(stereo(np.concatenate([quiet, loud])))

    def test_uncorrelated_channels(self):
        rng = np.random.default_rng(7)
        left = rng.standard_normal(RATE * 10) * 0.1
        right = rng.standard_normal(RATE * 10) * 0.3
        self._compare(np.stack([left, right], axis=1).astype(np.float32))


if __name__ == "__main__":
    unittest.main()
