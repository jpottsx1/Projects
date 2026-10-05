"""Intro edits.

The tracks here are built from known stems: kicks on a grid, a bass that
accents the first beat of each bar, a vocal that is a pure 880 Hz tone so
it can be found by frequency alone, and a breakdown with no drums. Using
the TRUE stems pins what the intro code does with a separation; how good
Demucs's separation is on a real record is measured by the separation
speed test, not asserted here.
"""

from __future__ import annotations

import contextlib
import io
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import numpy as np
from scipy.signal import butter, sosfilt

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools"))
from loudnesslab import cli, decode, intro, subbass, write  # noqa: E402
import measure_stem_kicks as fx  # noqa: E402

RATE = fx.RATE
BPM = 120.0
BEAT = 60.0 / BPM
BAR = 4 * BEAT


def song(bars: int = 36, pickup_beats: int = 0, vocal_bars=(range(0, 8), range(16, 24)),
         breakdown=range(28, 32), accent: bool = True, seed: int = 0,
         restless=range(0, 0), soft_bars=range(0, 0), lead_in_vocal_beats: int = 0,
         fill_bars=(), busy_bars=()):
    """`soft_bars`: an opening of the song's own, with no drums, no bass and
    no vocal, only the quiet pad: the part an intro edit cuts out.
    `lead_in_vocal_beats`: a sustained vocal over the last N beats of the
    soft opening, running into the drop.
    `fill_bars`: bars ending in the SAME roll of sixteenth snares every time,
    like a phrase-end fill: it repeats exactly, so only a measure of how a bar
    differs from its neighbours can tell it from the groove.
    `busy_bars`: the same groove with sixteenth-note hats added, at about the
    same level: a different feel, not a different loudness."""
    # (original, stems, join in seconds). Bar 0 starts at `pickup_beats`
    # beats in: before it, only a vocal pickup.
    rng = np.random.default_rng(seed)
    lead = pickup_beats * BEAT
    n = int((lead + bars * BAR + 2.0) * RATE)
    drums, bass, other, vocals = (np.zeros(n) for _ in range(4))
    quiet = {b for b in breakdown}
    voiced = {b for r in vocal_bars for b in r}
    soft = set(soft_bars)
    for bar in range(bars):
        for beat in range(4):
            t = lead + bar * BAR + beat * BEAT
            if bar in soft:
                if (bar == max(soft) and beat >= 4 - lead_in_vocal_beats):
                    d = np.arange(int(BEAT * RATE)) / RATE
                    fx._place(vocals, t, 0.25 * np.sin(2 * np.pi * 880 * d))
                continue
            if bar not in quiet:
                fx._place(drums, t, fx._kick(int(0.3 * RATE), rng) * 0.9)
                fx._place(drums, t + BEAT / 2, fx._hat(int(0.08 * RATE), rng) * 0.25)
                gain = 0.7 if (beat == 0 or not accent) else 0.3
                fx._place(bass, t, gain * fx._pluck(int(BEAT * RATE), 55.0, 0.25))
            if bar in busy_bars:
                fx._place(drums, t + BEAT / 4, fx._hat(int(0.05 * RATE), rng) * 0.25)
                fx._place(drums, t + 3 * BEAT / 4, fx._hat(int(0.05 * RATE), rng) * 0.25)
            if bar in fill_bars and beat >= 2:
                for k in range(4):
                    fx._place(drums, t + k * BEAT / 4, fx._snare(int(0.1 * RATE), rng) * 0.6)
            if bar in restless:
                # A fill that never repeats: a different scatter of snares
                # every bar, so no bar looks like the one four on.
                for _ in range(5):
                    fx._place(drums, t + rng.uniform(0, BEAT),
                              fx._snare(int(0.2 * RATE), rng) * 0.5)
            if bar in voiced:
                d = np.arange(int(0.3 * RATE)) / RATE
                fx._place(vocals, t, 0.25 * np.sin(2 * np.pi * 880 * d) * np.exp(-d * 6))
    if pickup_beats:
        d = np.arange(int(0.3 * RATE)) / RATE
        fx._place(vocals, 0.0, 0.25 * np.sin(2 * np.pi * 880 * d) * np.exp(-d * 6))
    other += sosfilt(butter(4, [300, 3500], btype="band", fs=RATE, output="sos"),
                     rng.standard_normal(n)) * 0.04
    mix = drums + bass + other + vocals
    scale = 0.8 / np.abs(mix).max()

    def stereo(y):
        return np.stack([y, y], axis=1).astype(np.float32) * scale

    parts = {"drums": stereo(drums), "bass": stereo(bass),
             "other": stereo(other), "vocals": stereo(vocals)}
    return stereo(mix), parts, lead


def tone_power(y: np.ndarray, hz: float = 880.0) -> float:
    """Power in a narrow band round `hz`: the vocal, and little else."""
    band = sosfilt(butter(4, [hz - 12, hz + 12], btype="band", fs=RATE, output="sos"),
                   y.mean(axis=1))
    return float(np.mean(band ** 2))


class TestTheGrid(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.x, cls.parts, cls.lead = song()
        cls.kicks, cls.strengths = subbass.detect_kicks(cls.x, RATE, cls.parts["drums"])

    def test_the_tempo_is_read_back_from_the_kicks_not_the_tag(self):
        # Tagged 1% fast, as a rounded tag can be.
        period, first, coherence = intro.fit_grid(self.kicks, self.strengths, RATE, 121.0)
        self.assertAlmostEqual(60.0 * RATE / period, 120.0, delta=0.05)
        self.assertGreater(coherence, 0.9)

    def test_the_first_beat_is_where_the_first_kick_is(self):
        period, first, _ = intro.fit_grid(self.kicks, self.strengths, RATE, BPM)
        off = ((first - self.lead * RATE) / period + 0.5) % 1.0 - 0.5
        self.assertLess(abs(off) * BEAT, 0.006)

    def test_too_few_kicks_is_no_grid(self):
        self.assertIsNone(intro.fit_grid(self.kicks[:4], self.strengths[:4], RATE, BPM))


class TestTheJoin(unittest.TestCase):
    def test_a_track_that_starts_cold_joins_at_its_first_beat(self):
        x, parts, _ = song()
        a = intro.analyse(x, parts, RATE, BPM)
        self.assertLess(abs(a.join / RATE), 0.01)
        self.assertEqual(a.pickup, 0)

    def test_the_accents_find_the_bar_when_the_start_is_not_the_one(self):
        # Bar 0 begins two beats in, behind a two-beat vocal lead. The
        # song's own start is on beat 3 of a bar; the bass accent says so.
        x, parts, lead = song(pickup_beats=2)
        a = intro.analyse(x, parts, RATE, BPM)
        self.assertAlmostEqual(a.join / RATE, lead, delta=0.01)
        self.assertAlmostEqual(a.pickup / RATE, lead, delta=0.01)
        self.assertGreater(a.grid.confidence, intro.DOWNBEAT_CONFIDENCE)

    def test_even_accents_fall_back_to_the_song_start(self):
        x, parts, _ = song(accent=False)
        a = intro.analyse(x, parts, RATE, BPM)
        self.assertLess(abs(a.join / RATE), 0.01)
        self.assertIn("start", a.grid.how)
        self.assertTrue(any("guess" in w for w in a.warnings))

    def test_a_given_bar_line_overrides_the_search(self):
        x, parts, lead = song(pickup_beats=2)
        a = intro.analyse(x, parts, RATE, BPM, downbeat_s=lead)
        self.assertAlmostEqual(a.join / RATE, lead, delta=0.01)
        self.assertEqual(a.grid.how, "the beat grid you gave")

    def test_no_tempo_is_an_error_that_says_what_to_do(self):
        x, parts, _ = song()
        with self.assertRaisesRegex(ValueError, "--bpm"):
            intro.analyse(x, parts, RATE, None)


class TestWhereTheSongArrives(unittest.TestCase):
    """The song's own opening is cut out and the intro takes its place, so
    where the song joins matters: at the first bar where the groove lands."""

    @classmethod
    def setUpClass(cls):
        cls.x, cls.parts, _ = song(soft_bars=range(0, 8), vocal_bars=(range(8, 16),),
                                   lead_in_vocal_beats=2)
        cls.a = intro.analyse(cls.x, cls.parts, RATE, BPM)

    def test_a_soft_opening_joins_where_the_drums_come_in(self):
        self.assertEqual(self.a.suggested_join_bar, 8)
        join, _ = intro.resolve_join(self.a, 8)
        self.assertAlmostEqual(join / RATE, 8 * BAR, delta=0.02)
        self.assertIn("drums come in", self.a.join_reason)

    def test_a_vocal_swelling_into_the_drop_does_not_move_it_a_bar_early(self):
        # The first version read the whole mix, and the vocal over the last
        # two beats of bar 7 made bar 7 look like the arrival.
        self.assertNotEqual(self.a.suggested_join_bar, 7)

    def test_a_track_that_starts_at_full_level_joins_at_its_first_bar(self):
        x, parts, _ = song()
        a = intro.analyse(x, parts, RATE, BPM)
        self.assertEqual(a.suggested_join_bar, 0)
        self.assertIn("starts at full level", a.join_reason)

    def test_a_vocal_leading_into_the_drop_is_kept(self):
        _, pickup = intro.resolve_join(self.a, 8)
        self.assertAlmostEqual(pickup / self.a.grid.period, 2.0, delta=0.05)

    def test_no_vocal_before_the_drop_keeps_nothing(self):
        x, parts, _ = song(soft_bars=range(0, 8), vocal_bars=(range(8, 16),))
        a = intro.analyse(x, parts, RATE, BPM)
        self.assertEqual(intro.resolve_join(a, 8)[1], 0)

    def test_a_join_outside_the_track_is_refused(self):
        for bad in (-1, len(self.a.bar_lines) - 1, 10 ** 6):
            with self.assertRaisesRegex(ValueError, "outside the track"):
                intro.resolve_join(self.a, bad)

    def test_the_opening_is_cut_out_of_the_file(self):
        source = intro.candidates(self.a, 4)[0]
        cut, info = intro.render(self.a, 16, source)                  # suggested: bar 8
        whole, whole_info = intro.render(self.a, 16, source, join_bar=0)   # keep the opening
        join, pickup = intro.resolve_join(self.a, 8)
        # Same intro, so the files differ by exactly the bars between the
        # first bar and the join: the opening that was cut out. (The lead-in
        # kept ahead of the join changes where the original takes over, not
        # how long the file is.)
        # (Each intro is made to the tempo of the bars the song arrives with,
        # which differ by a few samples between the two joins; that is in
        # `intro_samples`.)
        self.assertEqual(len(whole) - len(cut),
                         join - self.a.join + whole_info["intro_samples"] - info["intro_samples"])
        self.assertAlmostEqual((join - self.a.join) / RATE, 8 * BAR, delta=0.02)
        self.assertEqual(info["join_bar"], 8)
        self.assertEqual(info["suggested_join_bar"], 8)
        self.assertAlmostEqual(info["cut_seconds"], (join - pickup) / RATE, delta=0.001)

    def test_the_song_arrives_untouched_at_the_join(self):
        source = intro.candidates(self.a, 4)[0]
        audio, info = intro.render(self.a, 16, source)
        join, _ = intro.resolve_join(self.a, 8)
        join_out = info["intro_samples"] + round(info["lead_seconds"] * RATE)
        np.testing.assert_allclose(audio[join_out + 2000:], self.x[join + 2000:], atol=1e-6)

    def test_the_intro_has_the_groove_where_the_original_had_a_pad(self):
        source = intro.candidates(self.a, 4)[0]
        audio, _ = intro.render(self.a, 8, source)

        def low(y):
            band = sosfilt(butter(2, 150, btype="low", fs=RATE, output="sos"), y.mean(axis=1))
            return float(np.sqrt(np.mean(band ** 2)))

        opening = self.x[:2 * RATE]                      # the original's pad
        self.assertGreater(low(audio[RATE:3 * RATE]), 10 * max(low(opening), 1e-9))

    def test_a_chosen_bar_overrides_the_suggestion(self):
        source = intro.candidates(self.a, 4)[0]
        _, info = intro.render(self.a, 8, source, join_bar=12)
        self.assertEqual(info["join_bar"], 12)
        self.assertEqual(info["suggested_join_bar"], 8)
        self.assertAlmostEqual(info["join_seconds"], 12 * BAR, delta=0.02)

    def test_a_render_with_a_bad_join_is_refused(self):
        source = intro.candidates(self.a, 4)[0]
        with self.assertRaisesRegex(ValueError, "outside the track"):
            intro.render(self.a, 8, source, join_bar=10 ** 6)


class TestThePickerEnvelope(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        x, parts, _ = song(soft_bars=range(0, 8), vocal_bars=(range(8, 16),))
        cls.a = intro.analyse(x, parts, RATE, BPM)
        cls.env = intro.envelope(cls.a)

    def test_it_covers_the_track_at_the_stated_rate(self):
        per = self.env["per_second"]
        self.assertAlmostEqual(per, 50, delta=0.5)
        for band in ("bass", "mid", "treble"):
            self.assertAlmostEqual(len(self.env[band]), self.env["seconds"] * per, delta=2)

    def test_it_is_plain_json_in_range(self):
        import json
        json.dumps(self.env)
        for band in ("bass", "mid", "treble"):
            values = self.env[band]
            self.assertTrue(all(isinstance(v, int) and 0 <= v <= 255 for v in values))

    def test_the_opening_is_visibly_quieter_than_the_groove(self):
        per = self.env["per_second"]
        bass = np.array(self.env["bass"], dtype=float)
        opening = bass[int(1 * per):int(14 * per)].mean()
        groove = bass[int(18 * per):int(30 * per)].mean()
        self.assertGreater(groove, 3 * max(opening, 1.0))


class TestChoosingTheLoop(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        x, parts, _ = song()
        cls.a = intro.analyse(x, parts, RATE, BPM)

    def test_the_best_source_has_no_vocal_in_it(self):
        best = intro.candidates(self.a, 4)[0]
        self.assertTrue(best.vocal_free)
        # Vocals are in bars 0-7 and 16-23.
        bars = set(range(best.bar, best.bar + 4))
        self.assertFalse(bars & (set(range(0, 8)) | set(range(16, 24))), best)

    def test_a_breakdown_is_not_a_loop_source_for_having_no_vocal(self):
        for s in intro.candidates(self.a, 4):
            self.assertFalse(set(range(s.bar, s.bar + 4)) & set(range(28, 32)), s)

    def test_candidates_do_not_overlap(self):
        found = intro.candidates(self.a, 4, count=5)
        bars = sorted(s.bar for s in found)
        for early, late in zip(bars, bars[1:]):
            self.assertGreaterEqual(late - early, 4)

    def test_a_stretch_that_does_not_repeat_loses_to_one_that_does(self):
        # Bars 8-15 have no vocal and a full groove, but a different fill
        # every bar; 24-39 are the same groove again and again. Without the
        # repeat score the fills win on level alone.
        x, parts, _ = song(bars=48, breakdown=range(40, 44), restless=range(8, 16))
        a = intro.analyse(x, parts, RATE, BPM)
        best = intro.candidates(a, 4)[0]
        self.assertGreater(best.repeat, 0.9, best)
        self.assertFalse(set(range(best.bar, best.bar + 4)) & set(range(8, 16)), best)

    def test_the_ranking_trades_a_little_vocal_for_a_loop_that_repeats(self):
        def source(vocal, repeat):
            return intro.Source(bar=0, start=0, vocal_db=vocal, level_db=0.0,
                                drums_db=0.0, vocal_free=vocal <= -20,
                                repeat=repeat)
        silent_fill = source(-120.0, 0.4)       # no vocal, never comes round
        faint_groove = source(-25.0, 1.0)       # a breath of vocal, repeats
        self.assertLess(intro.cost(faint_groove), intro.cost(silent_fill))
        # ...and that is the repeat term's doing, not an accident of scale.
        with mock.patch.object(intro, "REPEAT_WEIGHT", 0.0):
            self.assertGreater(intro.cost(faint_groove), intro.cost(silent_fill))

    def test_a_vocal_stem_that_is_exactly_silent_is_not_infinitely_good(self):
        clean = intro.Source(bar=0, start=0, vocal_db=-120.0, level_db=0.0,
                             drums_db=0.0, vocal_free=True)
        leaky = intro.Source(bar=0, start=0, vocal_db=-45.0, level_db=0.0,
                             drums_db=0.0, vocal_free=True)
        self.assertEqual(intro.cost(clean), intro.cost(leaky))

    def test_a_track_all_vocal_still_offers_one_and_flags_it(self):
        x, parts, _ = song(vocal_bars=(range(0, 36),))
        a = intro.analyse(x, parts, RATE, BPM)
        best = intro.candidates(a, 4)[0]
        self.assertFalse(best.vocal_free)

    def test_a_hand_picked_bar_is_honoured(self):
        s = intro.source_at(self.a, 9, 4)
        self.assertEqual(s.bar, 9)
        self.assertEqual(s.start, int(self.a.bar_lines[9]))

    def test_a_hand_picked_bar_is_measured_even_if_it_would_not_have_ranked(self):
        # Bars 2-5 are vocal bars, nowhere near the best four: it still
        # reports what is in them, so the person choosing it is told.
        s = intro.source_at(self.a, 2, 4)
        self.assertFalse(np.isnan(s.vocal_db))
        self.assertGreater(s.vocal_db, intro.VOCAL_FREE_DB)
        self.assertFalse(s.vocal_free)
        self.assertGreater(s.length, 0)

    def test_a_pick_past_the_end_is_refused(self):
        with self.assertRaisesRegex(ValueError, "past the end"):
            intro.source_at(self.a, 40, 4)

    def test_a_loop_length_that_is_not_offered_is_refused(self):
        with self.assertRaises(ValueError):
            intro.candidates(self.a, 3)


class TestAFillIsNotALoop(unittest.TestCase):
    """A phrase-end fill in the loop is heard on every repeat, and the last
    one runs straight into the song. It repeats exactly, so the repeat score
    cannot see it; the deviation from the bars around it can."""

    @classmethod
    def setUpClass(cls):
        fills = tuple(range(3, 40, 4))
        x, parts, _ = song(bars=44, vocal_bars=(range(0, 2),), breakdown=range(0, 0),
                           fill_bars=fills)
        cls.a = intro.analyse(x, parts, RATE, BPM)
        cls.fills = fills
        x, parts, _ = song(bars=44, vocal_bars=(range(0, 2),), breakdown=range(0, 0))
        cls.plain = intro.analyse(x, parts, RATE, BPM)

    def test_a_fill_bar_stands_out_from_the_groove(self):
        dev = intro.bar_deviation(self.a)
        fill = np.mean([dev[b] for b in self.fills[1:-1]])
        groove = np.median(dev)
        self.assertGreater(fill, 0.5)
        self.assertLess(groove, 0.2)

    def test_a_plain_groove_has_no_fill_anywhere(self):
        self.assertLess(np.percentile(intro.bar_deviation(self.plain), 90), intro.FILL_OK)

    def test_a_two_bar_loop_is_taken_from_between_the_fills(self):
        best = intro.candidates(self.a, 2)[0]
        self.assertLess(best.fill, intro.FILL_OK, best)
        self.assertFalse({best.bar, best.bar + 1} & set(self.fills), best)

    def test_a_fill_costs_a_loop_its_place_in_the_ranking(self):
        plain = intro.Source(bar=0, start=0, vocal_db=-20.0, level_db=0.0, drums_db=0.0,
                             vocal_free=True, fill=0.1)
        filled = intro.Source(bar=0, start=0, vocal_db=-20.0, level_db=0.0, drums_db=0.0,
                              vocal_free=True, fill=0.9)
        self.assertGreater(intro.cost(filled), intro.cost(plain) + 10)
        # and a loop under the threshold pays nothing
        slight = intro.Source(bar=0, start=0, vocal_db=-20.0, level_db=0.0, drums_db=0.0,
                              vocal_free=True, fill=intro.FILL_OK)
        self.assertEqual(intro.cost(slight), intro.cost(plain))

    def test_a_loop_holding_a_fill_is_called_out_in_the_source_fields(self):
        source = intro.source_at(self.a, 2, 4)           # bars 2-5 hold fills at 3
        self.assertGreater(source.fill, intro.FILL_NOTED)
        self.assertGreater(intro.source_fields(source)["fill"], intro.FILL_NOTED)


class TestSoundingLikeTheSong(unittest.TestCase):
    """The intro is chosen to sound like the bars the song arrives with, not
    like the song's typical bar, and built from the song's own stems."""

    @classmethod
    def setUpClass(cls):
        busy = [b for b in range(8, 48) if not 24 <= b < 32]
        x, parts, _ = song(bars=48, vocal_bars=(), breakdown=range(0, 0), busy_bars=busy)
        cls.a = intro.analyse(x, parts, RATE, BPM)
        cls.busy = set(busy)

    def test_a_loop_is_taken_from_a_part_with_the_songs_own_feel(self):
        # The song arrives at bar 0 on the plain groove; most of the record
        # after it is busier, so its typical bar is the busy one.
        best = intro.candidates(self.a, 4, join_bar=0)[0]
        self.assertFalse(set(range(best.bar, best.bar + 4)) & self.busy, best)
        self.assertLess(best.feel, 0.2)

    def test_and_the_reference_moves_with_the_join(self):
        best = intro.candidates(self.a, 4, join_bar=12)[0]
        self.assertTrue(set(range(best.bar, best.bar + 4)) <= self.busy, best)

    def test_feel_costs_a_loop_its_place(self):
        near = intro.Source(bar=0, start=0, vocal_db=-20.0, level_db=0.0, drums_db=0.0,
                            vocal_free=True, feel=0.05)
        far = intro.Source(bar=0, start=0, vocal_db=-20.0, level_db=0.0, drums_db=0.0,
                           vocal_free=True, feel=0.8)
        self.assertGreater(intro.cost(far), intro.cost(near) + 10)

    def test_a_tempo_step_at_the_join_costs_a_loop_its_place(self):
        a = intro.Source(bar=0, start=0, vocal_db=-20.0, level_db=0.0, drums_db=0.0,
                         vocal_free=True, tempo_off=0.0)
        b = intro.Source(bar=0, start=0, vocal_db=-20.0, level_db=0.0, drums_db=0.0,
                         vocal_free=True, tempo_off=0.01)
        self.assertGreater(intro.cost(b), intro.cost(a) + 10)

    def test_a_loop_a_little_off_the_songs_tempo_is_resampled_to_it(self):
        source = intro.source_at(self.a, 24, 4, 0)
        source.length = int(round(source.length * 1.008))         # 0.8% slow at the join
        audio, info = intro.render(self.a, 16, source, 4, join_bar=0)
        ref = intro._reference(self.a, 0, 4)
        self.assertAlmostEqual(info["retuned_pct"], (ref["bar_len"] * 4 / source.length - 1) * 100,
                               delta=0.01)
        self.assertLess(info["retuned_pct"], -0.5)
        self.assertEqual(info["tempo_off_pct"], 0.0)
        # the intro is as long as four loops at the SONG's tempo, to a few samples
        self.assertAlmostEqual(info["intro_samples"], 4 * ref["bar_len"] * 4, delta=8)

    def test_a_loop_too_far_off_is_left_alone_and_said_so(self):
        source = intro.source_at(self.a, 24, 4, 0)
        source.length = int(round(source.length * 1.05))
        _, info = intro.render(self.a, 16, source, 4, join_bar=0)
        self.assertEqual(info["retuned_pct"], 0.0)
        self.assertLess(info["tempo_off_pct"], -4.0)

    def test_build_brings_the_stems_in_and_ends_whole(self):
        source = intro.candidates(self.a, 4, join_bar=0)[0]
        full, info = intro.render(self.a, 16, source, 4, join_bar=0, style="full")
        built, binfo = intro.render(self.a, 16, source, 4, join_bar=0, style="build")
        self.assertEqual(binfo["style"], "build")
        self.assertEqual(full.shape, built.shape)
        unit = info["intro_samples"] // 4
        first = slice(2000, unit - 2000)
        last = slice(3 * unit + 2000, 4 * unit - 2000)
        self.assertTrue(np.allclose(full[last], built[last], atol=1e-6))
        gap = np.sqrt(np.mean((full[first] - built[first]) ** 2))
        self.assertGreater(gap, 0.05 * np.sqrt(np.mean(full[first] ** 2)))
        # the first repeat is the drum stem and nothing else: silencing the
        # bass and the rest changes nothing in it, and changes the last
        # repeat's bass and the second repeat's bass
        import dataclasses
        drums_only = dataclasses.replace(self.a, bass=np.zeros_like(self.a.bass),
                                         other=np.zeros_like(self.a.other))
        bare, _ = intro.render(drums_only, 16, source, 4, join_bar=0, style="build")
        self.assertTrue(np.allclose(built[first], bare[first], atol=1e-6))
        second = slice(unit + 2000, 2 * unit - 2000)
        self.assertFalse(np.allclose(built[second], bare[second], atol=1e-4))
        self.assertFalse(np.allclose(built[last], bare[last], atol=1e-4))

    def test_beat_runs_only_the_drums_and_bass_under_every_repeat(self):
        import dataclasses
        source = intro.candidates(self.a, 4, join_bar=0)[0]
        beat, info = intro.render(self.a, 16, source, 4, join_bar=0, style="beat")
        self.assertEqual(info["style"], "beat")
        unit = info["intro_samples"] // 4
        # silencing the rest of the band changes nothing, in any repeat
        no_other = dataclasses.replace(self.a, other=np.zeros_like(self.a.other))
        bare, _ = intro.render(no_other, 16, source, 4, join_bar=0, style="beat")
        intro_part = slice(2000, info["intro_samples"] - 2000)
        self.assertTrue(np.allclose(beat[intro_part], bare[intro_part], atol=1e-6))
        # but silencing the bass does, in the last repeat as in the first
        no_bass = dataclasses.replace(self.a, bass=np.zeros_like(self.a.bass))
        thin, _ = intro.render(no_bass, 16, source, 4, join_bar=0, style="beat")
        last = slice(3 * unit + 2000, 4 * unit - 2000)
        self.assertFalse(np.allclose(beat[last], thin[last], atol=1e-4))

    def test_the_stem_styles_hand_over_with_drums_and_bass_under_the_song(self):
        source = intro.candidates(self.a, 4, join_bar=0)[0]
        for style in ("build", "beat"):
            cut, _ = intro.render(self.a, 16, source, 4, join_bar=0, style=style, handover=0)
            mixed, info = intro.render(self.a, 16, source, 4, join_bar=0, style=style)
            self.assertEqual(info["handover_bars"], 1.0)
            unit = info["intro_samples"] // 4
            lead = int(round(info["lead_seconds"] * self.a.rate))
            end = info["intro_samples"] + lead
            # nothing changes before the loop stops, or a bar after it
            self.assertTrue(np.allclose(cut[:end - 200], mixed[:end - 200], atol=1e-6))
            # under the song's first bar the mix carries the loop's band
            gap = np.sqrt(np.mean((mixed[end:end + unit // 4] - cut[end:end + unit // 4]) ** 2))
            self.assertGreater(gap, 0.01)
            # ...and after one bar it is the song alone again
            later = slice(end + unit // 4 + 200, end + unit // 4 + 4000)
            self.assertTrue(np.allclose(cut[later], mixed[later], atol=1e-6))
        # full loop has no hand-over
        _, finfo = intro.render(self.a, 16, source, 4, join_bar=0, style="full")
        self.assertEqual(finfo["handover_bars"], 0.0)

    def test_a_half_beat_move_shifts_the_bar_lines_by_half_a_beat(self):
        period = self.a.grid.period
        later = intro.rephase(self.a, 0, 1)
        earlier = intro.rephase(self.a, 0, -1)
        for moved in (later, earlier):
            off = (moved.join - self.a.join) % period
            self.assertLess(abs(off - period / 2), 0.15 * period)
            self.assertEqual(moved.grid.bpm, self.a.grid.bpm)
        # two half beats make a whole one, the same as moving a beat
        two = intro.rephase(intro.rephase(self.a, 0, 1), 0, 1)
        whole = intro.rephase(self.a, 1)
        self.assertLess(abs(two.join - whole.join), 0.15 * period)
        # and half a beat there and back is where it began
        back = intro.rephase(intro.rephase(self.a, 0, 1), 0, -1)
        self.assertLess(abs(back.join - self.a.join), 0.15 * period)

    def test_underlay_keeps_the_opening_and_puts_the_beat_under_it(self):
        import dataclasses
        a = self.a
        join_bar = 4
        source = intro.candidates(a, 4, join_bar=join_bar)[0]
        out, info = intro.render(a, 8, source, 4, join_bar=join_bar, style="underlay")
        self.assertEqual(out.shape, a.original.shape)       # nothing cut, nothing moved
        self.assertEqual(info["style"], "underlay")
        self.assertEqual(info["bars"], 4)                    # the opening is 4 bars
        join = int(a.bar_lines[join_bar])
        self.assertEqual(info["intro_samples"], join)
        # after the hand-over the file is the song, untouched
        late = slice(join + int(2 * a.grid.bar), len(out) - 1000)
        self.assertTrue(np.allclose(out[late], a.original[late], atol=1e-4))
        # under the opening it is not: the beat is there, and louder toward the join
        early = slice(int(a.bar_lines[0]) + 4000, int(a.bar_lines[1]))
        late_open = slice(int(a.bar_lines[join_bar - 1]), join - 2000)
        added = lambda s_: np.sqrt(np.mean((out[s_] - a.original[s_]) ** 2))
        self.assertGreater(added(late_open), added(early))
        self.assertGreater(added(late_open), 0.01)
        # a song that starts on its groove has no opening to underlay
        with self.assertRaises(ValueError):
            intro.render(a, 8, source, 4, join_bar=0, style="underlay")
        # and it needs the stems
        bare = dataclasses.replace(a, bass=np.zeros((0, 2), dtype=np.float32))
        with self.assertRaises(ValueError):
            intro.render(bare, 8, source, 4, join_bar=join_bar, style="underlay")

    def test_a_drumless_opening_suggests_underlay(self):
        import dataclasses
        lines = self.a.bar_lines
        drums = self.a.drums.copy()
        drums[int(lines[0]):int(lines[4])] *= 0.05
        style, why = intro.suggest_style(dataclasses.replace(self.a, drums=drums), 4)
        self.assertEqual(style, "underlay")
        self.assertIn("lay the beat under it", why)

    def test_the_style_follows_how_bare_the_arrival_bars_are(self):
        import dataclasses
        style, why = intro.suggest_style(self.a, 4)
        self.assertEqual(style, "build")
        self.assertIn("own groove", why)
        # take the drums out of the bars the song arrives with: bare
        lines = self.a.bar_lines
        drums = self.a.drums.copy()
        drums[int(lines[4]):int(lines[8])] *= 0.05
        bare = dataclasses.replace(self.a, drums=drums)
        style, why = intro.suggest_style(bare, 4)
        self.assertEqual(style, "beat")
        self.assertIn("below the song's body", why)

    def test_without_the_separate_stems_build_falls_back_to_the_whole_instrumental(self):
        import dataclasses
        bare = dataclasses.replace(self.a, bass=np.zeros((0, 2), dtype=np.float32),
                                   other=np.zeros((0, 2), dtype=np.float32))
        source = intro.candidates(bare, 4, join_bar=0)[0]
        _, info = intro.render(bare, 16, source, 4, join_bar=0, style="build")
        self.assertEqual(info["style"], "full")

    def test_an_unknown_style_is_refused(self):
        with self.assertRaises(ValueError):
            intro.render(self.a, 16, intro.candidates(self.a, 4, join_bar=0)[0], 4, style="smooth")


class TestEndingOnTheSongsOwnBreak(unittest.TestCase):
    """The intro's last bar can be the song's own break, so the intro leads
    into the downbeat the way the song leads into a drop."""

    @classmethod
    def setUpClass(cls):
        x, parts, _ = song(bars=44, vocal_bars=(range(0, 2),), breakdown=range(33, 34))
        cls.a = intro.analyse(x, parts, RATE, BPM)
        cls.source = intro.candidates(cls.a, 4)[0]

    def test_the_bar_before_the_drums_come_back_is_found(self):
        found = intro.suggest_lead_in(self.a, 0)
        self.assertIsNotNone(found)
        self.assertEqual(found[0], 33)
        self.assertGreaterEqual(found[1], intro.LEAD_IN_MATCH)

    def test_a_song_with_no_break_has_none(self):
        x, parts, _ = song(bars=44, vocal_bars=(range(0, 2),), breakdown=range(0, 0))
        plain = intro.analyse(x, parts, RATE, BPM)
        self.assertIsNone(intro.suggest_lead_in(plain, 0))

    def test_the_last_bar_before_the_join_is_the_break_and_the_rest_is_untouched(self):
        plain, _ = intro.render(self.a, 16, self.source, 4, join_bar=0)
        ended, info = intro.render(self.a, 16, self.source, 4, join_bar=0, lead_in_bar=33)
        self.assertEqual(info["lead_in_bar"], 33)
        self.assertEqual(plain.shape, ended.shape)
        bar = int(self.a.grid.bar)
        join = int(round((info["seconds_of_intro"] + info["lead_seconds"]) * RATE))
        low = lambda y: float(np.mean(sosfilt(butter(2, 150.0, btype="low", fs=RATE,
                                                      output="sos"), y.mean(axis=1)) ** 2))
        # before: the last bar is loop (kicks and bass); after: the break, which has neither
        last = slice(join - bar + 2000, join - 2000)
        self.assertLess(low(ended[last]), 0.05 * low(plain[last]))
        # the bars before it, and the whole song after the join, are the same samples
        early = slice(0, join - bar - 2000)
        self.assertTrue(np.allclose(ended[early], plain[early], atol=1e-6))
        self.assertTrue(np.array_equal(ended[join + 2000:], plain[join + 2000:]))

    def test_a_bad_bar_is_refused(self):
        with self.assertRaises(ValueError):
            intro.render(self.a, 16, self.source, 4, join_bar=0, lead_in_bar=0)

    def test_a_session_render_can_ask_for_it_automatically(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = write.write(Path(tmp) / "Song", song(bars=44, vocal_bars=(range(0, 2),),
                                                          breakdown=range(33, 34))[0], RATE, fmt="flac")
            session = intro.Session(out_dir=Path(tmp) / "out")
            parts = song(bars=44, vocal_bars=(range(0, 2),), breakdown=range(33, 34))[1]
            events = []
            with mock.patch.object(intro, "separate", return_value=parts):
                session.handle({"id": 1, "cmd": "prepare", "path": str(source), "bpm": 120},
                               events.append)
            events = []
            session.handle({"id": 2, "cmd": "render", "bars": 16, "loop_bars": 4,
                            "lead_in": "auto"}, events.append)
            made = [e for e in events if e["event"] == "intro"][0]
            self.assertEqual(made["lead_in_bar"], 33)
            self.assertGreaterEqual(made["lead_in_match"], intro.LEAD_IN_MATCH)
            events = []
            session.handle({"id": 3, "cmd": "render", "bars": 16, "loop_bars": 4}, events.append)
            self.assertIsNone([e for e in events if e["event"] == "intro"][0]["lead_in_bar"])


class TestBeatOne(unittest.TestCase):
    """Moving which beat is the first of the bar, without separating again."""

    @classmethod
    def setUpClass(cls):
        x, parts, _ = song(bars=36)
        cls.a = intro.analyse(x, parts, RATE, BPM)

    def test_one_beat_later_moves_every_bar_line_by_a_beat(self):
        b = intro.rephase(self.a, 1)
        beat = self.a.grid.period
        n = min(len(self.a.bar_lines), len(b.bar_lines)) - 2
        shift = (b.bar_lines[:n] - self.a.bar_lines[:n]) % self.a.grid.bar
        self.assertAlmostEqual(float(np.median(shift)) / beat, 1.0, delta=0.02)

    def test_four_beats_is_the_same_bar_lines(self):
        b = intro.rephase(self.a, 4)
        self.assertEqual(b.grid.downbeat_phase, self.a.grid.downbeat_phase)
        n = min(len(self.a.bar_lines), len(b.bar_lines))
        self.assertTrue(np.array_equal(b.bar_lines[:n], self.a.bar_lines[:n]))

    def test_earlier_and_later_cancel(self):
        b = intro.rephase(intro.rephase(self.a, 1), -1)
        self.assertEqual(b.grid.downbeat_phase, self.a.grid.downbeat_phase)

    def test_a_hand_set_beat_is_no_longer_a_guess(self):
        b = intro.rephase(self.a, 1)
        self.assertEqual(b.grid.how, "set by hand")
        self.assertFalse([w for w in b.warnings if "guess" in w])

    def test_an_edit_made_after_is_laid_out_on_the_new_grid(self):
        b = intro.rephase(self.a, 2)
        source = intro.candidates(b, 4)[0]
        audio, info = intro.render(b, 8, source, 4, join_bar=0)
        self.assertEqual(info["join_bar"], 0)
        self.assertAlmostEqual(info["join_seconds"], b.bar_lines[0] / RATE, delta=0.001)


class TestTheEdit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.x, cls.parts, cls.lead = song()
        cls.a = intro.analyse(cls.x, cls.parts, RATE, BPM)
        cls.source = intro.candidates(cls.a, 4)[0]

    def render(self, bars=16, loop_bars=4):
        return intro.render(self.a, bars, self.source, loop_bars)

    def test_the_length_is_the_intro_plus_the_rest_of_the_song(self):
        for bars in intro.LENGTHS:
            audio, info = self.render(bars)
            join_out = (bars // 4) * self.source.length
            lead = round(info["lead_seconds"] * RATE)
            self.assertEqual(len(audio), len(self.x) - self.a.join + join_out + lead)
            # The tempo is fitted from kick onsets that jitter by about a
            # millisecond, so a bar is right to some parts in ten thousand,
            # not exactly: 10 ms over 32 bars is the allowance.
            self.assertAlmostEqual(info["seconds_of_intro"], bars * BAR, delta=0.01)

    def test_the_original_arrives_untouched_after_the_join(self):
        audio, info = self.render(16)
        join_out = (16 // 4) * self.source.length + round(info["lead_seconds"] * RATE)
        tail = audio[join_out + 2000:]
        original = self.x[self.a.join + 2000:]
        np.testing.assert_allclose(tail, original, atol=1e-6)

    def test_there_is_no_vocal_in_the_intro(self):
        audio, info = self.render(16)
        join_out = (16 // 4) * self.source.length + round(info["lead_seconds"] * RATE)
        in_intro = tone_power(audio[:join_out - RATE // 20])
        in_song = tone_power(self.x[:int(8 * BAR * RATE)])
        self.assertLess(in_intro, in_song * 1e-3)

    def test_the_beat_does_not_slip_across_the_seams_or_the_join(self):
        audio, info = self.render(32)
        # Against the song's TRUE period, not one fitted to this file: a
        # fit absorbs a drift that is spread across the file, and the
        # mutation of this test (a loop 40 samples long) went unnoticed
        # until it did not. The same detector on both sides, so its own
        # bias cancels: where in the beat the intro's kicks fall must be
        # where the song's do.
        kicks, _ = subbass.detect_kicks(audio, RATE)
        period = BEAT * RATE
        join_out = (32 // 4) * self.source.length + round(info["lead_seconds"] * RATE)

        def phase_ms(selected):
            angle = np.exp(2j * np.pi * selected / period)
            return np.angle(angle.mean()) / (2 * np.pi) * period / RATE * 1000

        intro_kicks = kicks[kicks < join_out - RATE // 5]
        song_kicks = kicks[kicks > join_out + RATE // 5]
        self.assertGreater(len(intro_kicks), 100)
        # Phase is circular: a difference is taken the short way round.
        slip = (phase_ms(intro_kicks) - phase_ms(song_kicks) + BEAT * 500) % (BEAT * 1000) - BEAT * 500
        self.assertLess(abs(slip), 1.5, f"intro kicks sit {slip:.1f} ms off the song's")

    def test_a_seam_does_not_double_or_dip_the_level(self):
        audio, info = self.render(16)
        mono = audio.mean(axis=1)
        window = int(0.02 * RATE)
        bar = int(round(self.a.grid.bar))
        lead = round(info["lead_seconds"] * RATE)
        join_out = (16 // 4) * self.source.length
        levels = []
        for seam in range(4 * bar + lead, join_out - 4 * bar, 4 * bar):
            around = np.sqrt(np.mean(mono[seam - window:seam + window] ** 2))
            beside = np.sqrt(np.mean(mono[seam + bar // 2 - window:seam + bar // 2 + window] ** 2))
            levels.append(20 * np.log10(around / beside))
        self.assertLess(max(abs(v) for v in levels), 4.0, levels)

    def test_nothing_clips(self):
        audio, _ = self.render(32)
        self.assertLessEqual(float(np.abs(audio).max()), 1.0)

    def test_a_length_the_loop_does_not_divide_is_refused(self):
        with self.assertRaisesRegex(ValueError, "whole number"):
            intro.render(self.a, 12, self.source, 8)

    def test_the_pickup_is_kept_and_leads_into_the_downbeat(self):
        x, parts, lead = song(pickup_beats=2)
        a = intro.analyse(x, parts, RATE, BPM)
        source = intro.candidates(a, 4)[0]
        audio, info = intro.render(a, 8, source)
        join_out = info["intro_samples"] + round(info["lead_seconds"] * RATE)
        # The vocal pickup sits just ahead of the join, as it did.
        pickup = audio[join_out - int(lead * RATE):join_out - int(lead * RATE) + RATE // 4]
        self.assertGreater(tone_power(pickup), 1e-6)
        self.assertAlmostEqual(info["pickup_seconds"], lead, delta=0.01)
        # And the original is whole from there.
        np.testing.assert_allclose(audio[join_out + 2000:], x[a.join + 2000:], atol=1e-6)

    def test_a_loop_with_vocal_in_it_is_called_out(self):
        x, parts, _ = song(vocal_bars=(range(0, 36),))
        a = intro.analyse(x, parts, RATE, BPM)
        _, info = intro.render(a, 8, intro.candidates(a, 4)[0])
        self.assertTrue(any("vocal bleed" in w for w in info["warnings"]))


class TestNothingTravelsThatWouldBeWrong(unittest.TestCase):
    """The original's cue points describe the song without its intro. Every
    one would be late by the intro's length, so none are carried."""

    def test_serato_markers_are_dropped_from_an_edit(self):
        from tests.test_tags import _geob, _tag
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "a.mp3"
            tone = np.zeros((RATE, 2), dtype=np.float32)
            write.write(Path(tmp) / "plain", tone, RATE, fmt="mp3")
            audio = (Path(tmp) / "plain.mp3").read_bytes()
            tag = _tag([(b"GEOB", _geob("Serato Markers2", b"\x01\x01" + bytes(200)))])
            source.write_bytes(tag + audio)
            kept = write.write(Path(tmp) / "kept", tone, RATE, source=source, fmt="mp3")
            dropped = write.write(Path(tmp) / "dropped", tone, RATE, source=source,
                                  fmt="mp3", keep_markers=False)
            self.assertIn(b"Serato Markers2", kept.read_bytes())
            self.assertNotIn(b"Serato Markers2", dropped.read_bytes())


class TestLettingGoOfMemory(unittest.TestCase):
    """A held session was measured at 6 GB on a 16 GB Mac, idle, for the best
    part of an hour. These keep that from coming back."""

    def test_the_gpu_caches_are_cleared_after_separating(self):
        fake_mx = mock.MagicMock()
        fake_torch = mock.MagicMock()
        with mock.patch.dict(sys.modules, {"mlx": mock.MagicMock(core=fake_mx),
                                           "mlx.core": fake_mx, "torch": fake_torch}):
            intro.release_memory()
        fake_mx.clear_cache.assert_called_once()
        fake_torch.mps.empty_cache.assert_called_once()

    def test_a_machine_with_neither_library_is_not_an_error(self):
        with mock.patch.dict(sys.modules, {"mlx": None, "mlx.core": None}):
            sys.modules.pop("torch", None)
            intro.release_memory()                      # must simply return

    def test_a_failing_cache_clear_does_not_break_a_separation(self):
        fake_mx = mock.MagicMock()
        fake_mx.clear_cache.side_effect = RuntimeError("no metal")
        with mock.patch.dict(sys.modules, {"mlx": mock.MagicMock(core=fake_mx),
                                           "mlx.core": fake_mx}):
            intro.release_memory()

    def test_separating_clears_the_caches_even_when_it_fails(self):
        with mock.patch.object(intro.stems, "available", return_value=["demucs"]), \
                mock.patch.object(intro.stems, "separate", side_effect=RuntimeError("boom")), \
                mock.patch.object(intro, "release_memory") as release:
            with self.assertRaisesRegex(RuntimeError, "boom"):
                intro.separate(np.zeros((100, 2), dtype=np.float32), RATE)
        release.assert_called_once()

    def test_a_released_session_says_no_track_with_a_code_to_act_on(self):
        x, parts, _ = song(bars=24, vocal_bars=(range(0, 4),), breakdown=range(0, 0))
        with tempfile.TemporaryDirectory() as tmp:
            source = write.write(Path(tmp) / "Song", x, RATE, fmt="flac")
            session = intro.Session(out_dir=Path(tmp) / "o")
            events = []
            with mock.patch.object(intro, "separate", return_value=parts):
                session.handle({"id": 1, "cmd": "prepare", "path": str(source), "bpm": 120},
                               events.append)
            self.assertIsNotNone(session.analysis)
            events.clear()
            session.handle({"id": 2, "cmd": "release"}, events.append)
            self.assertEqual([e["event"] for e in events], ["released", "done"])
            self.assertIsNone(session.analysis)
            events.clear()
            session.handle({"id": 3, "cmd": "render", "bars": 8}, events.append)
            self.assertEqual(events[-1]["event"], "error")
            self.assertEqual(events[-1]["code"], "no_track")

    def test_an_ordinary_error_has_no_code(self):
        session = intro.Session()
        events = []
        session.handle({"id": 1, "cmd": "dance"}, events.append)
        self.assertEqual(events[-1]["event"], "error")
        self.assertIsNone(events[-1]["code"])


class _Scripted:
    """A source of lines that also moves a fake clock: ('line', text),
    ('wait', seconds) which times out after that long, or ('eof',)."""

    def __init__(self, script, clock):
        self.script, self.clock, self.asked = list(script), clock, []

    def read(self, timeout):
        self.asked.append(timeout)
        kind, *rest = self.script.pop(0)
        if kind == "eof":
            return intro.EOF_LINE
        if kind == "wait":
            self.clock.now += rest[0]
            return intro.TIMED_OUT
        return rest[0]


class _Clock:
    now = 0.0

    def __call__(self):
        return self.now


class TestServingWithIdleHandling(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.x, cls.parts, _ = song(bars=24, vocal_bars=(range(0, 4),), breakdown=range(0, 0))
        cls.tmp = tempfile.TemporaryDirectory()
        cls.source = write.write(Path(cls.tmp.name) / "Song", cls.x, RATE, fmt="flac")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_script(self, script, **kwargs):
        import json
        clock, events = _Clock(), []
        session = intro.Session(out_dir=Path(self.tmp.name) / "o")
        source = _Scripted(script, clock)
        with mock.patch.object(intro, "separate", return_value=self.parts):
            intro.serve(session, source, events.append, clock=clock, **kwargs)
        return events, session, source

    def prepare_line(self):
        import json
        return ("line", json.dumps({"id": 1, "cmd": "prepare", "path": str(self.source),
                                    "bpm": 120}))

    def test_a_quiet_session_lets_its_track_go_and_says_so(self):
        events, session, _ = self.run_script(
            [self.prepare_line(), ("wait", 700), ("eof",)],
            release_after=600, exit_after=None)
        released = [e for e in events if e["event"] == "released"]
        self.assertEqual(len(released), 1)
        self.assertEqual(released[0]["reason"], "idle")
        self.assertIsNone(session.analysis)

    def test_it_is_idle_from_the_answer_not_the_ask(self):
        # The request took 500 s of (fake) time to answer; the clock for
        # idleness starts when it is done, so 200 more is not yet 600.
        import json
        clock = _Clock()
        session = intro.Session(out_dir=Path(self.tmp.name) / "o")
        events = []

        def slow_separate(*args, **kwargs):
            clock.now += 500
            return self.parts

        source = _Scripted([self.prepare_line(), ("wait", 200), ("eof",)], clock)
        with mock.patch.object(intro, "separate", side_effect=slow_separate):
            intro.serve(session, source, events.append, clock=clock,
                        release_after=600, exit_after=None)
        self.assertEqual([e for e in events if e["event"] == "released"], [])

    def test_nothing_is_released_when_nothing_is_held(self):
        events, _, _ = self.run_script([("wait", 700), ("eof",)],
                                       release_after=600, exit_after=None)
        self.assertEqual(events, [])

    def test_a_session_idle_long_enough_exits_and_says_so(self):
        events, _, source = self.run_script(
            [self.prepare_line(), ("wait", 700), ("wait", 1200), ("line", "never read")],
            release_after=600, exit_after=1800)
        self.assertEqual([e["event"] for e in events if e["event"] in ("released", "exit")],
                         ["released", "exit"])
        self.assertEqual(len(source.script), 1)            # it stopped before the last line

    def test_the_wait_is_for_the_nearest_deadline(self):
        _, _, source = self.run_script(
            [self.prepare_line(), ("wait", 600), ("eof",)], release_after=600, exit_after=1800)
        # After the prepare it waits 600 for the release; having released,
        # only the exit deadline is left: 1800 - 600.
        self.assertAlmostEqual(source.asked[1], 600, delta=1)
        self.assertAlmostEqual(source.asked[2], 1200, delta=1)

    def test_with_both_off_it_waits_for_ever(self):
        _, _, source = self.run_script([("eof",)], release_after=None, exit_after=None)
        self.assertIsNone(source.asked[0])

    def test_blank_and_broken_lines_do_not_end_it(self):
        events, _, _ = self.run_script(
            [("line", ""), ("line", "not json"), ("line", '{"id": 5, "cmd": "quit"}'),
             ("line", "never read")], release_after=None, exit_after=None)
        self.assertEqual(events[0]["event"], "error")
        self.assertIn("not JSON", events[0]["message"])
        self.assertEqual(events[-1], {"event": "done", "id": 5})

    def test_a_request_after_a_release_is_answered_with_the_code(self):
        import json
        events, _, _ = self.run_script(
            [self.prepare_line(), ("wait", 700),
             ("line", json.dumps({"id": 2, "cmd": "render", "bars": 8})), ("eof",)],
            release_after=600, exit_after=None)
        last = events[-1]
        self.assertEqual((last["event"], last.get("code")), ("error", "no_track"))


class TestReadingFromADescriptor(unittest.TestCase):
    """With a real pipe: the reason this does not use `for line in
    sys.stdin` is a buffering trap a mock cannot reproduce."""

    def test_lines_arrive_split_across_writes_and_two_at_once(self):
        r, w = os.pipe()
        try:
            source = intro.FdLines(r)
            os.write(w, b"first\nsec")
            self.assertEqual(source.read(1), "first")
            os.write(w, b"ond\nthird\n")
            self.assertEqual(source.read(1), "second")
            self.assertEqual(source.read(1), "third")     # already buffered: no wait
        finally:
            os.close(r)
            os.close(w)

    def test_a_silent_pipe_times_out_and_then_still_works(self):
        r, w = os.pipe()
        try:
            source = intro.FdLines(r)
            started = time.monotonic()
            self.assertIs(source.read(0.15), intro.TIMED_OUT)
            self.assertGreaterEqual(time.monotonic() - started, 0.1)
            os.write(w, b"late\n")
            self.assertEqual(source.read(1), "late")
        finally:
            os.close(r)
            os.close(w)

    def test_a_closed_pipe_is_the_end_and_a_last_unterminated_line_is_kept(self):
        r, w = os.pipe()
        try:
            source = intro.FdLines(r)
            os.write(w, b"last line without a newline")
            os.close(w)
            self.assertEqual(source.read(1), "last line without a newline")
            self.assertIs(source.read(1), intro.EOF_LINE)
        finally:
            os.close(r)


class TestFromAFile(unittest.TestCase):
    """The whole path, with the separation standing in for Demucs."""

    def test_the_command_writes_each_length_and_never_touches_the_original(self):
        x, parts, _ = song(bars=24, vocal_bars=(range(0, 4),), breakdown=range(0, 0))
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            source = write.write(tmp / "Song", x, RATE, fmt="flac")
            before = source.read_bytes()
            out = tmp / "out"
            with mock.patch.object(intro, "separate", return_value=parts), \
                    contextlib.redirect_stdout(io.StringIO()) as printed:
                code = cli.main(["intro", str(source), "--bpm", "120",
                                 "--bars", "8", "16", "--out", str(out)])
            self.assertEqual(code, 0, printed.getvalue())
            made = sorted(p.name for p in out.iterdir())
            self.assertEqual(made, ["Song (Intro 16).flac", "Song (Intro 8).flac"])
            self.assertEqual(source.read_bytes(), before)
            first = decode.decode(out / "Song (Intro 8).flac")
            self.assertAlmostEqual(len(first) / RATE,
                                   len(x) / RATE + 8 * BAR, delta=0.05)

    def test_a_track_with_no_tempo_says_how_to_give_one(self):
        x, parts, _ = song(bars=24)
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            source = write.write(tmp / "Song", x, RATE, fmt="flac")
            err = io.StringIO()
            with mock.patch.object(intro, "separate", return_value=parts), \
                    contextlib.redirect_stderr(err), \
                    contextlib.redirect_stdout(io.StringIO()):
                code = cli.main(["intro", str(source), "--out", str(tmp / "o")])
            self.assertNotEqual(code, 0)
            self.assertIn("--bpm", err.getvalue())


class TestASession(unittest.TestCase):
    """What the app talks to: separate once, then ask for things."""

    @classmethod
    def setUpClass(cls):
        cls.x, cls.parts, _ = song(bars=24, vocal_bars=(range(0, 4),),
                                   breakdown=range(0, 0))
        cls.tmp = tempfile.TemporaryDirectory()
        cls.source = write.write(Path(cls.tmp.name) / "Song", cls.x, RATE, fmt="flac")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def ask(self, session, **request):
        events = []
        alive = session.handle(request, events.append)
        return events, alive

    def prepared(self):
        session = intro.Session(out_dir=Path(self.tmp.name) / "out")
        with mock.patch.object(intro, "separate", return_value=self.parts):
            events, _ = self.ask(session, id=1, cmd="prepare",
                                 path=str(self.source), bpm=120)
        return session, events

    def test_a_request_is_answered_and_always_ends_in_done_with_its_id(self):
        _, events = self.prepared()
        self.assertEqual([e["event"] for e in events], ["stage", "prepared", "done"])
        self.assertTrue(all(e["id"] == 1 for e in events))
        prepared = events[1]
        self.assertAlmostEqual(prepared["bpm"], 120.0, delta=0.1)
        self.assertEqual(prepared["name"], "Song.flac")

    def test_the_separation_is_paid_once_however_many_things_are_asked(self):
        session = intro.Session(out_dir=Path(self.tmp.name) / "out")
        with mock.patch.object(intro, "separate", return_value=self.parts) as sep:
            self.ask(session, id=1, cmd="prepare", path=str(self.source), bpm=120)
            self.ask(session, id=2, cmd="sources", loop_bars=4)
            self.ask(session, id=3, cmd="render", bars=8, loop_bars=4)
            self.ask(session, id=4, cmd="render", bars=16, loop_bars=4)
        self.assertEqual(sep.call_count, 1)

    def test_prepared_says_where_the_song_arrives_and_where_every_bar_is(self):
        _, events = self.prepared()
        prepared = [e for e in events if e["event"] == "prepared"][0]
        bars = prepared["bar_seconds"]
        self.assertEqual(len(bars), prepared["bars_after_join"] + 1)
        self.assertEqual(bars, sorted(bars))
        self.assertEqual(prepared["suggested_join_bar"], 0)       # this song starts cold
        self.assertIn("join_reason", prepared)
        self.assertAlmostEqual(prepared["join_seconds"],
                               bars[prepared["suggested_join_bar"]], delta=0.05)
        self.assertAlmostEqual(prepared["first_bar_seconds"], bars[0], delta=0.001)

    def test_the_beat_can_be_moved_in_a_held_session(self):
        session, events = self.prepared()
        before = events[1]
        events, _ = self.ask(session, id=12, cmd="rephase", beats=1)
        grid = [e for e in events if e["event"] == "grid"][0]
        self.assertEqual(grid["downbeat_from"], "set by hand")
        self.assertEqual(len(grid["bar_seconds"]) > 10, True)
        self.assertNotAlmostEqual(grid["bar_seconds"][0], before["bar_seconds"][0], delta=0.1)
        self.assertEqual(events[-1]["event"], "done")
        events, _ = self.ask(session, id=13, cmd="render", bars=8, loop_bars=4)
        self.assertEqual(events[-1]["event"], "done")

    def test_the_envelope_is_sent_on_request(self):
        session, _ = self.prepared()
        events, _ = self.ask(session, id=7, cmd="envelope")
        env = [e for e in events if e["event"] == "envelope"][0]
        self.assertGreater(len(env["bass"]), 100)
        self.assertEqual(len(env["bass"]), len(env["mid"]))
        self.assertEqual(events[-1]["event"], "done")

    def test_a_render_takes_the_chosen_join(self):
        session, _ = self.prepared()
        events, _ = self.ask(session, id=8, cmd="render", bars=8, loop_bars=4,
                             join_bar=3)
        made = [e for e in events if e["event"] == "intro"][0]
        self.assertEqual(made["join_bar"], 3)
        events, _ = self.ask(session, id=9, cmd="render", bars=8, loop_bars=4,
                             join_bar=10 ** 6)
        self.assertEqual(events[-1]["event"], "error")
        self.assertIn("outside the track", events[-1]["message"])

    def test_a_render_also_sends_the_finished_edits_envelope(self):
        session, _ = self.prepared()
        events, _ = self.ask(session, id=11, cmd="render", bars=8, loop_bars=4,
                             join_bar=3)
        made = [e for e in events if e["event"] == "intro"][0]
        drawn = [e for e in events if e["event"] == "render_envelope"][0]
        self.assertEqual(drawn["output"], made["output"])
        self.assertEqual(len(drawn["bass"]), len(drawn["mid"]))
        joined = made["seconds_of_intro"] + made["lead_seconds"]
        self.assertGreater(drawn["seconds"], joined)
        # the intro part is drawn, not silence, and so is the song after it
        per = drawn["per_second"]
        cut = int(joined * per)
        self.assertGreater(max(drawn["bass"][:cut]), 20)
        self.assertGreater(max(drawn["bass"][cut:]), 20)

    def test_sources_come_back_as_plain_json(self):
        session, _ = self.prepared()
        events, _ = self.ask(session, id=2, cmd="sources", loop_bars=4, count=3)
        found = [e for e in events if e["event"] == "sources"][0]["sources"]
        self.assertTrue(0 < len(found) <= 3)
        import json
        json.dumps(found)                     # no numpy types in it
        for key in ("bar", "seconds", "vocal_db", "vocal_free", "repeat", "snapped"):
            self.assertIn(key, found[0])

    def test_a_render_writes_the_file_and_says_where(self):
        session, _ = self.prepared()
        events, _ = self.ask(session, id=3, cmd="render", bars=8, loop_bars=4,
                             source_bar=10)
        made = [e for e in events if e["event"] == "intro"][0]
        self.assertTrue(Path(made["output"]).exists())
        self.assertEqual(made["source_bar"], 10)
        self.assertEqual(made["bars"], 8)
        self.assertIn("source_vocal_db", made)

    def test_asking_before_preparing_is_an_error_not_a_crash(self):
        session = intro.Session()
        events, alive = self.ask(session, id=9, cmd="render", bars=8)
        self.assertTrue(alive)
        self.assertEqual(events[-1]["event"], "error")
        self.assertIn("prepare", events[-1]["message"])
        self.assertEqual(events[-1]["id"], 9)

    def test_one_bad_request_does_not_end_the_session(self):
        session, _ = self.prepared()
        events, alive = self.ask(session, id=5, cmd="render", bars=8,
                                 loop_bars=4, source_bar=9999)
        self.assertTrue(alive)
        self.assertEqual(events[-1]["event"], "error")
        events, _ = self.ask(session, id=6, cmd="sources", loop_bars=4)
        self.assertEqual(events[-1]["event"], "done")

    def test_an_unknown_command_and_quit(self):
        session = intro.Session()
        events, alive = self.ask(session, id=1, cmd="dance")
        self.assertTrue(alive)
        self.assertEqual(events[-1]["event"], "error")
        events, alive = self.ask(session, id=2, cmd="quit")
        self.assertFalse(alive)
        self.assertEqual(events[-1]["event"], "done")

    def test_a_new_track_lets_the_last_one_go(self):
        session, _ = self.prepared()
        with mock.patch.object(intro, "separate", side_effect=RuntimeError("boom")):
            events, _ = self.ask(session, id=2, cmd="prepare",
                                 path=str(self.source), bpm=120)
        self.assertEqual(events[-1]["event"], "error")
        # The failed prepare must not leave the old track answering for it.
        events, _ = self.ask(session, id=3, cmd="sources")
        self.assertEqual(events[-1]["event"], "error")

    def test_serve_reads_lines_from_stdin_and_writes_events_to_stdout(self):
        import json
        requests = "\n".join(json.dumps(r) for r in (
            {"id": 1, "cmd": "prepare", "path": str(self.source), "bpm": 120},
            {"id": 2, "cmd": "render", "bars": 8, "out": str(Path(self.tmp.name) / "served")},
            {"id": 3, "cmd": "quit"},
        )) + "\nnot json at all\n"
        out = io.StringIO()
        with mock.patch.object(intro, "separate", return_value=self.parts), \
                mock.patch("sys.stdin", io.StringIO(requests)), \
                contextlib.redirect_stdout(out):
            code = cli.main(["intro", "--serve"])
        self.assertEqual(code, 0)
        events = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual([e["id"] for e in events if e["event"] == "done"], [1, 2, 3])
        self.assertTrue((Path(self.tmp.name) / "served" / "Song (Intro 8).flac").exists())
        # `quit` ended it: the line after it was never read.
        self.assertNotIn("not JSON", out.getvalue())


class TestBatchProgress(unittest.TestCase):
    def test_json_mode_announces_each_file_and_reports_a_failure_as_an_event(self):
        import json
        x, parts, _ = song(bars=24, vocal_bars=(range(0, 4),), breakdown=range(0, 0))
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            good = write.write(tmp / "Good", x, RATE, fmt="flac")
            bad = tmp / "Bad.flac"
            bad.write_bytes(b"not audio")
            out = io.StringIO()
            with mock.patch.object(intro, "separate", return_value=parts), \
                    contextlib.redirect_stdout(out), \
                    contextlib.redirect_stderr(io.StringIO()):
                code = cli.main(["intro", str(bad), str(good), "--bpm", "120",
                                 "--bars", "8", "--json", "--out", str(tmp / "o")])
            events = [json.loads(line) for line in out.getvalue().splitlines()]
            kinds = [(e["event"], e.get("name")) for e in events]
            self.assertEqual(kinds, [("file", "Bad.flac"), ("error", "Bad.flac"),
                                     ("file", "Good.flac"), ("intro", None)])
            self.assertEqual([e["total"] for e in events if e["event"] == "file"], [2, 2])
            self.assertEqual(code, 1)           # one failed, and it says so


if __name__ == "__main__":
    unittest.main()
