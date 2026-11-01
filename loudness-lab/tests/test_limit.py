"""The peak limiter that lets levelling reach the target (limit.py)."""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from loudnesslab import bs1770, cli, limit, subbass  # noqa: E402

RATE = 48000
HAVE_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None


def peaky(seconds: float = 8.0, every_s: float = 0.5) -> np.ndarray:
    """A bed with a short, tall hit every `every_s`: an old master's shape,
    peaks standing ~14 dB over the loudness (the 1984 tracks: 12-15). The
    bed has to carry the loudness, as music does: at a third of this level
    the hits WERE the loudness, limiting them took it with them, and 6 dB
    was rightly not enough."""
    rng = np.random.default_rng(7)
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    bed = 0.12 * (np.sin(2 * np.pi * 220 * t) + 0.5 * rng.standard_normal(n))
    hit_n = int(0.006 * RATE)
    window = np.hanning(hit_n)
    # Bed and hit together stay under full scale: a FLAC fixture clips.
    hit = 0.6 * window * np.sin(2 * np.pi * 2000 * np.arange(hit_n) / RATE)
    x = bed.copy()
    for start in range(int(0.25 * RATE), n - hit_n, int(every_s * RATE)):
        x[start:start + hit_n] += hit
    return np.stack([x, x * 0.98], axis=1).astype(np.float32)


class TestTheCurve(unittest.TestCase):

    def test_peaks_are_held_to_the_ceiling(self):
        x = peaky() * np.float32(4.0)       # hits well over full scale
        ceiling = -1.0
        y, gain, report = limit.level(
            x, RATE, bs1770.measure(x)["lufs_i"],
            bs1770.measure(x)["lufs_i"], "lufs_i", ceiling, 20.0)
        self.assertLessEqual(bs1770.true_peak_dbtp(y), ceiling + 0.01)
        self.assertTrue(report["applied"])

    def test_away_from_the_hits_nothing_changes(self):
        """Only peaks move. Between the hits -- past the attack before one
        and well past the release after -- the audio is the audio."""
        x = peaky()
        peaks = limit.peaks_per_sample(x)
        # Over the bed's peaks (~-10 dBFS), under the hits'.
        curve = limit.gain_curve(peaks, RATE, 10 ** (-4 / 20))
        self.assertLess(curve.min(), 1.0)
        # Halfway between two hits is 250 ms from either: 12 releases.
        middle = int(0.5 * RATE)
        self.assertAlmostEqual(float(curve[middle]), 1.0, places=4)

    def test_the_gain_never_rises_above_what_a_peak_allows(self):
        x = peaky() * np.float32(3.0)
        peaks = limit.peaks_per_sample(x)
        ceiling = 10 ** (-1 / 20)
        curve = limit.gain_curve(peaks, RATE, ceiling)
        self.assertLessEqual(float((peaks * curve).max()), ceiling * 1.0001)
        self.assertLessEqual(float(curve.max()), 1.0)


class TestLevelling(unittest.TestCase):

    def setUp(self):
        self.x = peaky()
        m = bs1770.measure(self.x)
        self.value, self.peak = m["lufs_i"], m["true_peak_dbtp"]
        # A target 3 dB past where the -1 dBTP ceiling stops plain gain.
        self.target = self.value + (-1.0 - self.peak) + 3.0

    def test_it_reaches_the_target_when_the_cap_allows(self):
        y, gain, report = limit.level(self.x, RATE, self.value, self.target,
                                      "lufs_i", -1.0, 6.0)
        reached = bs1770.measure(y)
        self.assertLess(abs(reached["lufs_i"] - self.target), 0.1)
        self.assertLessEqual(reached["true_peak_dbtp"], -1.0 + 0.01)
        self.assertFalse(report["short_of_target"])

    def test_it_stops_short_rather_than_take_more_than_the_cap(self):
        y, gain, report = limit.level(self.x, RATE, self.value, self.target,
                                      "lufs_i", -1.0, 1.0)
        reached = bs1770.measure(y)
        self.assertTrue(report["short_of_target"])
        self.assertLess(reached["lufs_i"], self.target - 1.0)
        self.assertLessEqual(report["reduction_db"], 1.0 + 0.15)
        self.assertLessEqual(reached["true_peak_dbtp"], -1.0 + 0.01)

    def test_nothing_to_do_where_plain_gain_fits(self):
        quiet_target = self.value + (-1.0 - self.peak) - 1.0
        self.assertIsNone(limit.level(self.x, RATE, self.value, quiet_target,
                                      "lufs_i", -1.0, 6.0))

    def test_a_known_peak_that_fits_skips_the_peak_pass(self):
        quiet_target = self.value + (-1.0 - self.peak) - 1.0
        with unittest.mock.patch.object(limit, "peaks_per_sample",
                                        side_effect=AssertionError("worked out")):
            self.assertIsNone(limit.level(self.x, RATE, self.value, quiet_target,
                                          "lufs_i", -1.0, 6.0, peak_dbtp=self.peak))

    def test_a_known_peak_that_does_not_fit_still_limits(self):
        with_peak = limit.level(self.x, RATE, self.value, self.target,
                                "lufs_i", -1.0, 6.0, peak_dbtp=self.peak)
        without = limit.level(self.x, RATE, self.value, self.target,
                              "lufs_i", -1.0, 6.0)
        self.assertIsNotNone(with_peak)
        np.testing.assert_array_equal(with_peak[0], without[0])
        self.assertEqual(with_peak[1], without[1])

    def test_off_is_off(self):
        self.assertIsNone(limit.level(self.x, RATE, self.value, self.target,
                                      "lufs_i", -1.0, 0.0))


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class TestThroughTheCommand(unittest.TestCase):
    """The wiring: a profile's peak limit reaches the levelling, and 0
    leaves the ceiling in charge as it always was."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.src = self.dir / "src"
        self.src.mkdir(parents=True)
        x = peaky()
        subbass.write_flac(self.src / "old master.flac", x, RATE)
        m = bs1770.measure(x)
        self.target = m["lufs_i"] + (-1.0 - m["true_peak_dbtp"]) + 3.0

    def _run(self, peak_limit: str) -> tuple[dict, float]:
        out = self.dir / f"out{peak_limit}"
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = cli.main(["subbass", str(self.src), "--db",
                             str(self.dir / "l.db"), "--out", str(out),
                             "--amount", "0", "--no-compare", "--jobs", "1",
                             "--format", "flac", "--porcelain",
                             "--target", f"{self.target:.3f}",
                             "--estimator", "lufs_i", "--peak-ceiling", "-1",
                             "--peak-limit", peak_limit])
        self.assertEqual(code, 0, buffer.getvalue())
        events = [json.loads(line) for line in buffer.getvalue().splitlines()
                  if line.strip()]
        track = [e for e in events if e.get("phase") == "process"][-1]
        manifest = json.loads((out / "manifest.json").read_text())
        written = Path(manifest["tracks"][0]["variants"][0]["path"])
        from loudnesslab import decode
        return track, bs1770.measure(decode.decode(written))["lufs_i"]

    def test_the_limit_lets_it_land(self):
        track, reached = self._run("6")
        self.assertGreater(track["limit_db"], 2.0)
        self.assertLess(abs(reached - self.target), 0.15)

    def test_without_it_the_ceiling_wins(self):
        track, reached = self._run("0")
        self.assertIsNone(track["limit_db"])
        self.assertLess(reached, self.target - 2.5)


if __name__ == "__main__":
    unittest.main()
