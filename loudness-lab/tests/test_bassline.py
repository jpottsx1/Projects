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


DEEP = [41.2, 49.0, 36.7, 46.2, 43.7, 0.0, 51.9, 38.9]


def _deep_line(seed: int = 1, repeats: int = 3, kicks: float = 1.0):
    """(bass part, mix, each note's fundamental as it sits in the mix).

    Notes under 56 Hz, each starting at a random phase, and in the mix a
    kick on every one: She Blinded Me With Science, where the bass line is
    the kick drum. The fundamental is kept apart as the truth a tone in
    step with the note has to match."""
    rng = np.random.default_rng(seed)
    n = int(NOTE_S * RATE)
    d = np.arange(n) / RATE
    bass, fund, drums = [], [], []
    for f in DEEP * repeats:
        if not f:
            bass.append(np.zeros(n)); fund.append(np.zeros(n)); drums.append(np.zeros(n))
            continue
        phi = rng.uniform(0, 2 * np.pi)
        env = np.exp(-d / 0.8) * np.minimum(1.0, d / 0.004)
        bass.append(sum(np.sin(2 * np.pi * f * k * d + k * phi) / k
                        * np.exp(-d * 10 * (k - 1)) for k in range(1, 5)) * env)
        fund.append(np.sin(2 * np.pi * f * d + phi) * env)
        drums.append(fixtures._kick(n, rng))
    bass, fund = 0.5 * np.concatenate(bass), 0.5 * np.concatenate(fund)
    mix = bass + kicks * 0.5 * np.concatenate(drums)
    stereo = lambda y: np.stack([y, y], axis=1).astype(np.float32)
    return stereo(bass), stereo(mix), fund


def _middles(n_total: int, skip: float = 0.12):
    """The middle of each note: clear of its rise, its fall and the kick."""
    n = int(NOTE_S * RATE)
    for k, f in enumerate(DEEP * (n_total // (n * len(DEEP)))):
        if f:
            yield f, slice(k * n + int(skip * RATE), (k + 1) * n - int(0.05 * RATE))


class TestADeepNoteGetsATone(unittest.TestCase):
    """Under 56 Hz an octave down is under 28 Hz, so a deep note gets a tone
    on its own pitch -- in step with it, the phase read from the mix."""

    @classmethod
    def setUpClass(cls):
        cls.bass, cls.mix, cls.fund = _deep_line()
        cls.free, cls.locked, cls.heard = bassline.tones(
            cls.bass, RATE, cls.bass.shape[0], mix=cls.mix)

    def in_step(self, tone):
        """Per note: how closely the tone matches the note's own
        fundamental in the mix, 1 exactly in step, -1 exactly against."""
        out = []
        for f, where in _middles(tone.size):
            a, b = tone[where].astype(np.float64), self.fund[where]
            out.append(float(np.dot(a, b) / np.linalg.norm(a) / np.linalg.norm(b)))
        return np.array(out)

    def test_it_is_in_step_with_every_note(self):
        agree = self.in_step(self.locked)
        self.assertGreater(float(np.min(agree)), 0.95, agree.round(3))

    def test_it_is_a_tone_not_the_mix(self):
        """Only the phase is read from the mix, and slowly: a lock wide
        enough to follow the kick would print the kick's thump into the
        tone's wobble. Over each whole note, kick included, the tone keeps
        99.5% of its energy within 6 Hz of the note (at 6 Hz: 99.95%; a
        60 Hz lock: 97.8%)."""
        for f, where in _middles(self.locked.size, skip=0.0):
            seg = self.locked[where].astype(np.float64)
            spectrum = np.abs(np.fft.rfft(seg * np.hanning(seg.size), 8 * seg.size)) ** 2
            freqs = np.fft.rfftfreq(8 * seg.size, 1 / RATE)
            self.assertGreater(spectrum[np.abs(freqs - f) < 6].sum() / spectrum.sum(),
                               0.995, f)

    def test_so_every_note_only_gains(self):
        # The note's own band, before and after, at the level the stage
        # would add: never less, where a tone at a guessed phase takes
        # some notes away.
        band = lambda y: subbass._band(y, RATE, 30.0, 60.0)
        scale = 0.5 * np.abs(self.fund).max() / np.abs(self.locked).max()
        guessed = self.locked.astype(np.float64)
        n = int(NOTE_S * RATE)
        # The same tone at a phase not read from the mix: its own start.
        rng = np.random.default_rng(5)
        for k in range(0, guessed.size, n):
            chunk = guessed[k:k + n]
            analytic = np.fft.ifft(np.fft.fft(chunk) * np.r_[1, 2 * np.ones(chunk.size // 2 - 1),
                                                         np.zeros(chunk.size - chunk.size // 2)])
            guessed[k:k + n] = np.real(analytic * np.exp(1j * rng.uniform(0, 2 * np.pi)))
        mix = self.mix[:, 0].astype(np.float64)
        change = {"locked": [], "guessed": []}
        for f, where in _middles(mix.size):
            before = np.mean(band(mix)[where] ** 2)
            for name, tone in (("locked", self.locked), ("guessed", guessed)):
                after = np.mean(band(mix + scale * tone)[where] ** 2)
                change[name].append(10 * np.log10(after / before))
        self.assertGreater(min(change["locked"]), 1.0, np.round(change["locked"], 2))
        self.assertLess(min(change["guessed"]), 0.0,
                        "the fixture should show why the phase is read")

    def test_notes_above_56_hz_keep_the_octave_under(self):
        # The line the other tests use: its notes over 56 Hz get the same
        # octave-under tone as before, the recording given or not.
        bass, _ = _line(repeats=1)
        free, locked, heard = bassline.tones(bass, RATE, bass.shape[0], mix=bass)
        # LINE has two deep notes in ten, 41.2 and 55 Hz: only they are locked.
        self.assertTrue(0.12 < heard["on_note"] <= 0.2, heard["on_note"])
        without, _ = bassline.tone(bass, RATE, bass.shape[0])
        np.testing.assert_allclose(free, without, atol=1e-6)

    def test_without_the_recording_a_deep_note_gets_nothing(self):
        free, locked, heard = bassline.tones(self.bass, RATE, self.bass.shape[0])
        self.assertEqual(float(np.abs(locked).max()), 0.0)
        self.assertEqual(heard["on_note"], 0.0)
        self.assertIsNone(heard["median_deep_hz"])
        self.assertAlmostEqual(self.heard["median_deep_hz"], 44.0, delta=4.0)

    def test_the_sub_stage_never_flips_it(self):
        """enhance flips what it adds when the kick bursts run against the
        track. With the kick inverted in the mix one of these two is
        flipped; the tone in step with the notes must stay in step in
        both."""
        flipped = []
        for sign in (1.0, -1.0):
            bass, mix, fund = _deep_line(kicks=sign)
            free, locked, _ = bassline.tones(bass, RATE, bass.shape[0], mix=mix)
            kicks = subbass.detect_kicks(mix, RATE, mix - bass)
            out, report = subbass.enhance(mix, RATE, amount_db=4.0, kicks=kicks,
                                          bassline=(free, 0.7, locked))
            flipped.append(report["polarity_flipped"])
            added = (out / 10 ** (report["safety_trim_db"] / 20) - mix)[:, 0]
            for f, where in _middles(added.size, skip=0.3):
                a, b = added[where].astype(np.float64), fund[where]
                self.assertGreater(float(np.dot(a, b) / np.linalg.norm(a)
                                         / np.linalg.norm(b)), 0.8, (sign, f))
        self.assertEqual(sorted(flipped), [False, True])

    def test_the_report_says_it(self):
        line = fixtures.bassline_line(np.zeros_like(self.bass), self.bass,
                                      self.bass.shape[0], mix=self.mix)
        self.assertRegex(line, r"in step with the notes under 56 Hz \(around \d+ Hz\) \d+%")
        said = bassline.what_it_did(self.heard, 0.4)
        self.assertRegex(said, r"^40% of the sub under the bassline: one in step "
                               r"with the deep notes around \d+ Hz, \d+% of the track$")


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
