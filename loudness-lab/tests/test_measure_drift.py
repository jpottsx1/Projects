"""tools/measure_drift.py: a live drummer's drift, read back.

The tracks are built with the drift put in by hand: a tempo curve (a few
percent over the song, or a step), every beat pushed or pulled 5-20 ms off
it, a kick on 1 and 3 and a snare on 2 and 4, eighth-note hats, a stop with
no drums (Sweet Caroline's "bah bah bah"), and optionally a stretch where
the kick is feathered too quietly for the kick detector. The TRUE stems are
used, through the shared cache's own copies (8 kHz drums, 2 kHz bass), so
what is tested is the measuring and not Demucs: how well Demucs separates
a 1960s drum kit is what the tool is for finding out.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from scipy.signal import butter, sosfilt

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools"))
from loudnesslab import stems  # noqa: E402
import measure_drift as md  # noqa: E402
import measure_stem_kicks as fx  # noqa: E402

RATE = md.RATE
assert fx.RATE == RATE

ROOTS = (45, 43, 41, 38)            # A2 G2 F2 D2, as MIDI notes


def drummer(bars: int = 40, bpm: float = 120.0, drift: float = 0.04,
            step_at: int | None = None, step: float = 0.0,
            push_ms: tuple[float, float] = (5.0, 20.0), stop=range(20, 22),
            feathered=range(0, 0), bleed_db: float | None = -20.0,
            tuning_cents: float = 30.0, seed: int = 1):
    """(mix, stems, truth). The tempo runs from `bpm` to bpm * (1 + drift)
    in a straight line over the song, or jumps by `step` at bar `step_at`.
    Every beat lands a random 5-20 ms early or late against that curve.
    `truth`: the curve's beat times (no push or pull), the beats as played,
    each bar's tempo, and the notes."""
    rng = np.random.default_rng(seed)
    beats = bars * 4
    tempo = bpm * (1 + drift * np.arange(beats) / beats)
    if step_at is not None:
        tempo = np.where(np.arange(beats) >= step_at * 4, bpm * (1 + step), bpm)
    lead = 1.0
    grid = lead + np.concatenate([[0.0], np.cumsum(60.0 / tempo)])   # beats + 1
    lo, hi = push_ms
    played = grid + rng.choice([-1, 1], grid.size) * rng.uniform(lo, hi, grid.size) / 1000
    if hi == 0:
        played = grid.copy()
    n = int((grid[-1] + 2.0) * RATE)
    drums, bass, other, vocals, hats = (np.zeros(n) for _ in range(5))
    stopped = set(stop)
    soft = set(feathered)
    for i in range(beats):
        bar, beat = divmod(i, 4)
        if bar in stopped:
            continue
        t = played[i]
        if beat in (0, 2):
            gain = 0.04 if bar in soft else 0.9
            fx._place(drums, t, fx._kick(int(0.3 * RATE), rng) * gain)
        else:
            fx._place(drums, t, fx._snare(int(0.25 * RATE), rng) * 0.5)
        fx._place(hats, (grid[i] + grid[i + 1]) / 2, fx._hat(int(0.08 * RATE), rng) * 0.25)
        fx._place(hats, t, fx._hat(int(0.08 * RATE), rng) * 0.2)
    drums += hats
    notes = []
    for bar in range(bars):
        note = ROOTS[bar % len(ROOTS)]
        notes.append(note)
        if bar in stopped:
            continue
        start, end = played[bar * 4], played[bar * 4 + 4]
        hz = 440.0 * 2 ** ((note - 69 + tuning_cents / 100) / 12)
        length = int((end - start) * RATE) - int(0.02 * RATE)
        d = np.arange(length) / RATE
        tone = sum(np.sin(2 * np.pi * hz * k * d) / k for k in (1, 2, 3))
        # Plucked: it dies away over the bar, so the bar's first beat
        # carries the most low end, as on a record.
        env = (np.minimum(1.0, d / 0.01) * np.minimum(1.0, (length / RATE - d) / 0.02)
               * np.exp(-d * 0.8))
        fx._place(bass, start, 0.4 * tone * env)
    other += sosfilt(butter(4, [300, 3500], btype="band", fs=RATE, output="sos"),
                     rng.standard_normal(n)) * 0.03
    if bleed_db is not None:
        other += hats * 10 ** (bleed_db / 20)
    t = np.arange(n) / RATE
    vocals += 0.1 * np.sin(2 * np.pi * 330 * t) * (0.6 + 0.4 * np.sin(2 * np.pi * 0.2 * t))
    mix = drums + bass + other + vocals
    scale = 0.8 / np.abs(mix).max()

    def stereo(y):
        return np.stack([y, y], axis=1).astype(np.float32) * scale

    parts = {"drums": stereo(drums), "bass": stereo(bass),
             "other": stereo(other), "vocals": stereo(vocals)}
    bar_bpm = np.array([240.0 / (grid[4 * k + 4] - grid[4 * k]) for k in range(bars)])
    return stereo(mix), parts, {"grid": grid * RATE, "played": played * RATE,
                                "bar_bpm": bar_bpm, "notes": notes, "stop": stop}


def through_the_cache(x, parts):
    """The parts as the tool reads them from the shared cache."""
    with tempfile.TemporaryDirectory() as cache:
        stems.store_kick_source(Path(cache), x, RATE, parts["drums"],
                                [parts["vocals"], parts["other"]], bass=parts["bass"])
        stems.keep_extra(Path(cache), x, md.bleed_envelopes(parts, RATE))
        return {**stems.load_report_parts(Path(cache), x, RATE),
                **stems.load_extra(Path(cache), x, md.BLEED_KEYS)}


def measured(**kw):
    x, parts, truth = drummer(**kw)
    return md.measure(x, through_the_cache(x, parts), RATE, tag=kw.get("bpm", 120.0)), truth


def bar_of(r, truth, k):
    """The measured bar index whose bar line is truth's bar k."""
    target = truth["played"][4 * k]
    return int(np.argmin(np.abs(r["bar_lines"] - target)))


def beat_errors_ms(r, truth):
    """Each found beat against the beat as played nearest it, in ms."""
    played = truth["played"]
    at = r["beats"][r["found"]]
    nearest = played[np.argmin(np.abs(played[None, :] - at[:, None]), axis=1)]
    return (at - nearest) / RATE * 1000


class TestADriftingDrummer(unittest.TestCase):
    """4% faster over 40 bars, every beat 5-20 ms off, a two-bar stop."""

    @classmethod
    def setUpClass(cls):
        cls.r, cls.truth = measured()

    def test_every_found_beat_is_on_the_beat_as_played(self):
        err = beat_errors_ms(self.r, self.truth)
        self.assertLess(np.median(np.abs(err)), 2.0)
        self.assertLess(np.max(np.abs(err)), 6.0)

    def test_every_beat_the_drummer_played_is_found(self):
        played = self.truth["played"][:-1]
        playing = np.array([i // 4 not in self.truth["stop"] for i in range(played.size)])
        found = self.r["beats"][self.r["found"]]
        missed = [i for i in np.nonzero(playing)[0]
                  if np.min(np.abs(found - played[i])) > 0.01 * RATE]
        self.assertLessEqual(len(missed), 1, missed)

    def test_the_bars_line_up_with_the_song(self):
        # Every measured bar line within 25 ms of a bar's first beat as played.
        played = self.truth["played"][0::4]
        for line, ok in zip(self.r["bar_lines"], self.r["lines_found"]):
            if ok:
                self.assertLess(np.min(np.abs(played - line)) / RATE * 1000, 6.0)

    def test_the_tempo_curve_is_recovered_bar_by_bar(self):
        errors = []
        for k in range(len(self.truth["bar_bpm"])):
            i = bar_of(self.r, self.truth, k)
            if i < self.r["per_bar"].size and np.isfinite(self.r["per_bar"][i]):
                errors.append(self.r["per_bar"][i] / self.truth["bar_bpm"][k] - 1)
        errors = np.array(errors) * 100
        self.assertGreater(errors.size, 30)
        self.assertLess(np.sqrt(np.mean(errors ** 2)), 0.6)
        self.assertLess(np.max(np.abs(errors)), 1.5)

    def test_the_drift_is_read_from_start_to_end(self):
        # The curve put in, read the same way: every beat on its grid time.
        grid = self.truth["grid"]
        playing = np.array([i // 4 not in self.truth["stop"] for i in range(grid.size)])
        curve = md.tempo_curve(grid, playing, 0, RATE, md.SMOOTH_BARS)
        self.assertAlmostEqual(self.r["start_bpm"], curve[0], delta=0.4)
        self.assertAlmostEqual(self.r["end_bpm"], np.nanmax(curve), delta=0.4)
        spread = (np.nanmax(curve) - np.nanmin(curve)) / np.nanmedian(curve) * 100
        self.assertGreater(spread, 2.5)
        self.assertAlmostEqual(self.r["spread_pct"], spread, delta=0.4)

    def test_the_push_and_pull_is_measured(self):
        # Against the same line through the beats as played, the 5-20 ms
        # each beat was put off by reads as itself, near enough.
        truth = md.push_pull_ms(self.truth["played"], np.ones(self.truth["played"].size, bool), RATE)
        self.assertAlmostEqual(self.r["push_pull_median_ms"], np.nanmedian(np.abs(truth)), delta=2.0)
        self.assertGreater(self.r["push_pull_median_ms"], 8.0)

    def test_the_stop_is_the_longest_stretch_without_lock(self):
        beats = self.r["longest_unlocked_beats"]
        self.assertGreaterEqual(beats, 7)
        self.assertLessEqual(beats, 9)
        stop_starts = self.truth["played"][4 * self.truth["stop"][0]]
        self.assertLess(abs(self.r["longest_unlocked_at"] - stop_starts) / RATE, 0.6)

    def test_the_kick_and_snare_hold_the_beat(self):
        s = self.r["shares"]
        self.assertGreater(s["kick"], 0.4)
        self.assertGreater(s["snare"], 0.35)
        self.assertEqual(md.held_verdict(self.r), "kick and snare between them held")

    def test_the_first_beat_is_placed_as_every_other(self):
        # On its attack (`attack`), not on the detector's onset ~5 ms out.
        self.assertLess(abs(self.r["beats"][0] - self.truth["played"][0]) / RATE * 1000, 1.5)

    def test_the_snare_alone_holds_only_its_own_beats(self):
        # 2 and 4: the kick's click in the snare's band is not a snare.
        self.assertLess(self.r["alone"]["snare"], 0.5)

    def test_the_report_says_it(self):
        text = md.describe(self.r, "drummer.wav")
        for words in ("tempo:", "lock:", "held by:", "drum bleed", "bass:"):
            self.assertIn(words, text)


class TestALateStop(unittest.TestCase):
    def test_the_bars_around_it_read_the_drummer_not_the_carried_grid(self):
        # Late in a 4% drift the drummer is 1% off the song's mean tempo; the
        # beats carried across the stop are at the mean, and a bar read
        # from them as well as the played ones was 0.8-0.9% out.
        r, truth = measured(stop=range(30, 32))
        for k in range(len(truth["bar_bpm"])):
            i = bar_of(r, truth, k)
            if i < r["per_bar"].size and np.isfinite(r["per_bar"][i]):
                self.assertLess(abs(r["per_bar"][i] / truth["bar_bpm"][k] - 1) * 100, 0.6, f"bar {k}")


class TestPushAndPull(unittest.TestCase):
    def test_one_beat_twenty_ms_late_reads_twenty_ms(self):
        beats = 1000.0 + np.arange(17) * 24000.0
        beats[8] += 0.020 * RATE
        found = np.ones(beats.size, dtype=bool)
        got = md.push_pull_ms(beats, found, RATE)
        self.assertAlmostEqual(got[8], 20.0, delta=0.1)
        self.assertLess(abs(got[4]), 3.0)


class TestASteadyMachine(unittest.TestCase):
    def test_no_drift_and_no_push_reads_as_none(self):
        r, _ = measured(drift=0.0, push_ms=(0.0, 0.0), stop=range(0, 0), bars=24)
        self.assertLess(r["spread_pct"], 0.2)
        self.assertLess(r["largest_step_pct"], 0.2)
        self.assertLess(r["push_pull_median_ms"], 0.5)
        self.assertEqual(r["longest_unlocked_beats"], 0)


class TestATempoStep(unittest.TestCase):
    def test_a_sudden_three_percent_jump_is_where_it_happened(self):
        r, truth = measured(drift=0.0, step_at=16, step=0.03, stop=range(0, 0),
                            push_ms=(2.0, 5.0), bars=32)
        self.assertGreater(r["largest_step_pct"], 1.0)
        at = bar_of(r, truth, 16)
        self.assertLessEqual(abs(r["largest_step_bar"] - at), 1)
        self.assertAlmostEqual(r["max_bpm"] / r["min_bpm"], 1.03, delta=0.006)


class TestAFeatheredKick(unittest.TestCase):
    """Bars 8-19 the kick is 27 dB down: under the kick detector's gate."""

    @classmethod
    def setUpClass(cls):
        cls.r, cls.truth = measured(feathered=range(8, 20), stop=range(0, 0), bars=32)

    def beats_in(self, bars):
        lo = self.truth["played"][4 * bars.start] - 0.1 * RATE
        hi = self.truth["played"][4 * bars.stop] - 0.1 * RATE
        return (self.r["beats"] >= lo) & (self.r["beats"] < hi)

    def test_the_kick_loses_the_beat_there(self):
        held = self.r["held"][self.beats_in(range(8, 20))]
        self.assertLess(np.mean(held == 0), 0.1)

    def test_the_snare_holds_its_beats_there(self):
        held = self.r["held"][self.beats_in(range(8, 20))]
        self.assertGreater(np.mean(held == 1), 0.4)

    def test_the_beats_stay_on_the_drummer(self):
        err = beat_errors_ms(self.r, self.truth)
        self.assertLess(np.max(np.abs(err)), 6.0)
        after = self.r["held"][self.beats_in(range(22, 30))]
        self.assertGreater(np.mean(after == 0), 0.45)

    def test_the_kick_alone_would_not_have_held(self):
        self.assertLess(self.r["alone"]["kick"], 0.45)
        self.assertNotEqual(md.held_verdict(self.r), "the kick held")


class TestBleed(unittest.TestCase):
    """The hats copied into "other" at -20 and -10 dB, over a steady noise
    pad that has transients of its own by the harmonic/percussive split."""

    @classmethod
    def setUpClass(cls):
        cls.with_bleed, _ = measured(bars=16, stop=range(0, 0), bleed_db=-20.0)
        cls.louder, _ = measured(bars=16, stop=range(0, 0), bleed_db=-10.0)
        cls.clean, _ = measured(bars=16, stop=range(0, 0), bleed_db=None)

    def test_cymbals_in_other_are_found_and_sit_on_the_hits(self):
        b = self.with_bleed["bleed"]["other"]
        self.assertIsNotNone(b["db"])
        self.assertGreater(b["on_hits"], b["chance"])

    def test_ten_db_more_bleed_reads_ten_db_more(self):
        self.assertAlmostEqual(self.louder["bleed"]["other"]["db"]
                               - self.with_bleed["bleed"]["other"]["db"], 10.0, delta=1.5)

    def test_without_them_other_reads_far_lower(self):
        clean = self.clean["bleed"]["other"]["db"]
        self.assertTrue(clean is None or clean < self.with_bleed["bleed"]["other"]["db"] - 10,
                        clean)

    def test_a_vocal_with_no_drums_in_it_is_not_on_the_hits(self):
        v = self.with_bleed["bleed"]["vocals"]
        self.assertLess(v["db"] if v["db"] is not None else -99, -30)


class TestTheDownbeat(unittest.TestCase):
    def test_the_bar_starts_where_the_bass_note_does(self):
        r, truth = measured(feathered=range(8, 20), stop=range(0, 0), bars=32)
        bar_one = truth["played"][0::4]
        for line in r["bar_lines"][:-1]:
            self.assertLess(np.min(np.abs(bar_one - line)) / RATE, 0.05)


class TestTheBassline(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.r, cls.truth = measured(bars=24, stop=range(0, 0), tuning_cents=30.0)

    def test_the_record_is_heard_thirty_cents_sharp(self):
        self.assertAlmostEqual(self.r["bass"]["tuning_cents"], 30.0, delta=5.0)

    def test_each_bar_has_its_one_note(self):
        b = self.r["bass"]
        right = 0
        for k, note in enumerate(self.truth["notes"][:-1]):
            i = bar_of(self.r, self.truth, k)
            if i < len(b["notes"]) and b["notes"][i] == [note]:
                right += 1
        self.assertGreaterEqual(right, 0.9 * (len(self.truth["notes"]) - 1))
        self.assertGreater(b["clear"], 0.85)
        self.assertEqual(b["notes_median"], 1.0)
        self.assertLess(b["flicker"], 0.05)


class TestTempoFromTheOnsets(unittest.TestCase):
    def test_no_tag_and_a_half_tag_both_find_the_beat(self):
        x, parts, _ = drummer(bars=16, stop=range(0, 0), drift=0.0)
        p = through_the_cache(x, parts)
        for tag in (None, 60.0):
            r = md.measure(x, p, RATE, tag=tag)
            self.assertAlmostEqual(r["hint"], 120.0, delta=1.5, msg=str(tag))
            self.assertAlmostEqual(r["start_bpm"], 120.0, delta=0.6, msg=str(tag))


class TestTheCache(unittest.TestCase):
    def test_extras_are_added_beside_what_was_kept(self):
        x = np.random.default_rng(0).standard_normal((RATE, 2)).astype(np.float32) * 0.1
        with tempfile.TemporaryDirectory() as cache:
            stems.store_kick_source(Path(cache), x, RATE, x, bass=x)
            self.assertIsNone(stems.load_extra(Path(cache), x, md.BLEED_KEYS))
            stems.keep_extra(Path(cache), x, {k: np.ones(3, np.float32) for k in md.BLEED_KEYS})
            self.assertIsNotNone(stems.load_report_parts(Path(cache), x, RATE))
            kept = stems.load_extra(Path(cache), x, md.BLEED_KEYS)
            self.assertEqual(sorted(kept), sorted(md.BLEED_KEYS))


if __name__ == "__main__":
    unittest.main()
