"""tools/headroom.py: is the peak ceiling holding tracks under the target,
and would rotating the bass's phase give it back? What it measures has to
be right before its answer is worth acting on."""

from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from scipy.signal import sosfreqz

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import headroom  # noqa: E402
from loudnesslab import subbass  # noqa: E402
from tests.test_subbass import RATE, programme  # noqa: E402


def lopsided(seconds: float = 8.0) -> np.ndarray:
    """A bass whose harmonics are in step with its fundamental: a tall
    peak on one side, as a plucked or synth bass has, over a groove."""
    x, _ = programme(seconds=seconds)
    t = np.arange(x.shape[0]) / RATE
    bass = sum(np.sin(2 * np.pi * 55 * k * t) / k for k in range(1, 6))
    return (0.5 * x + 0.25 * np.stack([bass] * 2, 1)).astype(np.float32)


class TestTheRotator(unittest.TestCase):
    def test_it_changes_no_level_at_any_frequency(self):
        for name, corners in headroom.ROTATIONS:
            _, response = sosfreqz(headroom.allpass(corners, RATE), worN=4096, fs=RATE)
            self.assertLess(float(np.max(np.abs(np.abs(response) - 1))), 1e-9, name)

    def test_it_lowers_a_lopsided_peak_and_leaves_the_sound(self):
        from loudnesslab import bs1770
        x = lopsided()
        before = bs1770.measure(x)
        bands = headroom.band_levels(x)
        # What a rotation takes off depends on where the harmonics land,
        # so it differs by strength and by track -- on this clip 0.22,
        # 0.31 and 0.55 dB. The best of them is the claim.
        best = 0.0
        for name, corners in headroom.ROTATIONS:
            turned = headroom.rotate(x, corners)
            after = bs1770.measure(turned)
            best = max(best, before["true_peak_dbtp"] - after["true_peak_dbtp"])
            self.assertAlmostEqual(after["lufs_i"], before["lufs_i"], delta=0.05)
            moved = headroom.band_levels(turned)
            for band, level in bands.items():
                if np.isfinite(level) and level > -90:
                    # 0.10 at most, measured (deep, 63 Hz): the filter is
                    # level-flat exactly (above), but a band measured over
                    # a short clip sees the bass arrive a little later.
                    self.assertAlmostEqual(moved[band], level, delta=0.15,
                                           msg=(name, band))
        self.assertGreater(best, 0.4)

    def test_forwards_and_backwards_it_would_do_nothing(self):
        """Why it runs causally: a zero-phase pass cancels an all-pass."""
        from scipy.signal import sosfiltfilt
        x = lopsided(4.0)
        both = sosfiltfilt(headroom.allpass(headroom.ROTATIONS[1][1], RATE), x, axis=0)
        self.assertLess(float(np.max(np.abs(both[RATE:-RATE] - x[RATE:-RATE]))), 1e-3)


class TestHeldBack(unittest.TestCase):
    def test_the_arithmetic(self):
        # Wants +6 to reach -16; the peak at -4 allows only +3.
        self.assertEqual(headroom.held_back(-22.0, -4.0, -16.0, -1.0), (6.0, 3.0))
        # Room to spare: nothing refused.
        self.assertEqual(headroom.held_back(-22.0, -10.0, -16.0, -1.0), (6.0, 0.0))
        # Too loud already: turned down, never refused.
        self.assertEqual(headroom.held_back(-12.0, 0.0, -16.0, -1.0), (-4.0, 0.0))
        self.assertEqual(headroom.held_back(None, -3.0, -16.0, -1.0), (0.0, 0.0))

    def test_a_comparison_folder_reads_only_the_processed_files(self):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        loud = lopsided(4.0)
        subbass.write_flac(directory / "Song -- A original.flac", loud, RATE)
        subbass.write_flac(directory / "Song -- B eighties.flac", loud, RATE)
        said = []
        rows = headroom.run(directory, workers=1, out=said.append)
        self.assertEqual([r["name"] for r in rows], ["Song -- B eighties.flac"])
        self.assertTrue(any("track(s) held under the target" in line
                            for line in "\n".join(said).splitlines()))

    def test_the_summary_says_when_rotation_would_give_level_back(self):
        rows = [{"name": "a", "wanted": 6.0, "refused": 3.0, "peak": -4.0,
                 "rotations": {n: {"peak_down": 2.0, "loudness_moved": 0.01,
                                   "band_moved": 0.02} for n, _ in headroom.ROTATIONS}},
                {"name": "b", "wanted": 2.0, "refused": 0.0, "peak": -9.0,
                 "rotations": {n: {"peak_down": 1.0, "loudness_moved": 0.01,
                                   "band_moved": 0.02} for n, _ in headroom.ROTATIONS}}]
        text = "\n".join(headroom.summary(rows))
        self.assertIn("1 of 2 track(s) held under the target", text)
        self.assertIn("held back 3.0 dB (median)", text)
        self.assertIn("gives back 2.00 dB of the held-back level", text)
        # The table's sign: peaks that went down read as a minus.
        self.assertIn("peak -1.50 dB (median, down), -2.00 at best; lowers the "
                      "peak on 2 of 2", text)

    def test_peaks_that_rose_read_as_up(self):
        """Jeff's 132 processed tracks: rotation RAISED the median peak by
        about 1 dB -- limited masters, whose flattened tops it knocks out of
        line -- and the first summary said "peaks down -0.97"."""
        rows = [{"name": "a", "wanted": -3.0, "refused": 0.0, "peak": -0.1,
                 "rotations": {n: {"peak_down": -1.0, "loudness_moved": 0.01,
                                   "band_moved": 0.02} for n, _ in headroom.ROTATIONS}}]
        text = "\n".join(headroom.summary(rows))
        self.assertIn("peak +1.00 dB (median, up)", text)
        self.assertIn("lowers the peak on 0 of 1", text)


if __name__ == "__main__":
    unittest.main()
