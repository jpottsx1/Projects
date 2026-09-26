"""The sub that follows the bassline (loudnesslab/bassline.py).

A synthetic bass line with known notes stands in for a separated bass
part: plucked notes with harmonics and a decay, rests between some, at
different levels. What is held: the notes are tracked, the tone sits an
octave under them (two for a high note, none for a deep one), follows the
bass's loudness, starts and stops without a click -- and nothing of the
bass part itself reaches the audio.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools"))
from loudnesslab import bassline, decode, render, stems, subbass  # noqa: E402
import measure_stem_kicks as fixtures  # noqa: E402

RATE = fixtures.RATE
NOTE_S = 0.5
# (Hz, level); 0 Hz is a rest.
LINE = [(82.4, 1.0), (110.0, 0.5), (73.4, 1.0), (0.0, 0.0), (98.0, 0.25),
        (55.0, 1.0), (146.8, 1.0), (196.0, 1.0), (41.2, 1.0), (0.0, 0.0)]


def _line(repeats: int = 3, seed: int = 0, hiss: float = 0.0):
    """(bass part, per-10 ms truth of the note in Hz). `hiss` adds noise
    far above any bass note, to show none of it arrives."""
    rng = np.random.default_rng(seed)
    parts, truth = [], []
    n = int(NOTE_S * RATE)
    for f, level in LINE * repeats:
        parts.append(level * fixtures._pluck(n, f, 0.4) if f else np.zeros(n))
        truth += [f] * int(NOTE_S * 100)
    y = np.concatenate(parts) * 0.5 + 0.002 * rng.standard_normal(n * len(LINE) * repeats)
    if hiss:
        t = np.arange(y.size) / RATE
        y = y + hiss * np.sin(2 * np.pi * 3000 * t)
    return np.stack([y, y], axis=1).astype(np.float32), np.array(truth)


def _settled(truth: np.ndarray, i: int) -> bool:
    """Frame i reads 64 ms of the part and up to 57 ms more of lag: only a
    frame whose whole reach is inside one note is judged on it."""
    return 3 <= i and i + 13 < truth.size and truth[i - 3] == truth[i] == truth[i + 13]


class TestTracking(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bass, cls.truth = _line()
        cls.f0, cls.level = bassline.track(cls.bass, RATE)

    def test_the_notes_are_found_to_within_a_percent(self):
        inside = [i for i in range(self.f0.size) if self.truth[i] > 0
                  and _settled(self.truth, i)]
        found = [i for i in inside if self.f0[i] > 0]
        self.assertGreaterEqual(len(found) / len(inside), 0.85)
        error = [abs(self.f0[i] / self.truth[i] - 1) for i in found]
        self.assertLess(float(np.percentile(error, 95)), 0.01)

    def test_a_rest_is_not_a_note(self):
        rests = [i for i in range(self.f0.size) if self.truth[i] == 0
                 and _settled(self.truth, i)]
        self.assertLess(float(np.mean(self.f0[rests] > 0)), 0.05)

    def test_the_level_follows_the_bass(self):
        # The note at half level reads about 6 dB under the ones at full.
        def at(f):
            idx = [i for i in range(self.f0.size) if self.truth[i] == f
                   and _settled(self.truth, i)]
            return float(np.median(self.level[idx]))
        self.assertAlmostEqual(20 * np.log10(at(110.0) / at(82.4)), -6.0, delta=2.0)


class TestWhereTheToneGoes(unittest.TestCase):
    def test_an_octave_under_two_for_a_high_note_none_for_a_deep_one(self):
        f0 = np.array([82.4, 146.8, 196.0, 60.0, 55.0, 41.2, 0.0])
        np.testing.assert_allclose(bassline.sub_frequency(f0),
                                   [41.2, 73.4, 49.0, 30.0, 0.0, 0.0, 0.0])

    def test_the_tone_is_at_the_octave_under_each_note(self):
        bass, truth = _line(repeats=2)
        tone, report = bassline.tone(bass, RATE, bass.shape[0])
        n = int(NOTE_S * RATE)
        for k, (f, _) in enumerate(LINE):
            # The middle of the note, clear of the rise and fall.
            seg = tone[k * n + n // 4:(k + 1) * n - n // 4].astype(np.float64)
            want = bassline.sub_frequency(np.array([f]))[0]
            if want == 0:
                self.assertLess(float(np.sqrt(np.mean(seg ** 2))),
                                1e-3 * np.abs(tone).max(), (f, "should be silent"))
                continue
            spectrum = np.abs(np.fft.rfft(seg * np.hanning(seg.size), 8 * seg.size))
            peak = np.fft.rfftfreq(8 * seg.size, 1 / RATE)[np.argmax(spectrum)]
            self.assertAlmostEqual(peak, want, delta=0.02 * want, msg=f)

    def test_no_click_where_a_note_starts_or_stops(self):
        # A sine's steepest step between samples is 2 pi f A / rate; a click
        # is a step well beyond that.
        bass, _ = _line(repeats=2)
        tone, _ = bassline.tone(bass, RATE, bass.shape[0])
        steepest = 2 * np.pi * 75.0 * np.abs(tone).max() / RATE
        self.assertLess(float(np.abs(np.diff(tone)).max()), 1.2 * steepest)

    def test_the_tone_follows_the_bass_loudness(self):
        bass, _ = _line(repeats=2)
        tone, _ = bassline.tone(bass, RATE, bass.shape[0])
        n = int(NOTE_S * RATE)

        def rms(k):
            seg = tone[k * n + n // 4:(k + 1) * n - n // 4].astype(np.float64)
            return float(np.sqrt(np.mean(seg ** 2)))
        # LINE[1] (110 Hz) is played at half the level of LINE[0] (82.4 Hz).
        self.assertAlmostEqual(20 * np.log10(rms(1) / rms(0)), -6.0, delta=2.0)


class TestTheShare(unittest.TestCase):
    def test_it_is_where_the_low_end_is(self):
        mix, drums, _ = fixtures.programme("groove", seconds=10.0)
        bass, _ = _line(repeats=1)
        n = min(drums.shape[0], bass.shape[0])
        drums, bass = drums[:n], bass[:n]
        silent = np.zeros_like(bass)
        self.assertGreater(bassline.share(silent, bass, RATE), 0.99)
        self.assertLess(bassline.share(drums, silent, RATE), 0.01)
        both = bassline.share(drums, bass, RATE)
        self.assertTrue(0.05 < both < 0.95, both)


class TestTheReportLine(unittest.TestCase):
    def test_it_says_what_the_setting_would_do(self):
        bass, _ = _line(repeats=2)
        silent = np.zeros_like(bass)
        line = fixtures.bassline_line(silent, bass, bass.shape[0])
        self.assertRegex(line, r"^bassline: a note \d+% of the track, around \d+ Hz; "
                               r"a tone around \d+ Hz \d+% of the track; the bass "
                               r"carries 100% of the low end, so 100% of the sub")


class TestTheSubStage(unittest.TestCase):
    """enhance(..., bassline=(tone, share))."""

    @classmethod
    def setUpClass(cls):
        cls.mix, cls.drums, cls.truth = fixtures.programme("groove", seconds=15.0)
        bass, _ = _line(repeats=1)
        n = cls.mix.shape[0]
        cls.bass = np.pad(bass, ((0, max(0, n - bass.shape[0])), (0, 0)))[:n]
        cls.tone, _ = bassline.tone(cls.bass, RATE, n)
        cls.kicks = subbass.detect_kicks(cls.mix, RATE, cls.drums)

    def added(self, out, report):
        """What enhance added: its safety trim scales the whole output,
        track included, so it is undone first."""
        untrimmed = out / 10 ** (report["safety_trim_db"] / 20)
        return (untrimmed - self.mix)[:, 0].astype(np.float64)

    def run_it(self, share, kicks=None):
        return subbass.enhance(self.mix, RATE, amount_db=4.0, kicks=kicks or self.kicks,
                               bassline=(self.tone, share))

    def test_the_lift_is_what_was_asked_for_however_it_is_shared(self):
        for share in (0.0, 0.5, 1.0):
            _, report = self.run_it(share)
            self.assertAlmostEqual(report["applied_db"], 4.0, delta=0.3, msg=share)
            self.assertAlmostEqual(report["bass_share"], share)

    def test_the_share_decides_where_it_goes(self):
        def with_tone(share):
            out, report = self.run_it(share)
            added = self.added(out, report)
            t = self.tone.astype(np.float64)
            # Either polarity: enhance flips the sub to reinforce the track.
            return abs(float(np.dot(added, t) / np.linalg.norm(added)
                             / np.linalg.norm(t)))
        self.assertGreater(with_tone(1.0), 0.95)
        self.assertLess(with_tone(0.0), 0.1)
        self.assertTrue(0.4 < with_tone(0.5) < 0.9)

    def test_too_few_kicks_puts_it_all_on_the_bassline(self):
        few = (self.kicks[0][:3], self.kicks[1][:3])
        _, report = self.run_it(0.3, kicks=few)
        self.assertAlmostEqual(report["applied_db"], 4.0, delta=0.3)
        self.assertEqual(report["bass_share"], 1.0)

    def test_nothing_of_the_bass_part_reaches_the_audio(self):
        # The part carries a loud 3 kHz whistle. The tone is synthesised
        # from its notes; the whistle must not arrive.
        bass, _ = _line(repeats=1, hiss=0.3)
        n = self.mix.shape[0]
        bass = np.pad(bass, ((0, max(0, n - bass.shape[0])), (0, 0)))[:n]
        tone, _ = bassline.tone(bass, RATE, n)
        out, report = subbass.enhance(self.mix, RATE, amount_db=4.0,
                                      kicks=self.kicks, bassline=(tone, 1.0))
        added = self.added(out, report)
        spectrum = np.abs(np.fft.rfft(added)) ** 2
        freqs = np.fft.rfftfreq(added.size, 1 / RATE)
        self.assertLess(spectrum[freqs > 1000].sum() / spectrum.sum(), 1e-4)


class TestTheStage(unittest.TestCase):
    """render.one with "Sub follows the bassline too" on."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.cache = Path(self.dir.name)
        mix, drums, truth = fixtures.programme("groove", seconds=15.0)
        bass, _ = _line(repeats=1)
        n = mix.shape[0]
        self.bass = np.pad(bass, ((0, max(0, n - bass.shape[0])), (0, 0)))[:n]
        self.mix = (mix + self.bass).astype(np.float32)
        self.drums = drums
        self.bpm = 60.0 / float(np.median(np.diff(truth)))

    def tearDown(self):
        self.dir.cleanup()

    def job(self, **changes):
        job = {"path": "track.mp3", "name": "track", "folder": "f", "stem": "track",
               "amount": 4.0, "skip": None, "label": "sub", "freq": 45.0,
               "decay": 0.12, "punch": 0.0, "punch_decay": 8.0,
               "declip": False, "declip_max": 6.0, "min_activity": 0.0,
               "target_lra": 0.0, "max_attenuation": 6.0, "transient": 0.0,
               "min_crest": 11.0, "air": 0.0, "air_tune": 3500.0,
               "stem_kicks": True, "bass_sub": True, "bpm": self.bpm,
               "stem_cache": str(self.cache), "target": -16.0,
               "estimator": "s_p95", "peak_ceiling": -1.0, "compare": True,
               "dry_run": True, "out_dir": self.dir.name, "fmt": "flac"}
        job.update(changes)
        return job

    def run_one(self, job):
        with mock.patch.object(decode, "decode", return_value=self.mix), \
                mock.patch.object(decode, "TARGET_RATE", RATE):
            return render.one(job)

    def test_the_sub_is_shared_with_the_bassline(self):
        stems.store_kick_source(self.cache, self.mix, RATE, self.drums, bass=self.bass)
        result = self.run_one(self.job())
        self.assertEqual(result["status"], "ok", result.get("reason"))
        self.assertIn("under the bassline", result["reason"])
        self.assertGreater(result["bass_share"], 0.0)

    def test_off_it_is_kicks_only(self):
        stems.store_kick_source(self.cache, self.mix, RATE, self.drums, bass=self.bass)
        result = self.run_one(self.job(bass_sub=False))
        self.assertEqual(result["bass_share"], 0.0)
        self.assertNotIn("bassline", result["reason"] or "")

    def test_without_a_kept_bass_part_it_says_so(self):
        stems.store_kick_source(self.cache, self.mix, RATE, self.drums)
        result = self.run_one(self.job())
        self.assertEqual(result["status"], "ok", result.get("reason"))
        self.assertIn("no bass part kept", result["reason"])
        self.assertEqual(result["bass_share"], 0.0)


    def test_a_separation_without_the_bass_part_is_redone(self):
        """Kept before the bass part was: with the bassline asked for,
        separating once more rather than going without."""
        import contextlib
        import io
        from loudnesslab import cli
        # As kept before the bass part was: drums and the air guide.
        quiet = np.zeros_like(self.drums)
        stems.store_kick_source(self.cache, self.mix, RATE, self.drums, [quiet, quiet])
        calls = []

        def separate(x, rate, backend):
            calls.append(backend)
            quiet = np.zeros_like(self.drums)
            return {"drums": self.drums, "bass": self.bass, "vocals": quiet,
                    "other": quiet}
        job = {"path": "a.mp3", "name": "a", "amount": 4.0, "skip": None,
               "stem_kicks": True}
        with mock.patch.object(decode, "decode", return_value=self.mix), \
                mock.patch.object(decode, "TARGET_RATE", RATE), \
                mock.patch.object(stems, "separate", separate), \
                contextlib.redirect_stdout(io.StringIO()):
            cli._separate_for_kicks([dict(job)], self.cache, porcelain=True, quiet=True)
            self.assertEqual(calls, [])
            cli._separate_for_kicks([dict(job, bass_sub=True)], self.cache,
                                    porcelain=True, quiet=True)
        self.assertEqual(calls, ["demucs"])
        self.assertTrue(stems.has_kick_source(self.cache, self.mix, report=True))


if __name__ == "__main__":
    unittest.main()
