"""Outro edits.

The tracks are the intro tests' own, built from known stems (see
`test_intro.song`), with a fade-out laid over the end where a test wants one.
Using the TRUE stems pins what the outro code does with a separation; how
good Demucs's separation is on a real record is not asserted here.
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
sys.path.insert(0, str(ROOT / "tests"))
from loudnesslab import intro, outro, subbass, write  # noqa: E402
from test_intro import BAR, BEAT, BPM, RATE, song, tone_power  # noqa: E402


def fading_song(bars: int = 40, fade_from: int = 28, fade_db: float = 50.0, **kwargs):
    """`song` with its last bars faded out, in the mix and in every stem,
    the way a record that fades away does."""
    x, parts, lead = song(bars=bars, breakdown=range(0, 0), **kwargs)
    n = len(x)
    start = int((lead + fade_from * BAR) * RATE)
    end = int((lead + bars * BAR) * RATE)
    gain = np.ones(n)
    ramp = 10 ** (np.linspace(0.0, -fade_db, end - start) / 20.0)
    gain[start:end] = ramp
    gain[end:] = ramp[-1]
    shaped = {k: (v * gain[:, None]).astype(np.float32) for k, v in parts.items()}
    return (x * gain[:, None]).astype(np.float32), shaped, lead


class TestTheExit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.x, cls.parts, cls.lead = fading_song()
        cls.a = intro.analyse(cls.x, cls.parts, RATE, BPM)

    def test_a_fade_out_is_replaced_from_where_it_starts_to_fall(self):
        # The fade begins at bar 28; the last bar at full level is 27, so the
        # bar line to leave at is 28, give or take the bar the drop is read in.
        self.assertIn(self.a.suggested_exit_bar, (28, 29, 30))
        self.assertIn("after bar", self.a.exit_reason)
        self.assertIn("replaced", self.a.exit_reason)

    def test_a_record_that_stops_dead_exits_where_the_music_stops(self):
        # `song` leaves two seconds of silence after its last bar.
        x, parts, _ = song(bars=36, breakdown=range(0, 0))
        a = intro.analyse(x, parts, RATE, BPM)
        self.assertEqual(a.suggested_exit_bar, 36)
        self.assertIn("fall", a.exit_reason)

    def test_a_record_at_full_level_to_its_last_bar_exits_at_its_last_bar_line(self):
        x, parts, _ = song(bars=36, breakdown=range(0, 0))
        end = int(36 * BAR * RATE)
        a = intro.analyse(x[:end], {k: v[:end] for k, v in parts.items()}, RATE, BPM)
        self.assertEqual(a.suggested_exit_bar, len(a.bar_lines) - 1)
        self.assertIn("full level to its last bar", a.exit_reason)

    def test_the_analysis_carries_it_for_the_session_to_report(self):
        fields = intro.Session._grid_fields(self.a)
        self.assertEqual(fields["suggested_exit_bar"], self.a.suggested_exit_bar)
        self.assertAlmostEqual(
            fields["exit_seconds"], self.a.bar_lines[self.a.suggested_exit_bar] / RATE, delta=0.001)
        self.assertEqual(fields["exit_reason"], self.a.exit_reason)

    def test_an_exit_outside_the_track_is_refused(self):
        last = len(self.a.bar_lines) - 1
        for bad in (0, 1, last + 1, -3):
            with self.assertRaisesRegex(ValueError, "outside the track"):
                outro.resolve_exit(self.a, bad)

    def test_no_vocal_past_the_exit_keeps_no_tail(self):
        # bars 24-27 have no vocal in them
        _, tail = outro.resolve_exit(self.a, 26)
        self.assertEqual(tail, 0)

    def test_a_vocal_ringing_past_the_exit_is_kept(self):
        x, parts, lead = song(bars=40, vocal_bars=(range(0, 0),), breakdown=range(0, 0))
        # A held vocal through the last bar before bar 20 and one beat past it.
        d = np.arange(int(5 * BEAT * RATE)) / RATE
        tone = (0.25 * np.sin(2 * np.pi * 880 * d)).astype(np.float32)
        at = int((lead + 19 * BAR) * RATE)
        parts = {k: v.copy() for k, v in parts.items()}
        for y in (parts["vocals"], x):
            y[at:at + len(tone)] += tone[:, None]
        a = intro.analyse(x, parts, RATE, BPM)
        _, tail = outro.resolve_exit(a, 20)
        self.assertGreaterEqual(tail, int(a.grid.period / 2) - 1)
        self.assertLessEqual(tail, 4 * int(a.grid.period / 2))


class TestTheEdit(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.x, cls.parts, cls.lead = fading_song()
        cls.a = intro.analyse(cls.x, cls.parts, RATE, BPM)
        cls.exit_bar = cls.a.suggested_exit_bar
        cls.exit_ = int(cls.a.bar_lines[cls.exit_bar])
        cls.source = outro.candidates(cls.a, 4, exit_bar=cls.exit_bar)[0]

    def render(self, bars=16, **kwargs):
        return outro.render(self.a, bars, self.source, 4, self.exit_bar, **kwargs)

    def test_the_file_is_the_original_up_to_the_exit_then_the_outro(self):
        for bars in outro.LENGTHS:
            audio, info = self.render(bars)
            self.assertEqual(len(audio), self.exit_ + info["outro_samples"])
            self.assertEqual(info["outro_samples"], (bars // 4) * self.source.length)
            self.assertAlmostEqual(info["seconds_of_outro"], bars * BAR, delta=0.01)

    def test_the_original_is_untouched_before_the_exit(self):
        audio, _ = self.render(16)
        safe = self.exit_ - int(0.05 * RATE)
        self.assertTrue(np.allclose(audio[:safe], self.x[:safe], atol=1e-6))

    def test_the_outro_has_the_groove_where_the_original_had_faded_away(self):
        audio, _ = self.render(16)
        span = slice(self.exit_ + int(BAR * RATE), self.exit_ + int(3 * BAR * RATE))
        made = np.sqrt(np.mean(audio[span] ** 2))
        # the original's own last bars, 50 dB down
        faded = np.sqrt(np.mean(self.x[len(self.x) - int(4 * BAR * RATE):] ** 2))
        self.assertGreater(made, 30 * faded)

    def test_the_best_source_has_no_vocal_and_none_leaks_into_the_outro(self):
        self.assertTrue(self.source.vocal_free)
        audio, _ = self.render(16)
        in_outro = tone_power(audio[self.exit_ + int(BAR * RATE):])
        in_song = tone_power(self.x[:int(8 * BAR * RATE)])
        self.assertLess(in_outro, in_song * 1e-3)

    def test_the_beat_does_not_slip_across_the_seams_or_the_exit(self):
        audio, info = self.render(32)
        kicks, _ = subbass.detect_kicks(audio, RATE)
        period = BEAT * RATE

        def phase_ms(selected):
            angle = np.exp(2j * np.pi * selected / period)
            return np.angle(angle.mean()) / (2 * np.pi) * period / RATE * 1000

        song_kicks = kicks[(kicks > 4 * RATE) & (kicks < self.exit_ - RATE // 5)]
        outro_kicks = kicks[kicks > self.exit_ + RATE // 5]
        self.assertGreater(len(outro_kicks), 100)
        slip = (phase_ms(outro_kicks) - phase_ms(song_kicks) + BEAT * 500) % (BEAT * 1000) - BEAT * 500
        self.assertLess(abs(slip), 1.5, f"outro kicks sit {slip:.1f} ms off the song's")

    def test_a_seam_does_not_double_or_dip_the_level(self):
        audio, info = self.render(16)
        mono = audio.mean(axis=1)
        window = int(0.02 * RATE)
        bar = int(round(self.a.grid.bar))
        levels = []
        for seam in range(self.exit_ + 4 * bar, self.exit_ + info["outro_samples"] - 4 * bar, 4 * bar):
            around = np.sqrt(np.mean(mono[seam - window:seam + window] ** 2))
            beside = np.sqrt(np.mean(mono[seam + bar // 2 - window:seam + bar // 2 + window] ** 2))
            levels.append(20 * np.log10(around / beside))
        self.assertLess(max(abs(v) for v in levels), 4.0, levels)

    def test_nothing_clips(self):
        for style in outro.STYLES:
            audio, _ = self.render(32, style=style)
            self.assertLessEqual(float(np.abs(audio).max()), 1.0)

    def test_strip_takes_the_band_away_and_ends_on_the_drums(self):
        full, _ = self.render(16, style="full")
        strip, info = self.render(16, style="strip")
        self.assertEqual(info["style"], "strip")
        unit = info["outro_samples"] // 4
        first = slice(self.exit_ + unit // 8, self.exit_ + unit - unit // 8)
        last = slice(self.exit_ + 3 * unit + unit // 8, self.exit_ + 4 * unit - unit // 8)
        rms = lambda y, s: float(np.sqrt(np.mean(y[s] ** 2)))   # noqa: E731
        self.assertGreater(rms(strip, first), 0.9 * rms(full, first))   # starts whole
        self.assertLess(rms(strip, last), 0.8 * rms(full, last))        # ends thinned

    def test_beat_runs_only_the_drums_and_bass(self):
        full, _ = self.render(16, style="full")
        beat, info = self.render(16, style="beat")
        self.assertEqual(info["style"], "beat")
        span = slice(self.exit_ + int(BAR * RATE), self.exit_ + int(3 * BAR * RATE))
        self.assertFalse(np.allclose(full[span], beat[span], atol=1e-4))

    def test_the_stem_styles_fade_the_loops_band_in_under_the_songs_last_bar(self):
        for style in ("beat", "strip"):
            bare, _ = self.render(16, style=style, handin=0)
            mixed, info = self.render(16, style=style)
            self.assertEqual(info["handin_bars"], 1.0)
            unit = info["outro_samples"] // 4
            # nothing differs until the last bar before the exit...
            before = self.exit_ - unit // 4 - 400
            self.assertTrue(np.allclose(bare[:before], mixed[:before], atol=1e-6))
            # ...where the mix carries the loop's band, and from the exit on it is the loop alone
            gap = np.sqrt(np.mean((mixed[self.exit_ - unit // 16:self.exit_]
                                   - bare[self.exit_ - unit // 16:self.exit_]) ** 2))
            self.assertGreater(gap, 0.01)
            later = slice(self.exit_ + 400, self.exit_ + unit)
            self.assertTrue(np.allclose(bare[later], mixed[later], atol=1e-6))
        _, finfo = self.render(16, style="full")
        self.assertEqual(finfo["handin_bars"], 0.0)

    def test_it_stops_on_the_bar_line_or_fades_over_its_last_bars(self):
        stop, _ = self.render(16)
        faded, info = self.render(16, fade_bars=4)
        self.assertEqual(info["fade_bars"], 4)
        last_second = slice(len(faded) - RATE, len(faded) - int(0.05 * RATE))
        loud = slice(self.exit_ + int(BAR * RATE), self.exit_ + int(2 * BAR * RATE))
        rms = lambda y, s: float(np.sqrt(np.mean(y[s] ** 2)))   # noqa: E731
        self.assertLess(rms(faded, last_second), 0.1 * rms(faded, loud))
        # a stop is still at the loop's own level a moment before it ends
        self.assertGreater(rms(stop, last_second), 0.25 * rms(stop, loud))
        self.assertLess(float(np.abs(stop[-int(0.002 * RATE):]).max()), 1e-3)   # and ends silent
        self.assertEqual(len(stop), len(faded))

    def test_a_length_the_loop_does_not_divide_is_refused(self):
        with self.assertRaisesRegex(ValueError, "whole number"):
            outro.render(self.a, 12, self.source, 8, self.exit_bar)

    def test_an_exit_outside_the_track_is_refused(self):
        with self.assertRaisesRegex(ValueError, "outside the track"):
            outro.render(self.a, 16, self.source, 4, len(self.a.bar_lines) + 5)

    def test_an_unknown_style_is_refused(self):
        with self.assertRaisesRegex(ValueError, "style"):
            self.render(16, style="underlay")

    def test_the_report_is_plain_json(self):
        import json
        _, info = self.render(16)
        json.dumps(info)
        for key in ("exit_bar", "exit_seconds", "tail_seconds", "cut_seconds",
                    "suggested_exit_bar", "seconds_of_outro", "style", "warnings"):
            self.assertIn(key, info)

    def test_the_exit_bar_is_not_the_intros_join(self):
        audio, info = self.render(16)
        self.assertEqual(info["exit_bar"], self.exit_bar)
        self.assertAlmostEqual(info["exit_seconds"], self.exit_ / RATE, delta=0.001)
        self.assertGreater(info["cut_seconds"], 1.0)    # the faded ending is replaced


class TestTheTailRingsOut(unittest.TestCase):
    """A vocal held through the exit and a beat past it is not cut mid-word."""

    @classmethod
    def setUpClass(cls):
        x, parts, lead = song(bars=40, vocal_bars=(range(0, 0),), breakdown=range(0, 0))
        d = np.arange(int(5 * BEAT * RATE)) / RATE
        tone = (0.25 * np.sin(2 * np.pi * 880 * d)).astype(np.float32)
        at = int((lead + 19 * BAR) * RATE)
        parts = {k: v.copy() for k, v in parts.items()}
        x = x.copy()
        for y in (parts["vocals"], x):
            y[at:at + len(tone)] += tone[:, None]
        cls.x = x
        cls.a = intro.analyse(x, parts, RATE, BPM)
        cls.exit_ = int(cls.a.bar_lines[20])
        cls.source = outro.candidates(cls.a, 4, exit_bar=20)[0]

    def test_the_vocal_past_the_exit_is_in_the_file_and_then_the_loop_takes_over(self):
        audio, info = outro.render(self.a, 16, self.source, 4, 20)
        tail = int(round(info["tail_seconds"] * RATE))
        self.assertGreater(tail, 0)
        guard = int(0.002 * RATE)
        held = slice(self.exit_ + guard, self.exit_ + tail - guard - int(0.02 * RATE))
        # the held note is there, at the strength the original has it
        self.assertGreater(tone_power(audio[held]), 0.5 * tone_power(self.x[held]))
        # and once the tail is over, the loop (which has no vocal) is all that is left
        after = slice(self.exit_ + tail + int(BAR * RATE), self.exit_ + tail + int(3 * BAR * RATE))
        self.assertLess(tone_power(audio[after]), 1e-3 * tone_power(self.x[held]))


def lost_lock_song(late_s: float, bars_a: int = 24, gap_bars: int = 4, bars_b: int = 28):
    """A track with a stretch of no kicks, after which the groove comes back
    `late_s` seconds off the grid. Before the bar lines could re-lock this
    left them off the kicks for the rest of the track (a real six-minute dance
    record did exactly that: 144 of 199 bar lines more than 40 ms from a kick,
    the last 0.4 of a beat off); `test_relock` covers the fix. Here it is the
    check that such a track now comes out right."""
    xa, pa, _ = song(bars=bars_a, breakdown=range(0, 0), vocal_bars=(range(0, 0),))
    xb, pb, _ = song(bars=bars_b, breakdown=range(0, 0), vocal_bars=(range(0, 0),))
    a_len = int(bars_a * BAR * RATE)
    gap = np.zeros((int((gap_bars * BAR + late_s) * RATE), 2), np.float32)

    def cat(ya, yb):
        return np.concatenate([ya[:a_len], gap, yb])
    return cat(xa, xb), {k: cat(pa[k], pb[k]) for k in pa}


def with_drifted_end(a, from_bar: int, shift_s: float):
    """The same analysis with every bar line from `from_bar` on moved `shift_s`
    later and marked unsnapped: a grid that has drifted off the kicks near the
    end, whatever the bar following does. The exit's alignment is a safety net
    for exactly that, so it is tested against a drift put in by hand and not
    against one the following may or may not produce."""
    import dataclasses
    lines = a.bar_lines.copy()
    lines[from_bar:] += int(shift_s * a.rate)
    snapped = a.snapped.copy()
    snapped[from_bar:] = False
    return dataclasses.replace(a, bar_lines=lines, snapped=snapped, cache={})


def kick_phase_beats(a, sample: int) -> float:
    """Where `sample` falls in the beat the kicks AROUND it keep, in beats
    (0 = on a kick, +-0.5 = between two). Only the kicks within a few seconds
    count: the track's early kicks can sit on a different grid."""
    near = a.kicks[np.abs(a.kicks - sample) < 4 * RATE]
    angle = np.exp(2j * np.pi * (near - sample) / a.grid.period).mean()
    return float(np.angle(angle)) / (2 * np.pi)


def slip_across_exit(audio, info) -> float:
    """How far the outro's kicks sit from the song's, in ms, on the full mix."""
    kicks, _ = subbass.detect_kicks(audio, RATE)
    period = BEAT * RATE
    exit_ = int(round(info["exit_seconds"] * RATE))

    def phase_ms(selected):
        angle = np.exp(2j * np.pi * selected / period)
        return np.angle(angle.mean()) / (2 * np.pi) * period / RATE * 1000

    song_kicks = kicks[(kicks > exit_ - 8 * RATE) & (kicks < exit_ - RATE // 5)]
    outro_kicks = kicks[kicks > exit_ + RATE // 5]
    assert len(song_kicks) > 8 and len(outro_kicks) > 50
    return (phase_ms(outro_kicks) - phase_ms(song_kicks) + BEAT * 500) % (BEAT * 1000) - BEAT * 500


class TestAGridThatHasDrifted(unittest.TestCase):
    """The exit is aligned to the kicks it is really near, so a grid that has
    drifted by the end does not put the loop half a beat from the song."""

    @classmethod
    def setUpClass(cls):
        x, parts = lost_lock_song(0.0, bars_a=24, gap_bars=4, bars_b=28)
        cls.good = intro.analyse(x, parts, RATE, BPM)
        cls.last = len(cls.good.bar_lines) - 1
        cls.a = with_drifted_end(cls.good, 40, 0.20)

    def test_the_test_track_really_has_a_drifted_grid(self):
        # Otherwise the tests below prove nothing.
        beat_ms = self.a.grid.period / RATE * 1000
        off = abs(kick_phase_beats(self.a, int(self.a.bar_lines[self.last]))) * beat_ms
        self.assertGreater(off, 100, f"the last bar line is only {off:.0f} ms from a kick")

    def test_the_exit_is_moved_onto_the_kicks(self):
        line = int(self.a.bar_lines[self.last])
        exit_, _ = outro.resolve_exit(self.a, self.last)
        self.assertGreater(abs(exit_ - line) / RATE * 1000, 150)
        # within the detector's onset-to-attack lag (up to ~30 ms) of a kick
        beat_ms = self.a.grid.period / RATE * 1000
        self.assertLess(abs(kick_phase_beats(self.a, exit_)) * beat_ms, 40)

    def test_the_outro_keeps_the_beat_across_the_exit(self):
        source = outro.candidates(self.a, 4, exit_bar=self.last)[0]
        audio, info = outro.render(self.a, 16, source, 4, self.last)
        self.assertGreater(abs(info["exit_moved_ms"]), 150)
        self.assertTrue([w for w in info["warnings"] if "drifted" in w])
        self.assertLess(abs(slip_across_exit(audio, info)), 12.0)

    def test_without_the_alignment_the_beat_would_skip(self):
        # Mutation check, run live: put the exit back on the bar line and the
        # same measurement shows the drift the alignment removes.
        source = outro.candidates(self.a, 4, exit_bar=self.last)[0]
        with mock.patch.object(outro, "aligned_exit",
                               lambda a, bar: int(a.bar_lines[bar])):
            audio, info = outro.render(self.a, 16, source, 4, self.last)
        self.assertGreater(abs(slip_across_exit(audio, info)), 100.0)

    def test_a_grid_that_has_not_drifted_is_left_alone(self):
        x, parts, _ = fading_song()
        a = intro.analyse(x, parts, RATE, BPM)
        exit_bar = a.suggested_exit_bar
        exit_, _ = outro.resolve_exit(a, exit_bar)
        self.assertLessEqual(abs(exit_ - int(a.bar_lines[exit_bar])) / RATE * 1000, 25)
        source = outro.candidates(a, 4, exit_bar=exit_bar)[0]
        _, info = outro.render(a, 8, source, 4, exit_bar)
        self.assertFalse([w for w in info["warnings"] if "drifted" in w])


class TestATrackThatUsedToLoseItsGrid(unittest.TestCase):
    """A stretch with no kicks and the groove back 0.2 s off the grid: the bar
    lines used to lose the kicks for good, and now re-lock (see `test_relock`).
    The outro on such a track must come out right either way."""

    @classmethod
    def setUpClass(cls):
        cls.x, cls.parts = lost_lock_song(0.20)
        cls.a = intro.analyse(cls.x, cls.parts, RATE, BPM)
        cls.last = len(cls.a.bar_lines) - 1

    def test_the_last_bar_line_is_on_a_kick(self):
        beat_ms = self.a.grid.period / RATE * 1000
        off = abs(kick_phase_beats(self.a, int(self.a.bar_lines[self.last]))) * beat_ms
        self.assertLess(off, 40, f"the last bar line is {off:.0f} ms from a kick")

    def test_the_outro_keeps_the_beat_and_the_exit_barely_moves(self):
        source = outro.candidates(self.a, 4, exit_bar=self.last)[0]
        audio, info = outro.render(self.a, 16, source, 4, self.last)
        self.assertLess(abs(info["exit_moved_ms"]), 30)
        self.assertLess(abs(slip_across_exit(audio, info)), 12.0)


class TestNothingNewClips(unittest.TestCase):
    """The loop is the stems summed, which can run louder than the mix they
    came from; the new material is brought under full scale and the original is
    never touched."""

    @classmethod
    def setUpClass(cls):
        x, parts, _ = fading_song()
        # stems from a separation that came out hot: 1.4x the mix's own level
        cls.x = x
        cls.parts = {k: (v * 1.4).astype(np.float32) for k, v in parts.items()}
        cls.a = intro.analyse(x, cls.parts, RATE, BPM)
        cls.exit_bar = cls.a.suggested_exit_bar
        cls.exit_ = int(cls.a.bar_lines[cls.exit_bar])
        cls.source = outro.candidates(cls.a, 4, exit_bar=cls.exit_bar)[0]

    def test_the_hot_stems_would_clip_a_loop_left_alone(self):
        raw = self.a.instrumental
        self.assertGreater(float(np.abs(raw).max()), 1.0)

    def test_the_outro_stays_under_full_scale_in_every_style(self):
        for style in outro.STYLES:
            audio, info = outro.render(self.a, 16, self.source, 4, self.exit_bar, style=style)
            self.assertLessEqual(float(np.abs(audio).max()), 1.0, style)
            self.assertLess(info["loop_gain_db"], 0.0, style)

    def test_the_original_is_still_untouched(self):
        audio, _ = outro.render(self.a, 16, self.source, 4, self.exit_bar, style="beat")
        safe = self.exit_ - int(0.5 * RATE) - 4 * int(self.a.grid.period)
        self.assertTrue(np.allclose(audio[:safe], self.x[:safe], atol=1e-6))

    def test_a_loop_that_fits_is_not_turned_down(self):
        x, parts, _ = fading_song()
        a = intro.analyse(x, parts, RATE, BPM)
        source = outro.candidates(a, 4, exit_bar=a.suggested_exit_bar)[0]
        _, info = outro.render(a, 8, source, 4, a.suggested_exit_bar)
        self.assertEqual(info["loop_gain_db"], 0.0)


class TestTheLoopIsJudgedAgainstWhatLeadsUpToTheExit(unittest.TestCase):
    def test_the_reference_is_the_bars_before_the_exit_not_the_start(self):
        # Busy hats only in the bars before bar 24: the loop that feels like
        # them is the one near them, not the plain groove from the start.
        x, parts, _ = song(bars=40, breakdown=range(0, 0), vocal_bars=(range(0, 0),),
                           busy_bars=set(range(16, 24)))
        a = intro.analyse(x, parts, RATE, BPM)
        near = outro.candidates(a, 4, count=3, exit_bar=24)[0]
        self.assertGreaterEqual(near.bar, 16)
        self.assertLessEqual(near.bar, 20)


class TestTheCommand(unittest.TestCase):
    """The whole path from a file, with the separation standing in for Demucs."""

    def run_cli(self, argv, parts):
        import contextlib
        import io
        from loudnesslab import cli
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(intro, "separate", return_value=parts), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_it_writes_each_length_and_never_touches_the_original(self):
        from loudnesslab import decode
        x, parts, _ = fading_song(bars=36, fade_from=24)
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            source = write.write(tmp / "Song", x, RATE, fmt="flac")
            before = source.read_bytes()
            out = tmp / "out"
            code, printed, _ = self.run_cli(
                ["outro", str(source), "--bpm", "120", "--bars", "8", "16", "--out", str(out)], parts)
            self.assertEqual(code, 0, printed)
            self.assertEqual(sorted(p.name for p in out.iterdir()),
                             ["Song (Outro 16).flac", "Song (Outro 8).flac"])
            self.assertEqual(source.read_bytes(), before)
            a = intro.analyse(x, parts, RATE, BPM)
            exit_ = a.bar_lines[a.suggested_exit_bar] / RATE
            made = decode.decode(out / "Song (Outro 8).flac")
            self.assertAlmostEqual(len(made) / RATE, exit_ + 8 * BAR, delta=0.05)

    def test_json_mode_reports_the_outro_event(self):
        import json
        x, parts, _ = fading_song(bars=36, fade_from=24)
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            source = write.write(tmp / "Song", x, RATE, fmt="flac")
            code, printed, _ = self.run_cli(
                ["outro", str(source), "--bpm", "120", "--bars", "8", "--json",
                 "--style", "beat", "--fade-bars", "2", "--out", str(tmp / "o")], parts)
            self.assertEqual(code, 0)
            events = [json.loads(line) for line in printed.splitlines()]
            made = [e for e in events if e["event"] == "outro"][0]
            self.assertEqual(made["style"], "beat")
            self.assertEqual(made["fade_bars"], 2.0)

    def test_list_sources_works_for_the_outro_and_the_intro(self):
        x, parts, _ = fading_song(bars=36, fade_from=24)
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            source = write.write(tmp / "Song", x, RATE, fmt="flac")
            for command in ("outro", "intro"):
                code, printed, err = self.run_cli(
                    [command, str(source), "--bpm", "120", "--list-sources",
                     "--out", str(tmp / "o")], parts)
                self.assertEqual(code, 0, err)
                self.assertIn("best", printed)
                self.assertFalse((tmp / "o").exists())      # lists, writes nothing


class TestInTheSession(unittest.TestCase):
    def prepared(self, tmp):
        x, parts, _ = fading_song()
        source = write.write(Path(tmp) / "Song", x, RATE, fmt="flac")
        session = intro.Session(out_dir=Path(tmp) / "intro-out")
        events = []
        with mock.patch.object(intro, "separate", return_value=parts):
            session.handle({"id": 1, "cmd": "prepare", "path": str(source), "bpm": 120},
                           events.append)
        return session, events

    def test_prepare_reports_where_the_song_would_leave(self):
        with tempfile.TemporaryDirectory() as tmp:
            _, events = self.prepared(tmp)
            prepared = [e for e in events if e["event"] == "prepared"][0]
            self.assertIn(prepared["suggested_exit_bar"], (28, 29, 30))
            self.assertIn("exit_reason", prepared)
            self.assertIn("exit_seconds", prepared)
            self.assertIn("tail_seconds", prepared)

    def test_outro_sources_lists_loops_judged_at_the_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            session, _ = self.prepared(tmp)
            events = []
            session.handle({"id": 2, "cmd": "outro_sources", "loop_bars": 4}, events.append)
            found = [e for e in events if e["event"] == "outro_sources"][0]
            self.assertTrue(found["sources"])
            self.assertEqual(events[-1]["event"], "done")

    def test_outro_render_writes_a_file_and_reports_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            session, _ = self.prepared(tmp)
            events = []
            out = Path(tmp) / "outro-out"
            session.handle({"id": 3, "cmd": "outro_render", "bars": 8, "loop_bars": 4,
                            "style": "strip", "out": str(out), "format": "flac"}, events.append)
            made = [e for e in events if e["event"] == "outro"][0]
            self.assertTrue(Path(made["output"]).exists())
            self.assertIn("(Outro 8)", made["output"])
            self.assertEqual(made["style"], "strip")
            self.assertEqual(events[-1]["event"], "done")
            self.assertTrue([e for e in events if e["event"] == "render_envelope"])

    def test_an_exit_the_track_does_not_have_is_an_error_not_a_crash(self):
        with tempfile.TemporaryDirectory() as tmp:
            session, _ = self.prepared(tmp)
            events = []
            session.handle({"id": 4, "cmd": "outro_render", "bars": 8, "loop_bars": 4,
                            "exit_bar": 9999}, events.append)
            self.assertEqual(events[-1]["event"], "error")
            self.assertIn("outside the track", events[-1]["message"])

    def test_it_needs_a_prepared_track(self):
        session = intro.Session()
        events = []
        session.handle({"id": 5, "cmd": "outro_sources"}, events.append)
        self.assertEqual(events[-1]["event"], "error")
        self.assertEqual(events[-1]["code"], "no_track")


if __name__ == "__main__":
    unittest.main()
