"""tools/low_end.py: how much bass a club's mono sub loses, and how much
mud sits above the reference -- read from the library, nothing processed."""

from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from scipy.signal import butter, sosfiltfilt

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import low_end  # noqa: E402
from loudnesslab import subbass  # noqa: E402
from tests.test_subbass import RATE, programme  # noqa: E402


class TestTheArithmetic(unittest.TestCase):
    def test_what_a_mono_sum_loses(self):
        # Side as strong as mid in every band: half the bass cancels, -3 dB.
        even = {b: (-20.0, 0.0, 0.0) for b in low_end.MONO_BANDS}
        self.assertAlmostEqual(low_end.mono_loss(even)[0], -3.0103, places=3)
        # No side figure: identical channels, nothing lost.
        mono = {b: (-20.0, None, 0.0) for b in low_end.MONO_BANDS}
        self.assertAlmostEqual(low_end.mono_loss(mono)[0], 0.0, places=6)
        # A loud band's stereo counts for more than a quiet band's.
        mixed = {b: (-60.0, 10.0, 0.0) for b in low_end.MONO_BANDS}
        mixed[63.0] = (-20.0, -30.0, 0.0)
        self.assertGreater(low_end.mono_loss(mixed)[0], -0.1)

    def test_mud_is_the_shape_above_the_reference(self):
        track = {b: (0.0, None, 3.0) for b in low_end.MUD_BANDS}
        reference = {b: 1.0 for b in low_end.MUD_BANDS}
        self.assertAlmostEqual(low_end.mud_excess(track, reference), 2.0)
        self.assertIsNone(low_end.mud_excess(track, {}))


class TestOnMeasuredTracks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = Path(tempfile.mkdtemp())
        music, ref = cls.dir / "music", cls.dir / "ref"
        music.mkdir()
        ref.mkdir()
        x, _ = programme(seconds=8.0)
        low = sosfiltfilt(butter(4, 120, fs=RATE, output="sos"), x, axis=0)
        flipped = x - low
        flipped[:, 0] += low[:, 0]
        flipped[:, 1] -= low[:, 1]
        mud = sosfiltfilt(butter(2, [200, 400], btype="band", fs=RATE, output="sos"),
                          x, axis=0)
        subbass.write_flac(music / "Mono Bass.flac", x.astype(np.float32), RATE)
        subbass.write_flac(music / "Out Of Step.flac", flipped.astype(np.float32), RATE)
        subbass.write_flac(music / "Muddy.flac", (x + mud).astype(np.float32), RATE)
        subbass.write_flac(ref / "Reference.flac", x.astype(np.float32), RATE)
        said = []
        cls.result = low_end.report(music, [ref], cls.dir / "l.db", out=said.append)
        cls.text = "\n".join(said)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir, ignore_errors=True)

    def by_name(self, name):
        return next(r for r in self.result["rows"] if r["name"] == name)

    def test_a_bass_out_of_step_is_found_and_a_mono_one_is_not(self):
        self.assertLess(self.by_name("Out Of Step.flac")["lost"], -10.0)
        self.assertAlmostEqual(self.by_name("Mono Bass.flac")["lost"], 0.0, places=3)
        self.assertEqual([r["name"] for r in self.result["against"]], ["Out Of Step.flac"])
        self.assertIn("1 of 3 lose more than 1 dB", self.text)
        self.assertIn("<- out of step", self.text)

    def test_mud_above_the_reference(self):
        self.assertGreater(self.by_name("Muddy.flac")["mud"], 3.0)
        self.assertAlmostEqual(self.by_name("Mono Bass.flac")["mud"], 0.0, delta=0.05)


if __name__ == "__main__":
    unittest.main()
