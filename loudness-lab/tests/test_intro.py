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
import sys
import tempfile
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
         restless=range(0, 0)):
    """(original, stems, join in seconds). Bar 0 starts at `pickup_beats`
    beats in: before it, only a vocal pickup."""
    rng = np.random.default_rng(seed)
    lead = pickup_beats * BEAT
    n = int((lead + bars * BAR + 2.0) * RATE)
    drums, bass, other, vocals = (np.zeros(n) for _ in range(4))
    quiet = {b for b in breakdown}
    voiced = {b for r in vocal_bars for b in r}
    for bar in range(bars):
        for beat in range(4):
            t = lead + bar * BAR + beat * BEAT
            if bar not in quiet:
                fx._place(drums, t, fx._kick(int(0.3 * RATE), rng) * 0.9)
                fx._place(drums, t + BEAT / 2, fx._hat(int(0.08 * RATE), rng) * 0.25)
                gain = 0.7 if (beat == 0 or not accent) else 0.3
                fx._place(bass, t, gain * fx._pluck(int(BEAT * RATE), 55.0, 0.25))
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
        join_out = (8 // 4) * source.length + round(info["lead_seconds"] * RATE)
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
