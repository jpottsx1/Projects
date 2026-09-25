"""Kick detection on a drum stem.

The scenarios come from tools/measure_stem_kicks.py, which builds tracks
with known kick times. The drum part used here is the TRUE one, from
before the mix -- a perfect separator. That pins what this code does with
a stem; how good a real separator's stem is gets measured by the tool,
not asserted here, because it cannot be run without the model weights.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np
from scipy.signal import butter, sosfiltfilt

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools"))
from loudnesslab import cli, decode, render, stems, subbass  # noqa: E402
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


class TestSelectingTheKicks(unittest.TestCase):
    """select_kicks on drum parts built from what stopped four real tracks:
    a snare with low thump on 2 and 4, a clap, tom fills, scratches, and a
    syncopated kick. Scored against the kicks' known times."""

    def select(self, drums, bpm):
        kicks, strengths = subbass.detect_kicks(drums, RATE, drums)
        kept, _, report = subbass.select_kicks(drums, RATE, kicks, strengths, bpm)
        return kicks, kept, report

    def test_the_other_drums_read_as_kicks_before_and_not_after(self):
        for drift in (0.0, 0.015, 0.03):
            drums, truth, _ = fixtures.backbeat(seed=1, drift=drift)
            found, kept, report = self.select(drums, 104.0)
            self.assertLess(fixtures.score(found, truth)[1], 0.5, drift)
            recall, precision, _ = fixtures.score(kept, truth)
            self.assertGreaterEqual(precision, 0.85, drift)
            # What is lost is the syncopated kick, off the beat: 6 of 29.
            self.assertGreaterEqual(recall, 0.75, drift)
            self.assertEqual(report["grid_bpm"], 104.0)

    def test_what_survives_agrees_with_the_tag(self):
        # Before: more than two hits for every kick -- snares, claps, toms
        # and scratches as well. After: kicks on 1 and 3, reading half the
        # tag, which is one kick every other beat.
        drums, truth, _ = fixtures.backbeat(seed=0, drift=0.015)
        found, kept, _ = self.select(drums, 104.0)
        self.assertGreater(found.size, 2 * truth.size)
        self.assertLessEqual(kept.size, truth.size)
        self.assertAlmostEqual(fixtures.implied_bpm(kept, RATE) / 104.0, 0.5,
                               delta=0.03)

    def test_a_kick_under_a_snare_is_kept(self):
        # On 2 and 4 the kick and the snare land together. A filter asking
        # "is this ONLY a kick" dropped those and halved the kicks.
        _, drums, truth = fixtures.programme("buried", seed=0)
        _, kept, _ = self.select(drums, 60 / float(np.median(np.diff(truth))))
        self.assertEqual(fixtures.score(kept, truth)[0], 1.0)

    def test_scratches_and_snares_alone_are_dropped(self):
        drums, _, other = fixtures.backbeat(seed=0)
        _, kept, _ = self.select(drums, 104.0)
        for kind in ("scratch", "snare"):
            # Not the snare that ends each fill: it lands with the lowest
            # floor tom, which has a kick's weight and is on the beat. That
            # is the one wrong hit this lets through, and it is said so in
            # CLAUDE.md rather than tested away.
            alone = [h for h in other[kind]
                     if np.min(np.abs(other["tom"] - h)) > 0.03]
            hits = [h for h in alone if np.min(np.abs(kept / RATE - h)) <= 0.03]
            self.assertEqual(hits, [], kind)

    def test_a_tag_at_half_the_tempo_moves_to_double_not_to_every_other_kick(self):
        # Four-on-the-floor on a half-speed grid lands alternately on and
        # exactly between its beats. Fitting that grid would keep every
        # other kick; the grid at double the tag keeps them all.
        _, drums, truth = fixtures.programme("groove", seed=0)
        bpm = 60 / float(np.median(np.diff(truth)))
        _, kept, report = self.select(drums, bpm / 2)
        self.assertAlmostEqual(report["grid_bpm"], bpm, places=6)
        self.assertEqual(fixtures.score(kept, truth)[:2], (1.0, 1.0))
        self.assertAlmostEqual(self.select(drums, bpm)[2]["grid_bpm"], bpm, places=6)

    def test_a_tag_that_fits_no_grid_falls_back_to_weight_alone(self):
        # Not refused: the kicks that are heavy enough still get their sub.
        _, drums, truth = fixtures.programme("groove", seed=0)
        bpm = 60 / float(np.median(np.diff(truth)))
        for wrong in (bpm * 1.37, bpm * 0.77):
            _, kept, report = self.select(drums, wrong)
            self.assertIsNone(report["grid_bpm"], wrong)
            self.assertEqual(report["off_grid"], 0)
            self.assertEqual(fixtures.score(kept, truth)[:2], (1.0, 1.0))
            self.assertIn("weight alone", subbass.describe_selection(report, wrong))

    def test_without_a_tag_only_the_weight_filter_runs(self):
        drums, _, _ = fixtures.backbeat(seed=0)
        _, _, report = self.select(drums, None)
        self.assertEqual(report["off_grid"], 0)
        self.assertGreater(report["not_kick_shaped"], 0)


class TestTheKeptKickSource(unittest.TestCase):
    """What is kept is 8 kHz mono. It has to find the same kicks."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.cache = Path(self.dir.name)

    def tearDown(self):
        self.dir.cleanup()

    def test_it_finds_the_same_kicks_as_the_stem_it_came_from(self):
        mix, drums, _ = fixtures.programme("octave", seconds=20.0)
        stems.store_kick_source(self.cache, mix, RATE, drums)
        kept = stems.load_kick_source(self.cache, mix, RATE)
        self.assertEqual(kept.shape, mix.shape)
        direct, _ = subbass.detect_kicks(mix, RATE, drums)
        again, _ = subbass.detect_kicks(mix, RATE, kept)
        self.assertEqual(direct.size, again.size)
        # Within a millisecond: the burst is laid at these offsets.
        self.assertLessEqual(int(np.max(np.abs(direct - again))), RATE // 1000)

    def test_other_audio_is_not_found(self):
        mix, drums, _ = fixtures.programme("octave", seconds=8.0)
        stems.store_kick_source(self.cache, mix, RATE, drums)
        other, _, _ = fixtures.programme("groove", seconds=8.0)
        self.assertIsNone(stems.load_kick_source(self.cache, other, RATE))
        self.assertFalse(stems.has_kick_source(self.cache, other))
        self.assertTrue(stems.has_kick_source(self.cache, mix))


class TestTheStageUsesTheStem(unittest.TestCase):
    """render.one, the per-track chain, with a kept drum source. Decoding
    is stood in for so this runs without ffmpeg; nothing is written."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.cache = Path(self.dir.name)
        self.mix, self.drums, self.truth = fixtures.programme("octave", seconds=20.0)
        self.bpm = 60.0 / float(np.median(np.diff(self.truth)))

    def tearDown(self):
        self.dir.cleanup()

    def job(self, **changes) -> dict:
        job = {"path": "track.mp3", "name": "track", "folder": "f", "stem": "track",
               "amount": 5.0, "skip": None, "label": "sub", "freq": 45.0,
               "decay": 0.12, "punch": 0.0, "punch_decay": 8.0,
               "declip": False, "declip_max": 6.0, "min_activity": 0.0,
               "target_lra": 0.0, "max_attenuation": 6.0, "transient": 0.0,
               "min_crest": 11.0, "air": 0.0, "air_tune": 3500.0,
               "stem_kicks": True, "bpm": self.bpm, "stem_cache": str(self.cache),
               "target": -16.0, "estimator": "s_p95", "peak_ceiling": -1.0,
               "compare": True, "dry_run": True, "out_dir": self.dir.name,
               "fmt": "flac"}
        job.update(changes)
        return job

    def run_one(self, job: dict) -> dict:
        with mock.patch.object(decode, "decode", return_value=self.mix), \
                mock.patch.object(decode, "TARGET_RATE", RATE):
            return render.one(job)

    def test_the_kicks_come_from_the_stem(self):
        stems.store_kick_source(self.cache, self.mix, RATE, self.drums)
        on_stem = self.run_one(self.job())
        on_mix = self.run_one(self.job(stem_kicks=False))
        self.assertEqual(on_stem["status"], "ok", on_stem.get("reason"))
        seconds = self.mix.shape[0] / RATE
        self.assertAlmostEqual(on_stem["kicks_per_minute"] * seconds / 60,
                               self.truth.size, delta=1)
        # The mix reads the octave bass too: that is what this is for.
        self.assertGreater(on_mix["kicks_per_minute"],
                           1.5 * on_stem["kicks_per_minute"])
        self.assertGreater(on_stem["applied_db"], 1.0)

    def test_a_tag_at_half_the_tempo_still_gets_a_sub_on_every_kick(self):
        # Refused, once. Now the grid moves to double the tag and every kick
        # keeps its burst, and the log says which grid it used.
        stems.store_kick_source(self.cache, self.mix, RATE, self.drums)
        result = self.run_one(self.job(bpm=self.bpm / 2))
        self.assertEqual(result["status"], "ok", result.get("reason"))
        seconds = self.mix.shape[0] / RATE
        self.assertAlmostEqual(result["kicks_per_minute"] * seconds / 60,
                               self.truth.size, delta=1)
        self.assertIn("double", result["reason"])

    def test_a_backbeat_track_gets_its_sub(self):
        """The four tracks the first real run skipped: snare thump, fills
        and scratches on the drum stem read as double the tag. Now the
        stage keeps the kicks and goes ahead, and says what it dropped."""
        drums, truth, _ = fixtures.backbeat(seed=0, drift=0.015)
        rng = np.random.default_rng(3)
        mix = (drums + 0.05 * rng.standard_normal(drums.shape)).astype(np.float32)
        self.mix = mix
        stems.store_kick_source(self.cache, mix, RATE, drums)
        result = self.run_one(self.job(bpm=104.0))
        self.assertEqual(result["status"], "ok", result.get("reason"))
        self.assertGreater(result["applied_db"], 1.0)
        self.assertIn("too light", result["reason"])
        seconds = mix.shape[0] / RATE
        used = result["kicks_per_minute"] * seconds / 60
        self.assertLess(used, 1.2 * truth.size)

    def test_no_kept_stem_means_no_sub_and_says_why(self):
        result = self.run_one(self.job(stem_error="RuntimeError: out of memory"))
        self.assertEqual(result["status"], "skipped")
        self.assertIn("no drum stem", result["reason"])
        self.assertIn("out of memory", result["reason"])


class TestTheSeparationPass(unittest.TestCase):
    """cli._separate_for_kicks: once per track, before the pool, and never
    fatal. Demucs and ffmpeg are stood in for."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.cache = Path(self.dir.name)
        self.mix, self.drums, _ = fixtures.programme("octave", seconds=6.0)
        self.calls = 0

    def tearDown(self):
        self.dir.cleanup()

    def separate(self, x, rate, backend):
        self.calls += 1
        return {"drums": self.drums}

    def run_pass(self, jobs, separate=None):
        out = io.StringIO()
        with mock.patch.object(decode, "decode", return_value=self.mix), \
                mock.patch.object(decode, "TARGET_RATE", RATE), \
                mock.patch.object(stems, "separate", separate or self.separate), \
                contextlib.redirect_stdout(out):
            cli._separate_for_kicks(jobs, self.cache, porcelain=True, quiet=True)
        return [json.loads(line) for line in out.getvalue().splitlines()]

    @staticmethod
    def job(**changes):
        return {"path": "a.mp3", "name": "a", "amount": 5.0, "skip": None, **changes}

    def test_each_track_is_separated_once(self):
        events = self.run_pass([self.job()])
        self.assertEqual(self.calls, 1)
        self.assertTrue(stems.has_kick_source(self.cache, self.mix))
        self.assertEqual([e["phase"] for e in events], ["separate"])
        again = self.run_pass([self.job()])
        self.assertEqual(self.calls, 1, "a kept track was separated again")
        self.assertEqual(again[0]["reason"], "already separated")

    def test_tracks_getting_no_sub_are_not_separated(self):
        self.run_pass([self.job(amount=0.0), self.job(skip="within 0.5 dB")])
        self.assertEqual(self.calls, 0)

    def test_a_failure_is_carried_to_the_track_not_raised(self):
        def broken(x, rate, backend):
            raise RuntimeError("MPS out of memory")
        job = self.job()
        events = self.run_pass([job], separate=broken)
        self.assertEqual(events[0]["status"], "error")
        self.assertIn("out of memory", job["stem_error"])


if __name__ == "__main__":
    unittest.main()
