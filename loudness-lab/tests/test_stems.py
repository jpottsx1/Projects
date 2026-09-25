"""Kick detection on a drum stem.

The scenarios come from tools/measure_stem_kicks.py, which builds tracks
with known kick times. The drum part used here is the TRUE one, from
before the mix -- a perfect separator. That pins what this code does with
a stem; how good a real separator's stem is gets measured by the tool,
not asserted here, because it cannot be run without the model weights.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from unittest import mock

import numpy as np
from scipy.signal import butter, sosfiltfilt

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools"))
from loudnesslab import stems, subbass  # noqa: E402
import measure_stem_kicks as fixtures  # noqa: E402

RATE = fixtures.RATE
HAVE_DEMUCS = (importlib.util.find_spec("demucs") is not None
               and importlib.util.find_spec("torch") is not None)


class TestDetectionOnAStem(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mix, cls.drums, cls.truth = fixtures.programme("octave", seconds=20.0)

    def test_the_mix_mistakes_an_octave_bass_for_kicks(self):
        # The reason for the stem. If this starts passing cleanly on the
        # mix, the case for separating has to be made again.
        kicks, _ = subbass.detect_kicks(self.mix, RATE)
        _, precision, _ = fixtures.score(kicks, self.truth)
        self.assertLess(precision, 0.6)

    def test_the_drum_stem_finds_only_the_kicks(self):
        kicks, _ = subbass.detect_kicks(self.mix, RATE, self.drums)
        recall, precision, offset = fixtures.score(kicks, self.truth)
        self.assertGreaterEqual(recall, 0.98)
        self.assertGreaterEqual(precision, 0.98)
        self.assertLess(offset, 10.0)

    def test_a_kick_buried_under_the_bass_is_found_on_the_stem(self):
        mix, drums, truth = fixtures.programme("buried", seconds=20.0)
        on_mix = fixtures.score(subbass.detect_kicks(mix, RATE)[0], truth)[0]
        on_stem = fixtures.score(subbass.detect_kicks(mix, RATE, drums)[0], truth)[0]
        self.assertLess(on_mix, 0.5)
        self.assertGreaterEqual(on_stem, 0.98)

    def test_without_a_stem_nothing_changes(self):
        mix, _, _ = fixtures.programme("groove", seconds=12.0)
        a, sa = subbass.detect_kicks(mix, RATE)
        b, sb = subbass.detect_kicks(mix, RATE, None)
        np.testing.assert_array_equal(a, b)
        np.testing.assert_array_equal(sa, sb)


class TestTheStemNeverReachesTheAudio(unittest.TestCase):
    def test_only_the_sub_is_added(self):
        """The stem moves the kick markers and nothing else. Hand enhance a
        'stem' full of loud high-frequency noise: if any of it leaked into
        the output, the difference would carry it above the sub octave."""
        mix, drums, truth = fixtures.programme("octave", seconds=20.0)
        rng = np.random.default_rng(1)
        hiss = sosfiltfilt(butter(4, 2000, btype="high", fs=RATE, output="sos"),
                           rng.standard_normal(drums.shape[0]))[:, None] * 0.3
        stem = (drums + hiss).astype(np.float32)
        out, report = subbass.enhance(mix, RATE, amount_db=5.0, drums=stem)
        self.assertEqual(report["kicks"], truth.size)

        # Undo the safety trim, which scales the whole track, then look at
        # what was added.
        added = (out / 10 ** (report["safety_trim_db"] / 20) - mix)[:, 0]
        above = sosfiltfilt(butter(4, 200, btype="high", fs=RATE, output="sos"),
                            added.astype(np.float64))
        ratio_db = 10 * np.log10(np.mean(above ** 2) / np.mean(added.astype(np.float64) ** 2))
        self.assertLess(ratio_db, -40.0)


class TestSeparate(unittest.TestCase):
    def test_an_unknown_backend_is_refused(self):
        with self.assertRaises(ValueError):
            stems.separate(np.zeros((1000, 2)), RATE, "nonsense")

    def test_a_missing_backend_says_so(self):
        with mock.patch.object(stems, "available", return_value=[]):
            with self.assertRaisesRegex(RuntimeError, "not installed"):
                stems.separate(np.zeros((1000, 2)), RATE, "demucs")

    @unittest.skipUnless(HAVE_DEMUCS, "demucs and torch not installed")
    def test_stems_line_up_with_the_input(self):
        """With an untrained model: this is about plumbing -- rates, lengths,
        channel order -- not separation quality. A stem a few samples short
        would put every sub burst a few samples early."""
        import torch
        from demucs.htdemucs import HTDemucs

        torch.manual_seed(0)
        model = HTDemucs(sources=list(stems.STEMS), samplerate=stems.MODEL_RATE,
                         segment=4, channels=8, t_layers=1)
        rng = np.random.default_rng(0)
        x = (rng.standard_normal((int(3.3 * RATE), 2)) * 0.1).astype(np.float32)
        out = stems.separate(x, RATE, "demucs", model=model)
        self.assertEqual(sorted(out), sorted(stems.STEMS))
        for name, stem in out.items():
            self.assertEqual(stem.shape, x.shape, name)
            self.assertEqual(stem.dtype, np.float32, name)
            self.assertTrue(np.all(np.isfinite(stem)), name)


if __name__ == "__main__":
    unittest.main()
