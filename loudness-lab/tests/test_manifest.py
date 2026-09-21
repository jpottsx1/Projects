"""The run record a player reads.

The one property worth testing here is alignment. Every variant of a track
is rendered from the SAME decode at the same rate, so they are sample-aligned
with each other by construction -- which is what lets a player switch between
them mid-bar without seeking, and is the whole reason the file exists. If
that ever stops being true the manifest must stop claiming it.
"""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import sys
import tempfile
import unittest
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from loudnesslab import cli  # noqa: E402

RATE = 48000
HAVE_FFMPEG = (shutil.which("ffmpeg") is not None
               and shutil.which("ffprobe") is not None)


def groove(seconds: float = 12.0, bpm: float = 120.0) -> np.ndarray:
    """Something with kicks in it, so the sub stage has work to do."""
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    rng = np.random.default_rng(7)
    mix = 0.3 * np.sin(2 * np.pi * 110.0 * t)
    for onset in np.arange(0.0, seconds, 60.0 / bpm):
        start = int(onset * RATE)
        span = min(int(0.2 * RATE), n - start)
        if span <= 0:
            break
        u = np.arange(span) / RATE
        sweep = 110.0 * np.exp(-u / 0.02) + 45.0
        mix[start:start + span] += (np.sin(2 * np.pi * np.cumsum(sweep) / RATE)
                                    * np.exp(-u / 0.08))
        mix[start:start + span] += (rng.standard_normal(span)
                                    * np.exp(-u / 0.002) * 0.3)
    stereo = np.column_stack([mix, mix * 0.98])
    return stereo / np.abs(stereo).max() * 0.98


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class Manifest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name) / "library"
        cls.root.mkdir(parents=True)
        with wave.open(str(cls.root / "groove.wav"), "wb") as handle:
            handle.setnchannels(2)
            handle.setsampwidth(2)
            handle.setframerate(RATE)
            handle.writeframes((groove() * 32767).astype("<i2").tobytes())

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_subbass(self, *extra: str) -> tuple[Path, str]:
        out_dir = Path(tempfile.mkdtemp(dir=self.tmp.name))
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = cli.main(["subbass", str(self.root), "--quiet", "--amount",
                             "5", "--db", str(Path(self.tmp.name) / "m.db"),
                             "--out", str(out_dir), *extra])
        self.assertEqual(code, 0, buffer.getvalue())
        return out_dir, buffer.getvalue()

    def load(self, *extra: str) -> dict:
        out_dir, text = self.run_subbass(*extra)
        path = out_dir / "manifest.json"
        self.assertTrue(path.exists(), f"no manifest written\n{text}")
        return json.loads(path.read_text())

    def test_a_comparison_run_records_both_variants(self):
        manifest = self.load()
        self.assertEqual(manifest["version"], 1)
        self.assertEqual(manifest["rate"], RATE)
        track, = manifest["tracks"]
        self.assertEqual([v["kind"] for v in track["variants"]],
                         ["original", "processed"])

    def test_the_variants_are_the_same_length_to_the_sample(self):
        """The alignment claim, which a player switching mid-bar relies on.
        Both come from one decode, so they cannot drift."""
        manifest = self.load()
        track, = manifest["tracks"]
        lengths = {v["seconds"] for v in track["variants"]}
        self.assertEqual(len(lengths), 1, f"variants differ in length: {lengths}")
        self.assertTrue(manifest["aligned"])

    def test_every_variant_points_at_a_file_that_exists(self):
        manifest = self.load()
        for track in manifest["tracks"]:
            for variant in track["variants"]:
                self.assertTrue(Path(variant["path"]).exists(), variant["path"])

    def test_each_variant_carries_what_a_fair_monitor_needs(self):
        """A player that switches without matching level is only measuring
        which one is louder."""
        manifest = self.load()
        track, = manifest["tracks"]
        for variant in track["variants"]:
            for field in ("lufs_i", "s_p95", "true_peak_dbtp"):
                self.assertIsInstance(variant[field], float, field)

    def test_the_settings_that_produced_it_are_recorded(self):
        manifest = self.load("--punch", "4")
        self.assertEqual(manifest["settings"]["amount"], 5.0)
        self.assertEqual(manifest["settings"]["punch"], 4.0)

    def test_a_single_output_run_records_one_variant(self):
        manifest = self.load("--no-compare")
        track, = manifest["tracks"]
        self.assertEqual([v["kind"] for v in track["variants"]], ["processed"])

    def test_a_dry_run_writes_no_manifest(self):
        """It wrote no audio, so a manifest would point at nothing."""
        out_dir, _ = self.run_subbass("--dry-run")
        self.assertFalse((out_dir / "manifest.json").exists())


if __name__ == "__main__":
    unittest.main()
