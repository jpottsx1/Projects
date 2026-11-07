"""The stem mix: what is heard live is what Commit writes.

Three claims, each tested against the failure it is for:

- the faders and the Bass and Air amounts map to gains the way the app
  computes them (the vectors at the bottom are the app's too:
  macapp/Tests/LoudnessLabUITests/StemMixTests.swift asserts the same
  numbers);
- the sub and air layers ARE the chain's sub and air: at every fader at
  0 dB, the mix is what `enhance` and `excite` would have made;
- a committed track, with its levelling taken back out, is the preview --
  the sum of the bundle's layers at the chosen gains -- and not the preview
  at a neighbouring setting.
"""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import tempfile
import unittest
import unittest.mock
from pathlib import Path

import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, sosfiltfilt

from loudnesslab import air, cli, decode, stemmix, stems, subbass

from tests.test_bassline import _line
from tests.test_processing_cli import HAVE_FFMPEG
from tests.test_subbass import RATE, programme

# The app's StemMixTests use these same stats and expect these gains.
# (energy, cross, layer energy, amount dB) -> gain, from gain_from_stats.
VECTORS = [
    (2.5e-3, 4.0e-4, 1.0e-3, 5.0),
    (2.5e-3, -3.0e-4, 1.0e-3, 3.0),
    (1.0e-5, 0.0, 4.0e-6, 12.0),
    (2.5e-3, 4.0e-4, 1.0e-3, 0.0),
    (2.5e-3, 4.0e-4, 0.0, 6.0),
]
LEVELS = [(0.0, 1.0), (-6.0, 0.501187), (6.0, 1.995262), (-29.9, 0.031989),
          (-30.0, 0.0), (-80.0, 0.0), (12.0, 3.981072), (20.0, 3.981072)]


def band_energy(x, low, high):
    sos = butter(4, [low, high], btype="band", fs=RATE, output="sos")
    return float(np.mean(sosfiltfilt(sos, x, axis=0) ** 2))


class TestMapping(unittest.TestCase):

    def test_fader_levels(self):
        for db, gain in LEVELS:
            with self.subTest(db=db):
                self.assertAlmostEqual(stemmix.level_gain(db), gain, places=5)
        self.assertEqual(stemmix.level_gain(float("nan")), 0.0)
        self.assertEqual(stemmix.level_gain(float("-inf")), 0.0)

    def test_the_gain_lifts_the_band_by_the_amount(self):
        """E + 2gC + g^2 S is E * 10^(a/10): the quadratic, solved."""
        for energy, cross, layer, amount in VECTORS:
            g = subbass.gain_from_stats(energy, cross, layer, amount)
            self.assertEqual(g, air.gain_from_stats(energy, cross, layer, amount))
            if layer <= 0:
                self.assertEqual(g, 0.0)
                continue
            self.assertGreaterEqual(g, 0.0)
            self.assertAlmostEqual((energy + 2 * g * cross + g * g * layer) / energy,
                                   10 ** (amount / 10), places=9)

    def test_vectors_the_app_checks(self):
        """Printed so the Swift side's numbers can be regenerated."""
        got = [round(subbass.gain_from_stats(*v), 9) for v in VECTORS]
        self.assertEqual(got, [1.959172344, 1.905663659, 6.092809681, 0.0, 0.0])

    def test_layer_gains_follow_the_choice(self):
        info = {"sub": {"available": True, "kick": True, "energy": 2.5e-3,
                        "tone_cross": 4.0e-4, "tone_energy": 1.0e-3,
                        "kick_cross": -3.0e-4, "kick_energy": 1.0e-3},
                "air": {"available": False}}
        gains = stemmix.layer_gains(info, {"levels_db": {"drums": -6, "vocals": -40},
                                           "sub_db": 5, "air_db": 3})
        self.assertEqual(gains["residual"], 1.0)
        self.assertAlmostEqual(gains["drums"], 0.501187, places=5)
        self.assertEqual(gains["bass"], 1.0)
        self.assertEqual(gains["vocals"], 0.0)
        self.assertAlmostEqual(gains["sub_tone"], 1.959172344, places=8)
        self.assertGreater(gains["sub_kick"], 0.0)
        self.assertEqual(gains["air"], 0.0)       # nothing to make air from
        off = stemmix.layer_gains(info, {"sub_db": 0})
        self.assertEqual((off["sub_tone"], off["sub_kick"]), (0.0, 0.0))
        capped = stemmix.layer_gains(info, {"sub_db": 99})
        self.assertEqual(capped["sub_tone"], stemmix.layer_gains(
            info, {"sub_db": stemmix.SUB_MAX_DB})["sub_tone"])


class TestTheLayersAreTheChain(unittest.TestCase):
    """At 0 dB on every fader the preview is the processing chain itself."""

    @classmethod
    def setUpClass(cls):
        cls.x, _ = programme(seconds=12.0)

    def assertSameAudio(self, a, b, tolerance=2e-5):
        self.assertEqual(a.shape, b.shape)
        self.assertLess(float(np.max(np.abs(a - b))), tolerance)

    def test_sub_without_a_bass_tone(self):
        layers = subbass.sub_layers(self.x, RATE)
        self.assertTrue(layers["available"])
        self.assertIsNone(layers["kick"])
        for amount in (2.0, 5.0):
            out, report = subbass.enhance(self.x, RATE, amount_db=amount)
            self.assertEqual(report["safety_trim_db"], 0.0)
            g = subbass.gain_from_stats(layers["energy"], layers["tone_cross"],
                                        layers["tone_energy"], amount)
            self.assertSameAudio(self.x + g * stemmix._stereo(layers["tone"]), out)

    def test_sub_with_a_bass_tone(self):
        """The kicks sized apart from the tone: two layers, two gains."""
        from loudnesslab import bassline
        n = self.x.shape[0]
        bass, _ = _line(repeats=1)
        bass = np.pad(bass, ((0, max(0, n - bass.shape[0])), (0, 0)))[:n]
        tone, _ = bassline.tone(bass, RATE, n)
        mix = (0.7 * self.x + 0.3 * bass).astype(np.float32)
        kicks = subbass.detect_kicks(mix, RATE)
        layers = subbass.sub_layers(mix, RATE, kicks=kicks, bassline=(tone, 0.4))
        self.assertIsNotNone(layers["kick"])
        out, report = subbass.enhance(mix, RATE, amount_db=4.0, kicks=kicks,
                                      bassline=(tone, 0.4))
        out = out / 10 ** (report["safety_trim_db"] / 20)
        info = {"sub": {"available": True, "kick": True,
                        **{k: layers[k] for k in ("energy", "tone_cross", "tone_energy",
                                                  "kick_cross", "kick_energy")}},
                "air": {"available": False}}
        gains = stemmix.layer_gains(info, {"sub_db": 4.0})
        self.assertAlmostEqual(gains["sub_kick"], report["kick_gain"], places=6)
        built = (mix + gains["sub_tone"] * stemmix._stereo(layers["tone"])
                 + gains["sub_kick"] * stemmix._stereo(layers["kick"]))
        self.assertSameAudio(built, out)

    def test_air(self):
        for guide in (None, np.linspace(0.2, 1.0, self.x.shape[0])):
            with self.subTest(guided=guide is not None):
                plan = air._air_plan(self.x, RATE, air.DEFAULT_TUNE_HZ,
                                     air.DRIVE, air.BIAS, guide)
                out, report = air.excite(self.x, RATE, amount_db=3.0, guide=guide)
                g = air.gain_from_stats(plan["before"], plan["cross"],
                                        plan["added"], 3.0)
                self.assertSameAudio(self.x + g * plan["harmonics"], out)


def fake_separate(x):
    """A deterministic split, standing in for Demucs. It need not sum to
    the track: the residual carries whatever it misses."""
    low = sosfiltfilt(butter(4, 150, btype="low", fs=RATE, output="sos"), x, axis=0)
    high = x - low
    return {"drums": (0.5 * low + 0.3 * high).astype(np.float32),
            "bass": (0.45 * low).astype(np.float32),
            "other": (0.55 * high).astype(np.float32),
            "vocals": (0.1 * high).astype(np.float32)}


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class TestCommitIsWhatWasHeard(unittest.TestCase):
    """Through the command, as the app drives it: prepare, then commit."""

    @classmethod
    def setUpClass(cls):
        cls.dir = Path(tempfile.mkdtemp())
        cls.src = cls.dir / "src"
        cls.src.mkdir()
        x, _ = programme(seconds=10.0)
        cls.track = cls.src / "Song.flac"
        subbass.write_flac(cls.track, x, RATE)
        cls.listing = cls.dir / "one.txt"
        cls.listing.write_text(str(cls.track) + "\n")
        cls.bundle = cls.dir / "bundle"
        code, cls.events = cls._cli(
            "--stem-preview", str(cls.bundle), "--amount", "4", "--air", "3")
        assert code == 0, cls.events
        cls.info = stemmix.read_info(cls.bundle)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir, ignore_errors=True)

    @classmethod
    def _cli(cls, *extra, out="out"):
        buffer = io.StringIO()
        with unittest.mock.patch.object(stems, "available", return_value=["demucs"]), \
                unittest.mock.patch.object(stems, "separate",
                                           side_effect=lambda x, *a, **k: fake_separate(x)), \
                contextlib.redirect_stdout(buffer):
            code = cli.main(["subbass", str(cls.src), "--db", str(cls.dir / "l.db"),
                             "--out", str(cls.dir / out), "--jobs", "1",
                             "--select", str(cls.listing), "--porcelain",
                             "--stem-cache", str(cls.dir / "cache"), *extra])
        return code, [json.loads(line) for line in buffer.getvalue().splitlines()
                      if line.strip()]

    def preview(self, choice):
        """What the app plays: every layer file times its gain, summed in
        float32 -- read from the files, not through stemmix's own reader."""
        gains = stemmix.layer_gains(self.info, choice)
        total = None
        for name, file in self.info["files"].items():
            rate, y = wavfile.read(self.bundle / file)
            self.assertEqual((rate, y.dtype), (RATE, np.float32))
            part = np.float32(gains[name]) * y
            total = part if total is None else total + part
        return total

    def test_preparing_writes_the_layers_and_no_track(self):
        self.assertEqual(self.events[-1]["event"], "stem_preview")
        self.assertFalse((self.dir / "out").exists()
                         and any((self.dir / "out").iterdir()))
        self.assertEqual(set(self.info["files"]) - {"sub_kick"},
                         {"residual", "drums", "bass", "other", "vocals",
                          "sub_tone", "air"})
        self.assertTrue(self.info["sub"]["available"])
        self.assertTrue(self.info["air"]["available"])
        self.assertEqual(self.info["defaults"], {"sub_db": 4.0, "air_db": 3.0})

    def test_at_unity_the_stems_sum_back_to_the_track(self):
        decoded = decode.decode(self.track)
        heard = self.preview({"sub_db": 0, "air_db": 0})
        self.assertLess(float(np.max(np.abs(heard - decoded))), 1e-6)

    def test_the_committed_track_is_the_preview(self):
        choice = {"bundle": str(self.bundle), "sub_db": 5.0, "air_db": 2.0,
                  "levels_db": {"drums": -4.0, "bass": 3.0, "other": 0.0,
                                "vocals": -60.0}}
        chosen = self.dir / "choice.json"
        chosen.write_text(json.dumps(choice))
        code, events = self._cli("--stem-mix", str(chosen), "--no-compare",
                                 "--peak-limit", "0", "--amount", "0",
                                 "--air", "0", out="committed")
        self.assertEqual(code, 0, events)
        manifest = json.loads((self.dir / "committed" / "manifest.json").read_text())
        track = manifest["tracks"][0]
        written = decode.decode(Path(track["variants"][0]["path"]))
        unlevelled = written / 10 ** (track["gain_db"] / 20)

        heard = self.preview(choice)
        error = float(np.max(np.abs(unlevelled - heard)))
        self.assertLess(error, 2e-4)
        # And not the preview at a neighbouring setting: a test that every
        # mix passed would prove nothing.
        for near in ({**choice, "levels_db": {**choice["levels_db"], "drums": -3.0}},
                     {**choice, "sub_db": 4.5}, {**choice, "air_db": 2.5}):
            other = float(np.max(np.abs(unlevelled - self.preview(near))))
            self.assertGreater(other, 10 * error)
        # What the results row says was done.
        self.assertIn("stem mix", track["sub_note"] or "")
        self.assertAlmostEqual(track["air_db"], 2.0, places=1)

    def test_a_bundle_for_other_audio_is_refused(self):
        other = self.dir / "other-src"
        other.mkdir(exist_ok=True)
        x, _ = programme(seconds=10.0, seed=3)
        subbass.write_flac(other / "Song.flac", x, RATE)
        listing = self.dir / "other.txt"
        listing.write_text(str(other / "Song.flac") + "\n")
        chosen = self.dir / "choice-other.json"
        chosen.write_text(json.dumps({"bundle": str(self.bundle), "sub_db": 2}))
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = cli.main(["subbass", str(other), "--db", str(self.dir / "l2.db"),
                             "--out", str(self.dir / "other-out"), "--jobs", "1",
                             "--select", str(listing), "--porcelain", "--no-compare",
                             "--stem-mix", str(chosen)])
        self.assertEqual(code, 0)
        events = [json.loads(line) for line in buffer.getvalue().splitlines() if line]
        failed = [e for e in events if e.get("status") == "error"]
        self.assertEqual(len(failed), 1)
        self.assertIn("changed since its stem mix", failed[0]["reason"])

    def test_one_track_only(self):
        listing = self.dir / "two.txt"
        listing.write_text(f"{self.track}\n{self.src / 'Other.flac'}\n")
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = cli.main(["subbass", str(self.src), "--db", str(self.dir / "l.db"),
                             "--select", str(listing), "--porcelain",
                             "--stem-preview", str(self.dir / "never")])
        self.assertEqual(code, 2)
        self.assertFalse((self.dir / "never").exists())


if __name__ == "__main__":
    unittest.main()
