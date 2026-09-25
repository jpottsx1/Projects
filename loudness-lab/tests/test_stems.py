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
from loudnesslab import air, cli, decode, render, stems, subbass  # noqa: E402
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
            # Every kick, the syncopated one included: the grid is picked to
            # fit the kicks, so a kick between beats is kept. What gets in
            # with it is the low floor toms of the fills, which are kick
            # weight and on a sixteenth grid -- the trade, measured.
            self.assertEqual(recall, 1.0, drift)
            self.assertGreaterEqual(precision, 0.75, drift)

    def test_what_survives_is_close_to_the_kicks(self):
        # Before: more than two hits for every kick -- snares, claps, toms
        # and scratches as well. After: within a third of the real count.
        drums, truth, _ = fixtures.backbeat(seed=0, drift=0.015)
        found, kept, _ = self.select(drums, 104.0)
        self.assertGreater(found.size, 2 * truth.size)
        self.assertLessEqual(kept.size, 1.35 * truth.size)

    def test_the_grid_is_the_one_the_kicks_sit_on(self):
        # Four-on-the-floor sits on quarters. Kicks on every eighth -- a
        # SAW-style record, or a tag at half the tempo -- on eighths.
        _, drums, truth = fixtures.programme("groove", seed=0)
        bpm = 60 / float(np.median(np.diff(truth)))
        self.assertEqual(self.select(drums, bpm)[2]["grid_step"], 1)
        self.assertEqual(self.select(drums, bpm / 2)[2]["grid_step"], 2)
        self.assertEqual(self.select(drums, bpm / 4)[2]["grid_step"], 4)

    def test_a_loose_fit_is_no_grid_at_all(self):
        # Domino Dancing's best fit was 0.32: a grid that loose drops most
        # of the kicks. Under MIN_GRID_COHERENCE the weight filter works
        # alone rather than trusting it.
        drums, _, _ = fixtures.backbeat(seed=0, drift=0.03)
        _, _, report = self.select(drums, 104.0)
        self.assertLess(report["grid_coherence"], subbass.MIN_GRID_COHERENCE)
        self.assertIsNone(report["grid_step"])
        self.assertEqual(report["off_grid"], 0)

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

    def test_a_tag_at_half_the_tempo_keeps_every_kick(self):
        # Four-on-the-floor on a half-speed grid lands alternately on and
        # exactly between its beats. Quarters of that tag would keep every
        # other kick; its eighths keep them all.
        _, drums, truth = fixtures.programme("groove", seed=0)
        bpm = 60 / float(np.median(np.diff(truth)))
        _, kept, report = self.select(drums, bpm / 2)
        self.assertEqual(report["grid_step"], 2)
        self.assertEqual(fixtures.score(kept, truth)[:2], (1.0, 1.0))

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


def _kicks_at(pitch: float, tail_s: float, seconds: float = 20.0,
              every: float = 0.5) -> tuple[np.ndarray, np.ndarray]:
    """A drum part of pitched kicks: a short downward sweep settling at
    `pitch`, falling 20 dB in `tail_s`. Returns (stereo part, onsets)."""
    n = int(seconds * RATE)
    t = np.arange(int(1.0 * RATE)) / RATE
    tau = tail_s / np.log(10)
    kick = (np.sin(2 * np.pi * np.cumsum(pitch * (1 + 0.5 * np.exp(-t * 50))) / RATE)
            * np.exp(-t / tau))
    y, onsets = np.zeros(n), []
    for on in np.arange(0, seconds - 1, every):
        i = int(on * RATE)
        onsets.append(i)
        y[i:i + t.size] += kick[: n - i]
    y = y / np.abs(y).max() * 0.8
    return np.stack([y, y], axis=1).astype(np.float32), np.array(onsets)


class TestTuningTheSub(unittest.TestCase):
    """The burst follows the track's kick: 1988 dance records measured
    58-84 Hz kicks falling 20 dB in 74-252 ms, under a fixed 45 Hz burst
    that rang for about 280."""

    def test_the_kick_is_measured(self):
        for pitch, tail in ((55.0, 0.3), (70.0, 0.127), (84.0, 0.115)):
            drums, onsets = _kicks_at(pitch, tail, every=1.2)
            measured = subbass.kick_voice(drums, RATE, onsets)
            self.assertAlmostEqual(measured[0], pitch, delta=1.0)
            self.assertAlmostEqual(measured[1], tail, delta=0.02)

    def test_the_burst_goes_an_octave_under_or_onto_the_kick(self):
        self.assertAlmostEqual(subbass.tuned_burst(70.0, 0.127)[0], 35.0)
        self.assertAlmostEqual(subbass.tuned_burst(84.0, 0.115)[0], 42.0)
        # An octave under 58 is 29 Hz, below the band: the kick's own pitch.
        self.assertAlmostEqual(subbass.tuned_burst(58.0, 0.1)[0], 58.0)
        self.assertAlmostEqual(subbass.tuned_burst(45.0, 0.1)[0], 45.0)

    def test_the_burst_is_gone_when_the_kick_is(self):
        freq, decay = subbass.tuned_burst(70.0, 0.127)
        # exp(-t/decay) is down 20 dB at decay * ln(10).
        self.assertAlmostEqual(decay * np.log(10), 0.127, delta=0.001)
        self.assertEqual(subbass.tuned_burst(70.0, 5.0)[1], subbass.TUNED_DECAY_S[1])
        self.assertEqual(subbass.tuned_burst(70.0, 0.001)[1], subbass.TUNED_DECAY_S[0])

    def test_too_few_kicks_leave_the_burst_alone(self):
        drums, onsets = _kicks_at(70.0, 0.127)
        self.assertIsNone(subbass.kick_voice(drums, RATE, onsets[:3]))


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
        # Refused, once. Now the grid is the tag's eighths and every kick
        # keeps its burst, and the log says which grid it used.
        stems.store_kick_source(self.cache, self.mix, RATE, self.drums)
        result = self.run_one(self.job(bpm=self.bpm / 2))
        self.assertEqual(result["status"], "ok", result.get("reason"))
        seconds = self.mix.shape[0] / RATE
        self.assertAlmostEqual(result["kicks_per_minute"] * seconds / 60,
                               self.truth.size, delta=1)
        self.assertIn("eighths", result["reason"])

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

    def test_the_sub_is_tuned_to_a_70_hz_kick(self):
        """Stage level: a 70 Hz kick gets its sub at 35 Hz, and the energy
        that goes in is there -- not at the old fixed 45."""
        drums, onsets = _kicks_at(70.0, 0.127)
        rng = np.random.default_rng(4)
        self.mix = (drums + 0.02 * rng.standard_normal(drums.shape)).astype(np.float32)
        stems.store_kick_source(self.cache, self.mix, RATE, drums)
        result = self.run_one(self.job(bpm=120.0))
        self.assertEqual(result["status"], "ok", result.get("reason"))
        self.assertAlmostEqual(result["sub_hz"], 35.0, delta=1.0)
        self.assertAlmostEqual(result["sub_decay_ms"], 127 / np.log(10), delta=10)
        self.assertIn("tuned to 35 Hz", result["reason"])

        # And the burst that tuning produces lands at 35 Hz.
        out, _ = subbass.enhance(self.mix, RATE, amount_db=5.0,
                                 freq=result["sub_hz"],
                                 decay_s=result["sub_decay_ms"] / 1000,
                                 kicks=(onsets, np.ones(onsets.size)))
        added = (out.astype(np.float64) - self.mix)[:, 0]
        spectrum = np.abs(np.fft.rfft(added))
        freqs = np.fft.rfftfreq(added.size, 1 / RATE)
        band = (freqs > 20) & (freqs < 80)
        self.assertAlmostEqual(float(freqs[band][np.argmax(spectrum[band])]), 35.0,
                               delta=2.0)

    def test_without_the_stem_the_burst_is_the_fixed_one(self):
        result = self.run_one(self.job(stem_kicks=False))
        self.assertEqual(result["sub_hz"], 45.0)
        self.assertAlmostEqual(result["sub_decay_ms"], 120.0)

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
        quiet = np.zeros_like(self.drums)
        return {"drums": self.drums, "vocals": quiet, "other": quiet,
                "bass": quiet}

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
        return {"path": "a.mp3", "name": "a", "amount": 5.0, "skip": None,
                "stem_kicks": True, **changes}

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

    def test_guided_air_is_separated_even_with_no_sub(self):
        self.run_pass([self.job(amount=0.0, stem_kicks=False, air=2.0,
                                air_stems=True)])
        self.assertEqual(self.calls, 1)
        self.assertTrue(stems.has_kick_source(self.cache, self.mix, guide=True))

    def test_a_separation_without_the_guide_is_redone_for_air(self):
        # Separations from before the guide existed kept only the drums.
        stems.store_kick_source(self.cache, self.mix, RATE, self.drums)
        self.assertFalse(stems.has_kick_source(self.cache, self.mix, guide=True))
        self.run_pass([self.job(air=2.0, air_stems=True)])
        self.assertEqual(self.calls, 1)
        self.assertIsNotNone(stems.load_air_guide(self.cache, self.mix, RATE))

    def test_a_failure_is_carried_to_the_track_not_raised(self):
        def broken(x, rate, backend):
            raise RuntimeError("MPS out of memory")
        job = self.job()
        events = self.run_pass([job], separate=broken)
        self.assertEqual(events[0]["status"], "error")
        self.assertIn("out of memory", job["stem_error"])


def _hats_then_voice(seconds: float = 12.0):
    """A drum stem of bright hi-hat noise in the first half only, and a
    'vocal' -- a 3-6 kHz tone cluster -- in the second half only. The mix is
    both. Returns (mix, drums, voice), each stereo."""
    from scipy.signal import butter, sosfilt
    n = int(seconds * RATE)
    rng = np.random.default_rng(7)
    t = np.arange(n) / RATE
    half = n // 2
    hats = sosfilt(butter(4, 6000, btype="high", fs=RATE, output="sos"),
                   rng.standard_normal(n)) * 0.2
    hats[half:] = 0
    voice = sum(np.sin(2 * np.pi * f * t) for f in (3100, 4200, 5300)) * 0.08
    voice[:half] = 0
    st = lambda y: np.stack([y, y], axis=1).astype(np.float32)  # noqa: E731
    return st(hats + voice), st(hats), st(voice)


class TestAirFollowsTheStems(unittest.TestCase):
    """Air where vocals and instruments carry the top end, not hi-hats."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.cache = Path(self.dir.name)
        self.mix, self.drums, self.voice = _hats_then_voice()
        stems.store_kick_source(self.cache, self.mix, RATE, self.drums,
                                [self.voice, np.zeros_like(self.voice)])
        self.half = self.mix.shape[0] // 2

    def tearDown(self):
        self.dir.cleanup()

    def test_the_guide_opens_on_the_voice_and_shuts_on_the_hats(self):
        guide = stems.load_air_guide(self.cache, self.mix, RATE)
        self.assertEqual(guide.shape, (self.mix.shape[0],))
        second = RATE
        self.assertLess(float(np.median(guide[second:self.half - second])), 0.05)
        self.assertGreater(float(np.median(guide[self.half + second:-second])), 0.95)

    def test_the_air_goes_where_the_guide_is_open(self):
        guide = stems.load_air_guide(self.cache, self.mix, RATE)
        out, report = air.excite(self.mix, RATE, amount_db=3.0, guide=guide)
        self.assertTrue(report["guided"])
        added = (out.astype(np.float64) - self.mix)[:, 0]
        second = RATE
        on_hats = float(np.sqrt(np.mean(added[second:self.half - second] ** 2)))
        on_voice = float(np.sqrt(np.mean(added[self.half + second:-second] ** 2)))
        self.assertGreater(on_voice, 20 * on_hats)
        # Unguided, the hats get air as well: the thing this is for.
        plain, _ = air.excite(self.mix, RATE, amount_db=3.0)
        added = (plain.astype(np.float64) - self.mix)[:, 0]
        self.assertGreater(float(np.sqrt(np.mean(added[second:self.half - second] ** 2))),
                           5 * on_hats)

    def test_where_the_guide_is_open_the_air_is_what_plain_air_adds(self):
        """The gain is set as without a guide, then the guide takes air
        away where the drums carry the top end. So where it is open, the
        track gets exactly what the same setting would add unguided -- not
        an average squeezed into fewer passages, which would make them
        hotter than plain air at that setting ever is."""
        guide = stems.load_air_guide(self.cache, self.mix, RATE)
        out, guided = air.excite(self.mix, RATE, amount_db=3.0, guide=guide)
        plain_out, plain = air.excite(self.mix, RATE, amount_db=3.0)
        second = RATE
        voice = slice(self.half + second, self.mix.shape[0] - second)
        with_guide = (out.astype(np.float64) - self.mix)[voice, 0]
        without = (plain_out.astype(np.float64) - self.mix)[voice, 0]
        ratio = np.sqrt(np.mean(with_guide ** 2) / np.mean(without ** 2))
        self.assertAlmostEqual(float(ratio), 1.0, delta=0.05)
        # And over the whole track, clearly less than unguided.
        self.assertAlmostEqual(plain["measured_db"], 3.0, delta=0.1)
        self.assertLess(guided["measured_db"], plain["measured_db"] - 0.5)

    def test_no_guide_means_no_air_rather_than_air_everywhere(self):
        empty = Path(self.dir.name) / "elsewhere"
        job = {"path": "t.mp3", "name": "t", "folder": "f", "stem": "t",
               "amount": 0.0, "skip": None, "label": "air", "freq": 45.0,
               "decay": 0.12, "punch": 0.0, "punch_decay": 8.0,
               "declip": False, "declip_max": 6.0, "min_activity": 0.0,
               "target_lra": 0.0, "max_attenuation": 6.0, "transient": 0.0,
               "min_crest": 11.0, "air": 3.0, "air_tune": 3500.0,
               "stem_kicks": False, "air_stems": True, "bpm": None,
               "stem_cache": str(empty), "target": -16.0, "estimator": "s_p95",
               "peak_ceiling": -1.0, "compare": True, "dry_run": True,
               "out_dir": self.dir.name, "fmt": "flac"}
        with mock.patch.object(decode, "decode", return_value=self.mix), \
                mock.patch.object(decode, "TARGET_RATE", RATE):
            result = render.one(job)
            self.assertFalse(result["air"]["applied"])
            self.assertIn("no air guide", result["air"]["note"])
            result = render.one({**job, "stem_cache": str(self.cache)})
        self.assertTrue(result["air"]["applied"])
        self.assertTrue(result["air"]["guided"])


class TestFixedAir(unittest.TestCase):
    """--air-fixed: with --auto sizing the sub, air stays the amount set.
    A folder brighter than the reference otherwise gets none at any
    setting -- the 1988 folder, at +4.56 dB, got none."""

    @staticmethod
    def args(**changes):
        import argparse
        base = {"air": 3.0, "auto": True, "air_fixed": False}
        return argparse.Namespace(**{**base, **changes})

    def air_for(self, args, shortfall):
        reason = None if shortfall > 0 else "already within 0.0 dB of the reference"
        with mock.patch.object(cli, "_auto_amount",
                               return_value=(max(shortfall, 0.0), reason)):
            return cli._air_for(args, conn=None, path="t.mp3",
                                top_curve={8000: -20.0})

    def test_a_bright_track_gets_no_air_when_sized(self):
        self.assertEqual(self.air_for(self.args(), shortfall=-4.56), 0.0)

    def test_fixed_air_ignores_the_reference(self):
        self.assertEqual(self.air_for(self.args(air_fixed=True), shortfall=-4.56), 3.0)
        self.assertEqual(self.air_for(self.args(air_fixed=True), shortfall=1.2), 3.0)

    def test_sized_air_is_the_shortfall(self):
        self.assertEqual(self.air_for(self.args(), shortfall=1.2), 1.2)

    def test_without_auto_air_is_always_as_set(self):
        self.assertEqual(self.air_for(self.args(auto=False), shortfall=-4.56), 3.0)

    def test_it_is_a_profile_setting(self):
        from loudnesslab import profiles
        self.assertIs(profiles.FIELDS["air_fixed"], False)
        self.assertIs(profiles.FIELDS["air_stems"], False)


if __name__ == "__main__":
    unittest.main()
