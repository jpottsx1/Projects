"""Sub-bass prototype tests.

Kick detection is checked against synthetic tracks with known kick times,
because "it found some onsets" is not a result. The fixture deliberately
includes a bassline changing note on every beat -- the thing a plain
rising-edge detector mistook for a kick -- and a passage with no kick at all.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from scipy.signal import butter, sosfilt

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from loudnesslab import subbass  # noqa: E402

RATE = 48000
HAVE_FFMPEG = shutil.which("ffmpeg") is not None


def programme(seconds: float = 24.0, bpm: float = 120.0, seed: int = 0,
              breakdown: bool = True) -> tuple[np.ndarray, np.ndarray]:
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    beat = 60.0 / bpm
    rng = np.random.default_rng(seed)

    truth, kick = [], np.zeros(n)
    click = rng.standard_normal(n)
    for onset in np.arange(0, seconds, beat):
        if breakdown and 10.0 <= onset < 13.0:
            continue
        truth.append(onset)
        i = int(onset * RATE)
        m = min(int(0.3 * RATE), n - i)
        d = np.arange(m) / RATE
        freq = 45 + 45 * np.exp(-d * 60)      # a kick's pitch drops
        kick[i:i + m] += (np.sin(2 * np.pi * np.cumsum(freq) / RATE)
                          * np.exp(-d * 22) + click[i:i + m] * np.exp(-d * 420) * 0.35)

    note = np.array([80.0, 90.0, 71.0, 107.0])[np.floor(t / beat).astype(int) % 4]
    bass = 0.55 * np.sin(2 * np.pi * np.cumsum(note) / RATE)
    mids = sosfilt(butter(4, [300, 4000], btype="band", fs=RATE, output="sos"),
                   rng.standard_normal(n)) * 0.25
    mix = 0.9 * kick + bass + mids + 0.03 * rng.standard_normal(n)
    mix = mix / np.abs(mix).max() * 0.8
    return np.stack([mix, mix], axis=1).astype(np.float32), np.array(truth)


def score(detected, truth, tol: float = 0.03) -> tuple[float, float]:
    found = np.asarray(detected) / RATE
    if found.size == 0 or truth.size == 0:
        return 0.0, 0.0
    hits = sum(1 for x in truth if np.any(np.abs(found - x) <= tol))
    matched = sum(1 for x in found if np.any(np.abs(truth - x) <= tol))
    return hits / truth.size, matched / found.size


class TestKickDetection(unittest.TestCase):
    def test_finds_kicks_across_tempos(self):
        for bpm in (96, 120, 128, 140, 174):
            with self.subTest(bpm=bpm):
                x, truth = programme(bpm=bpm)
                kicks, _ = subbass.detect_kicks(x, RATE)
                recall, precision = score(kicks, truth)
                self.assertGreater(recall, 0.85, f"recall at {bpm} BPM")
                self.assertGreater(precision, 0.80, f"precision at {bpm} BPM")

    def test_onsets_are_not_systematically_late(self):
        """A burst 25 ms behind the kick flams against a 22 ms cycle at 45 Hz.
        Causal envelope filtering did exactly that until it was made
        zero-phase and the onsets backtracked to the attack."""
        x, truth = programme()
        kicks, _ = subbass.detect_kicks(x, RATE)
        found = kicks / RATE
        offsets = [found[np.argmin(np.abs(found - t))] - t for t in truth]
        self.assertLess(abs(float(np.median(offsets))), 0.015)

    def test_a_sustained_tone_is_not_a_kick(self):
        t = np.arange(int(15 * RATE)) / RATE
        rng = np.random.default_rng(2)
        pad = 0.3 * np.sin(2 * np.pi * 110 * t) + 0.05 * rng.standard_normal(t.size)
        x = np.stack([pad, pad], axis=1).astype(np.float32)
        kicks, _ = subbass.detect_kicks(x, RATE)
        self.assertLess(kicks.size, 4)

    def test_silence_detects_nothing(self):
        kicks, _ = subbass.detect_kicks(np.zeros((RATE * 3, 2), np.float32), RATE)
        self.assertEqual(kicks.size, 0)

    def test_strengths_are_normalised(self):
        x, _ = programme()
        _, strengths = subbass.detect_kicks(x, RATE)
        self.assertTrue(np.all(strengths > 0))
        self.assertAlmostEqual(float(strengths.max()), 1.0, places=6)


class TestEnhancement(unittest.TestCase):
    def test_delivers_the_requested_band_increase(self):
        """The burst is phase-aligned with the kick, so an incoherent power
        estimate misses; the gain is the root of a quadratic."""
        x, _ = programme()
        for amount in (2.0, 3.0, 5.0, 8.0):
            with self.subTest(amount=amount):
                _, report = subbass.enhance(x * 0.4, RATE, amount_db=amount)
                self.assertAlmostEqual(report["applied_db"], amount, places=2)

    def test_the_energy_lands_in_the_target_octave(self):
        x, _ = programme()
        quiet = x * 0.4
        out, _ = subbass.enhance(quiet, RATE, amount_db=6.0)
        in_band = subbass._band_power(out, RATE, subbass.SUB_LOW_HZ,
                                      subbass.SUB_HIGH_HZ)
        before = subbass._band_power(quiet, RATE, subbass.SUB_LOW_HZ,
                                     subbass.SUB_HIGH_HZ)
        self.assertGreater(in_band / before, 3.0)
        # ...and not in the low mids, which is where mud would come from.
        mids_after = subbass._band_power(out, RATE, 160.0, 400.0)
        mids_before = subbass._band_power(quiet, RATE, 160.0, 400.0)
        self.assertLess(abs(10 * np.log10(mids_after / mids_before)), 0.3)

    def test_nothing_below_the_reproducible_floor(self):
        """Energy under ~28 Hz reaches no dancefloor and only eats headroom."""
        x, _ = programme()
        quiet = x * 0.4
        out, _ = subbass.enhance(quiet, RATE, amount_db=6.0)
        deep_after = subbass._band_power(out, RATE, 10.0, 22.0)
        deep_before = subbass._band_power(quiet, RATE, 10.0, 22.0)
        self.assertLess(10 * np.log10(deep_after / max(deep_before, 1e-20)), 1.0)

    def test_material_without_kicks_is_returned_untouched(self):
        t = np.arange(int(12 * RATE)) / RATE
        pad = (0.3 * np.sin(2 * np.pi * 110 * t)).astype(np.float32)
        x = np.stack([pad, pad], axis=1)
        out, report = subbass.enhance(x, RATE, amount_db=5.0)
        self.assertIsNotNone(report["note"])
        self.assertIs(out, x)

    def test_output_never_clips(self):
        x, _ = programme()
        out, report = subbass.enhance(x, RATE, amount_db=9.0)
        self.assertLessEqual(float(np.abs(out).max()), 1.0)
        self.assertLess(report["safety_trim_db"], 0.0)

    def test_asking_for_nothing_changes_nothing(self):
        x, _ = programme()
        out, report = subbass.enhance(x, RATE, amount_db=0.0)
        self.assertAlmostEqual(report["applied_db"], 0.0, places=3)


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg not installed")
class TestComparisonPairs(unittest.TestCase):
    """An unmatched A/B mostly measures which file is louder, and louder wins
    regardless of whether it is better. The pair must be loudness-matched."""

    def test_pair_is_loudness_matched_and_differs_only_in_the_low_end(self):
        from loudnesslab import bs1770, cli, decode, spectrum
        x, _ = programme(seconds=8.0)
        with tempfile.TemporaryDirectory() as tmp:
            root, out = Path(tmp) / "src", Path(tmp) / "out"
            root.mkdir()
            wav = root / "track.wav"
            subbass.write_flac(root / "track.flac", x, RATE)
            code = cli.main(["subbass", str(root), "--db", str(Path(tmp) / "s.db"),
                             "--out", str(out), "--amount", "3", "--limit", "1",
                             "--jobs", "1", "--quiet"])
            self.assertEqual(code, 0)
            a = next(out.glob("*A original.flac"))
            b = next(out.glob("*B sub*.flac"))
            xa, xb = decode.decode(a), decode.decode(b)

        self.assertAlmostEqual(bs1770.measure(xa)["lufs_i"],
                               bs1770.measure(xb)["lufs_i"], places=1)
        low = [31.5, 40.0, 50.0, 63.0]
        sa = {r["band_hz"]: r["shape_db"] for r in spectrum.analyse(xa, RATE)}
        sb = {r["band_hz"]: r["shape_db"] for r in spectrum.analyse(xb, RATE)}
        lifted = sum(sb[k] for k in low) / 4 - sum(sa[k] for k in low) / 4
        self.assertGreater(lifted, 1.5)
        # Everything above the sub octave must be left alone.
        for band in (250.0, 1000.0, 4000.0):
            self.assertAlmostEqual(sa[band], sb[band], delta=0.4, msg=f"{band} Hz")


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg not installed")
class TestFlacOutput(unittest.TestCase):
    def test_writes_a_readable_flac(self):
        x, _ = programme(seconds=4.0)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "out.flac"
            subbass.write_flac(path, x, RATE)
            self.assertTrue(path.exists())
            probe = subprocess.run(
                ["ffprobe", "-v", "error", "-show_entries",
                 "stream=codec_name,channels,sample_rate",
                 "-of", "csv=p=0", str(path)],
                capture_output=True, text=True)
        self.assertIn("flac", probe.stdout)
        self.assertIn("48000", probe.stdout)


if __name__ == "__main__":
    unittest.main()
