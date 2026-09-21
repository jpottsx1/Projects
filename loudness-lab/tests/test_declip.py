"""De-clipper tests.

The claim under test is not "it changed the waveform" -- anything can do
that. It is "the arc it draws is closer to the truth than the flat top it
replaced". So clean audio is clipped deliberately, restored, and the error
measured against the original that is still sitting there in memory. If
restoring did not beat leaving it alone, these fail.

The second claim is the one that decides whether this is safe to run across
a library: material that was never clipped has to come through untouched.
That is tested three ways -- quiet audio, audio sitting at exactly full
scale without clipping, and one channel of a stereo pair.
"""

from __future__ import annotations

import contextlib
import io
import shutil
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from loudnesslab import bs1770, cli, declip  # noqa: E402

HAVE_FFMPEG = (shutil.which("ffmpeg") is not None
               and shutil.which("ffprobe") is not None)

RATE = 48000


def programme(seconds: float = 8.0, seed: int = 0) -> np.ndarray:
    """Band-limited stereo with a moving envelope, peak-normalised to 1.0.

    A sum of sines rather than noise, so the truth is smooth and the peaks
    are narrow -- which is what clipping in real music looks like. The slow
    envelope stops every peak being the same height, so the fixture exercises
    short runs and long ones in the same pass.
    """
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    rng = np.random.default_rng(seed)
    x = np.zeros((n, 2))
    for freq in (55.0, 110.0, 165.0, 330.0, 740.0, 1480.0, 3300.0):
        for channel in range(2):
            x[:, channel] += (1.0 / (1.0 + freq / 200.0)) * np.sin(
                2 * np.pi * freq * t + rng.uniform(0, 2 * np.pi))
    x *= (0.75 + 0.25 * np.sin(2 * np.pi * 0.7 * t))[:, None]
    return x / np.abs(x).max()


def clipped_at(over_db: float, seconds: float = 8.0,
               seed: int = 0) -> tuple[np.ndarray, np.ndarray]:
    """(truth, clipped) for programme material driven `over_db` past full scale."""
    truth = programme(seconds, seed) * 10 ** (over_db / 20)
    return truth, np.clip(truth, -1.0, 1.0)


def sine(freq: float, seconds: float = 2.0, amplitude: float = 1.0) -> np.ndarray:
    t = np.arange(int(seconds * RATE)) / RATE
    wave = amplitude * np.sin(2 * np.pi * freq * t)
    return np.column_stack([wave, wave])


def harmonic_distortion_db(signal: np.ndarray, fundamental: float,
                           harmonics: int = 12) -> float:
    """Energy in the harmonics of `fundamental`, relative to the fundamental.

    Clipping a sine produces exactly this and nothing else, so it is the
    direct measure of how much clipping distortion is present.
    """
    spectrum = np.abs(np.fft.rfft(signal * np.hanning(signal.size))) ** 2
    freqs = np.fft.rfftfreq(signal.size, 1.0 / RATE)

    def energy_at(freq: float) -> float:
        centre = int(np.argmin(np.abs(freqs - freq)))
        return float(spectrum[max(0, centre - 3):centre + 4].sum())

    total = sum(energy_at(fundamental * k) for k in range(2, harmonics + 1))
    return float(10 * np.log10(total / energy_at(fundamental)))


class Reconstruction(unittest.TestCase):
    """Does the arc actually land nearer the truth than the flat top did?"""

    def error_at_clipped_samples(self, over_db: float) -> tuple[float, float]:
        truth, clipped = clipped_at(over_db)
        restored, _ = declip.restore(clipped, RATE)
        damaged = np.abs(clipped) >= declip.CLIP_THRESHOLD
        return (float(np.sqrt(np.mean((clipped[damaged] - truth[damaged]) ** 2))),
                float(np.sqrt(np.mean((restored[damaged] - truth[damaged]) ** 2))))

    def test_restoring_beats_leaving_it_alone(self):
        """The falsifiable one. Measured over 1 to 6 dB of overdrive, the
        reconstruction error runs 3.3 to 3.9 dB below the do-nothing error;
        the bar is set under that so a real regression trips it and ordinary
        drift does not."""
        for over_db in (1.0, 2.0, 3.0, 6.0):
            with self.subTest(over_db=over_db):
                nothing, restored = self.error_at_clipped_samples(over_db)
                improvement = 20 * np.log10(nothing / restored)
                self.assertGreater(
                    improvement, 2.5,
                    f"restoring only improved on doing nothing by "
                    f"{improvement:.2f} dB at {over_db:+.0f} dB over")

    def test_clipping_distortion_is_largely_removed(self):
        """Clipping a sine produces odd harmonics and nothing else, so the
        harmonic energy IS the damage. Observed drop is about 27 dB -- a
        factor of 500 in distortion energy."""
        for freq in (100.0, 440.0):
            for over_db in (1.0, 3.0):
                with self.subTest(freq=freq, over_db=over_db):
                    truth = sine(freq) * 10 ** (over_db / 20)
                    clipped = np.clip(truth, -1.0, 1.0)
                    restored, _ = declip.restore(clipped, RATE)
                    before = harmonic_distortion_db(clipped[:, 0], freq)
                    after = harmonic_distortion_db(restored[:, 0], freq)
                    self.assertLess(after, before - 20.0,
                                    f"distortion only fell from {before:.1f} "
                                    f"to {after:.1f} dB")

    def test_the_restored_peak_lands_near_the_true_peak(self):
        """Within about 0.13 dB on a clipped sine, where the true peak is
        known exactly. Bar at 0.3 dB."""
        for over_db in (1.0, 3.0):
            with self.subTest(over_db=over_db):
                truth = sine(220.0) * 10 ** (over_db / 20)
                restored, report = declip.restore(np.clip(truth, -1.0, 1.0), RATE)
                self.assertAlmostEqual(report["peak_after_dbfs"], over_db,
                                       delta=0.3)

    def test_short_runs_are_reconstructed_almost_exactly(self):
        """Where the accuracy actually is. Real clipping is mostly runs of a
        few samples, and across those the apex error stays under 0.01 of full
        scale -- the long runs are where the guessing starts."""
        truth, clipped = clipped_at(3.0)
        restored, _ = declip.restore(clipped, RATE)
        worst, counted = 0.0, 0
        for channel in range(2):
            for start, end, _ in declip.find_runs(clipped[:, channel]):
                if end - start > 8:
                    continue
                counted += 1
                worst = max(worst, abs(
                    np.abs(restored[start:end, channel]).max()
                    - np.abs(truth[start:end, channel]).max()))
        self.assertGreater(counted, 50, "fixture grew no short runs to judge")
        self.assertLess(worst, 0.02, f"worst short-run apex error {worst:.4f}")

    def test_a_restored_track_levelled_back_down_no_longer_clips(self):
        """End to end: the point of the exercise is a file with peaks in it
        that does not sit against the ceiling."""
        _, clipped = clipped_at(3.0)
        self.assertGreater(bs1770.count_clipping(clipped)[1], 0)
        restored, report = declip.restore(clipped, RATE)
        levelled = restored * 10 ** (-(report["headroom_db"] + 1.0) / 20)
        self.assertEqual(bs1770.count_clipping(levelled), (0, 0))


class LeavesCleanAudioAlone(unittest.TestCase):
    """The safety half. A de-clipper that damages unclipped material is worse
    than no de-clipper, because most of a library is unclipped."""

    def test_audio_nowhere_near_the_ceiling_comes_back_unchanged(self):
        quiet = sine(440.0, amplitude=0.7)
        restored, report = declip.restore(quiet, RATE)
        self.assertIs(restored, quiet)
        self.assertEqual(report["runs"], 0)
        self.assertEqual(report["restored_db"], 0.0)

    def test_a_full_scale_peak_that_never_clipped_is_left_alone(self):
        """The self-limiting property, and the reason a false detection is
        cheap. A bass sine at exactly 0 dBFS has a top flat enough to read as
        a clipping run, but its shoulders are already turning over, so the
        arc drawn through them is the peak that is already there.

        Note what is asserted and what is not. Below about 150 Hz the arc
        lands under the samples and nothing is added at all; above that it
        lands a hair over and the run counts as restored. Either way the
        audio moves by less than a millionth of full scale -- roughly -130
        dBFS, thirty dB under the noise floor of a 16-bit master -- and the
        peak does not move at all. The counter is not the claim; the change
        is."""
        for freq in (50.0, 100.0, 200.0):
            with self.subTest(freq=freq):
                clean = sine(freq)
                restored, report = declip.restore(clean, RATE)
                self.assertGreater(report["runs"], 0,
                                   "fixture no longer trips the detector, so "
                                   "it no longer tests anything")
                self.assertLess(float(np.abs(restored - clean).max()), 1e-6)
                self.assertLess(abs(report["restored_db"]), 0.01)

    def test_a_clean_channel_beside_a_clipped_one_is_untouched(self):
        truth = programme()
        stereo = np.column_stack([truth[:, 0] * 10 ** (3 / 20), truth[:, 1] * 0.5])
        clipped = np.clip(stereo, -1.0, 1.0)
        restored, report = declip.restore(clipped, RATE)
        self.assertGreater(report["restored"], 0)
        self.assertTrue(np.array_equal(restored[:, 1], clipped[:, 1]))
        self.assertFalse(np.array_equal(restored[:, 0], clipped[:, 0]))

    def test_no_sample_is_ever_made_smaller(self):
        """Clipping can only have reduced a sample, so restoration may only
        add. If this fails the arc is fighting the audio rather than
        completing it."""
        _, clipped = clipped_at(3.0)
        restored, _ = declip.restore(clipped, RATE)
        self.assertTrue(np.all(np.abs(restored) >= np.abs(clipped) - 1e-12))


class Refusals(unittest.TestCase):
    """What it declines to touch, and that declining is counted rather than
    silent -- an uncounted refusal is indistinguishable from a bug."""

    def test_a_run_too_long_to_be_a_peak_is_refused(self):
        """Fifty milliseconds at the ceiling is a squashed passage, not a
        clipped transient, and arcing over it would be composition rather
        than restoration."""
        wave = sine(200.0, seconds=1.0, amplitude=0.7)
        middle = slice(int(0.4 * RATE), int(0.4 * RATE) + int(0.05 * RATE))
        wave[middle, :] = 1.0
        restored, report = declip.restore(wave, RATE)
        self.assertEqual(report["runs"], 2)
        self.assertEqual(report["too_long"], 2)
        self.assertEqual(report["restored"], 0)
        self.assertIs(restored, wave)

    def test_a_shoulder_not_turning_over_contributes_no_slope(self):
        """Rising into the run and still rising out of it. The right-hand
        side says nothing about how tall the peak was, so it is dropped and
        the arc is drawn from the left alone -- counted, not silent."""
        ramp = np.concatenate([
            np.linspace(0.90, 0.9994, 200),    # climbing towards the ceiling
            np.full(6, 0.9996),                # a plateau at it
            np.linspace(0.9980, 0.9994, 200),  # and still climbing after
            np.linspace(0.9994, 0.0, 200)])
        wave = np.column_stack([ramp, ramp])
        _, report = declip.restore(wave, RATE)
        self.assertEqual(report["runs"], 2)
        self.assertEqual(report["flattened"], 2)

    def test_a_run_turning_over_on_neither_side_refuses_itself(self):
        """With both slopes dropped the Hermite collapses to a line between
        the two shoulders. Nothing then exceeds the audio, so the degenerate
        case needs no guard of its own -- it falls out as nothing_to_add."""
        flat = declip._hermite(10, 0.9996, 0.0, 0.9996, 0.0, 9)
        self.assertTrue(np.allclose(flat, 0.9996))

    def test_a_run_against_the_start_of_the_file_is_refused(self):
        """There is no shoulder on the left to arc from."""
        wave = sine(200.0, seconds=1.0, amplitude=0.7)
        wave[:4, :] = 1.0
        _, report = declip.restore(wave, RATE)
        self.assertEqual(report["runs"], 2)
        self.assertEqual(report["at_edge"], 2)

    def test_the_lift_cap_is_honoured(self):
        """A safety limit, not an estimate. Twelve dB of overdrive is more
        than any arc should be trusted to guess back."""
        truth = sine(220.0) * 10 ** (12 / 20)
        restored, report = declip.restore(np.clip(truth, -1.0, 1.0), RATE,
                                          max_restore_db=4.0)
        self.assertLessEqual(report["restored_db"], 4.0 + 1e-6)
        self.assertLessEqual(float(np.abs(restored).max()), 10 ** (4 / 20) + 1e-6)

    def test_every_run_is_either_restored_or_accounted_for(self):
        _, clipped = clipped_at(3.0)
        _, report = declip.restore(clipped, RATE)
        self.assertEqual(report["runs"], report["restored"] + report["refused"])


class Detection(unittest.TestCase):
    def test_a_run_never_straddles_a_sign_change(self):
        """A sample at +1 next to one at -1 is a signal at Nyquist, not one
        peak. Handing both to a single arc would be nonsense."""
        wave = np.zeros(200)
        wave[100:103] = 1.0
        wave[103:106] = -1.0
        runs = declip.find_runs(wave)
        self.assertEqual(runs, [(100, 103, 1), (103, 106, -1)])

    def test_runs_shorter_than_the_minimum_are_not_runs(self):
        wave = np.zeros(200)
        wave[50] = 1.0
        wave[100:102] = 1.0
        self.assertEqual(declip.find_runs(wave, min_run=2), [(100, 102, 1)])
        self.assertEqual(declip.find_runs(wave, min_run=3), [])

    def test_the_threshold_matches_the_one_the_reports_use(self):
        """If these drift apart, the tables say a track is clipped and the
        de-clipper finds nothing in it."""
        self.assertEqual(declip.CLIP_THRESHOLD,
                         bs1770.count_clipping.__defaults__[0])


class Arguments(unittest.TestCase):
    def test_mono_is_refused_rather_than_guessed_at(self):
        with self.assertRaises(ValueError):
            declip.restore(np.zeros(100), RATE)

    def test_a_shoulder_too_short_to_have_a_slope_is_refused(self):
        with self.assertRaises(ValueError):
            declip.restore(np.zeros((100, 2)), RATE, shoulder=1)

    def test_the_dtype_survives(self):
        _, clipped = clipped_at(3.0, seconds=2.0)
        restored, _ = declip.restore(clipped.astype(np.float32), RATE)
        self.assertEqual(restored.dtype, np.float32)


class Summary(unittest.TestCase):
    def test_a_clean_batch_says_so_rather_than_printing_nothing(self):
        text = declip.summarise([{"runs": 0}])
        self.assertIn("no runs", text)

    def test_a_batch_that_was_worked_on_reports_what_and_what_not(self):
        _, clipped = clipped_at(3.0, seconds=2.0)
        _, report = declip.restore(clipped, RATE)
        text = declip.summarise([report, {"runs": 0}])
        self.assertIn("1 of 2 track(s)", text)
        self.assertIn("run(s) restored", text)


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class ThroughMP3(unittest.TestCase):
    """The same falsifiable test, on the material this is actually for.

    Everything above scores the de-clipper against audio it clipped itself,
    which is the clean case: the flat tops are flat and every sample outside
    them is the truth. A library is not that. A library is MP3, and MPEG
    moves every sample, so by the time a clipped master reaches us the flat
    tops are rippled, some no longer read as flat at all, and the codec's own
    error sits under everything as a floor that no de-clipper can lift.

    So: clip known audio, encode it, decode it, restore that, and score it
    against the original that went in. This is the number that says what the
    tool does to your files, and it is a lot smaller than the clean one."""

    def measure(self, over_db: float, seconds: float = 10.0) -> float:
        truth, clipped = clipped_at(over_db, seconds=seconds)
        decoded = self.round_trip(clipped)
        truth, decoded = self.align(truth, decoded)
        damaged = np.abs(decoded) >= declip.CLIP_THRESHOLD
        self.assertGreater(damaged.sum(), 1000,
                           "the encode left nothing detectable to restore")
        restored, _ = declip.restore(decoded, RATE)
        nothing = np.sqrt(np.mean((decoded[damaged] - truth[damaged]) ** 2))
        fixed = np.sqrt(np.mean((restored[damaged] - truth[damaged]) ** 2))
        return float(20 * np.log10(nothing / fixed))

    def round_trip(self, x: np.ndarray) -> np.ndarray:
        from loudnesslab import decode
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "a.wav"
            encoded = Path(folder) / "a.mp3"
            with wave.open(str(source), "wb") as handle:
                handle.setnchannels(2)
                handle.setsampwidth(2)
                handle.setframerate(RATE)
                handle.writeframes((np.clip(x, -1, 1) * 32767)
                                   .astype("<i2").tobytes())
            subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y",
                            "-i", str(source), "-codec:a", "libmp3lame",
                            "-b:a", "320k", str(encoded)], check=True)
            return decode.decode(encoded).astype(np.float64)

    @staticmethod
    def align(a: np.ndarray, b: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """Encoders add a delay. Find it, or every sample compares to the
        wrong one and the whole measurement is noise."""
        window = min(len(a), 8 * RATE)
        correlation = np.correlate(b[:window, 0] - b[:window, 0].mean(),
                                   a[:window, 0] - a[:window, 0].mean(), "full")
        lag = int(np.argmax(correlation)) - (window - 1)
        b = b[lag:] if lag >= 0 else np.vstack([np.zeros((-lag, 2)), b])
        shared = min(len(a), len(b))
        return a[:shared], b[:shared]

    def test_restoring_still_beats_leaving_it_alone(self):
        """Smaller than on the clean fixture, and positive at every level.
        Measured at 320 kbps: about +2.0 dB where clipping is light, falling
        to +0.4 dB where it is heavy -- heavy clipping smears the flat tops
        enough that most of them are no longer findable. The bar is low
        because the honest number is low."""
        for over_db in (1.0, 3.0):
            with self.subTest(over_db=over_db):
                improvement = self.measure(over_db)
                self.assertGreater(
                    improvement, 0.15,
                    f"through MP3, restoring improved on doing nothing by "
                    f"only {improvement:.2f} dB at {over_db:+.0f} dB over")

    def test_light_clipping_is_where_the_gain_is(self):
        """Worth stating as a fact about the tool rather than a footnote: it
        helps most exactly where there is least to fix."""
        self.assertGreater(self.measure(1.0), self.measure(3.0))


class Merging(unittest.TestCase):
    """Runs a sample or two apart: one rippled flat top, or two peaks?"""

    @staticmethod
    def channel(gap_value: float) -> np.ndarray:
        wave_ = np.zeros(400)
        wave_[100:104] = 1.0
        wave_[104] = gap_value
        wave_[105:109] = 1.0
        return wave_

    def test_a_gap_at_the_ceiling_joins_the_runs(self):
        self.assertEqual(declip.find_runs(self.channel(0.9994)),
                         [(100, 109, 1)])

    def test_a_gap_that_carries_real_signal_does_not(self):
        """0.997 was never clipped, so it is the truth, and arcing over it
        would replace a measured value with a guess."""
        self.assertEqual(declip.find_runs(self.channel(0.997)),
                         [(100, 104, 1), (105, 109, 1)])

    def test_runs_of_opposite_sign_never_join(self):
        wave_ = self.channel(0.9994)
        wave_[105:109] = -1.0
        self.assertEqual(declip.find_runs(wave_),
                         [(100, 104, 1), (105, 109, -1)])

    def test_the_tolerance_is_a_hair_and_not_a_policy(self):
        """A couple of 16-bit steps. If this ever grows, re-run the table in
        _merge_near before believing it is an improvement."""
        self.assertLess(declip.MERGE_TOLERANCE, 8 / 32768)


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class ThroughTheCommand(unittest.TestCase):
    """That the module works proves nothing about whether the command reaches
    it, on the right audio, in the right order."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name) / "library"
        cls.root.mkdir(parents=True)
        wave_path = cls.root / "clipped.wav"
        with wave.open(str(wave_path), "wb") as handle:
            handle.setnchannels(2)
            handle.setsampwidth(2)
            handle.setframerate(RATE)
            _, clipped = clipped_at(3.0, seconds=20.0)
            handle.writeframes((clipped * 32767).astype("<i2").tobytes())
        # The gain command only ever works on MP3, so it gets its own folder.
        cls.mp3_root = Path(cls.tmp.name) / "mp3s"
        cls.mp3_root.mkdir()
        subprocess.run(
            ["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(wave_path),
             "-codec:a", "libmp3lame", "-b:a", "192k",
             str(cls.mp3_root / "clipped.mp3")], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_subbass(self, *extra: str) -> tuple[int, str, Path]:
        out_dir = Path(tempfile.mkdtemp(dir=self.tmp.name))
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = cli.main(["subbass", str(self.root), "--quiet",
                             "--db", str(Path(self.tmp.name) / "d.db"),
                             "--out", str(out_dir), *extra])
        return code, buffer.getvalue(), out_dir

    def test_declip_alone_is_enough_to_have_something_to_do(self):
        """With no sub and no punch the command normally declines to run, on
        the grounds that it would write identical files. De-clipping is work,
        so it has to lift that."""
        code, text, out_dir = self.run_subbass("--amount", "0", "--declip",
                                               "--no-compare")
        self.assertEqual(code, 0, text)
        self.assertIn("CLIPPING", text)
        self.assertIn("run(s) restored", text)
        self.assertEqual(len(list(out_dir.glob("*.flac"))), 1)

    def test_without_the_flag_it_still_declines(self):
        code, text, _ = self.run_subbass("--amount", "0")
        self.assertEqual(code, 0)
        self.assertIn("Nothing for subbass to do", text)

    def test_the_written_file_no_longer_clips(self):
        _, text, out_dir = self.run_subbass("--amount", "0", "--declip",
                                            "--no-compare")
        written, = out_dir.glob("*.flac")
        from loudnesslab import decode
        audio = decode.decode(written)
        self.assertEqual(bs1770.count_clipping(audio), (0, 0), text)

    def test_the_a_side_of_a_comparison_is_the_untouched_original(self):
        """A is what the listener has now, B is what the tool makes of it.
        Handing them the de-clipped audio as A would compare nothing."""
        _, text, out_dir = self.run_subbass("--amount", "0", "--declip")
        from loudnesslab import decode
        a, = out_dir.glob("* -- A original.flac")
        b, = out_dir.glob("* -- B *.flac")
        self.assertIn("declipped", b.name)

        def runs_at_full_scale(path: Path) -> int:
            # Both sides are level-matched downwards before writing, so
            # neither sits against the ceiling any more. Normalising each
            # back to unit peak asks the question that matters: is the FLAT
            # TOP still in the waveform?
            audio = decode.decode(path)
            return bs1770.count_clipping(audio / np.abs(audio).max())[1]

        self.assertGreater(runs_at_full_scale(a), 0,
                           "the A side is supposed to be the file as it is")
        self.assertLess(runs_at_full_scale(b), runs_at_full_scale(a) // 2)

    def test_the_gain_command_says_it_cannot_declip_rather_than_ignoring_it(self):
        profiles_file = Path(self.tmp.name) / "profiles.json"
        profiles_file.write_text('{"clipfix": {"declip": true}}')
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = cli.main(["gain", str(self.mp3_root), "--quiet",
                             "--db", str(Path(self.tmp.name) / "g.db"),
                             "--profiles", str(profiles_file),
                             "--profile", "clipfix"])
        self.assertEqual(code, 0)
        self.assertIn("cannot do", buffer.getvalue())


if __name__ == "__main__":
    unittest.main()
