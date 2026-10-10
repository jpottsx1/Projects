"""The beat check: a finished edit's kicks read back across its seams.

On the intro tests' songs (an exact grid) every seam and join should read
as on the beat, to the detector's own jitter; an edit broken on purpose
should read as broken, by about the amount it was broken by.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "tests"))
from loudnesslab import intro, outro, timing  # noqa: E402
from test_intro import BPM, RATE, song  # noqa: E402
from test_outro import fading_song  # noqa: E402

# Measured (2026-10-09): 0.2-0.4 ms at the joins and exits of every style,
# up to 1.5 ms at a seam where a stem comes in and moves the detector.
JITTER_MS = 2.0


class TestAnIntro(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        x, parts, _ = song()
        cls.a = intro.analyse(x, parts, RATE, BPM)
        cls.source = intro.candidates(cls.a, 4)[0]

    def test_every_style_reads_as_on_the_beat(self):
        for style in ("full", "build", "beat"):
            _, info = intro.render(self.a, 16, self.source, 4, style=style)
            t = info["timing"]
            self.assertLess(abs(t["join_offset_ms"]), JITTER_MS, style)
            self.assertLess(abs(t["join_tempo_step_pct"]), 0.1, style)
            self.assertEqual(len(t["seams"]), 3, style)
            self.assertLess(abs(t["worst_seam_ms"]), JITTER_MS, style)
            self.assertFalse([w for w in info["warnings"] if "beat" in w], style)

    def test_drums_entering_after_silence_are_met_on_the_beat(self):
        # Eight bars with no drums, then the song's drums come in at the join:
        # the case where a bar line read off the drum stem is least like the
        # others (see `intro.kick_offset`). It arrived 5 ms late before the
        # bar lines were found on the kicks every time (`intro.attack`).
        x, parts, _ = song(soft_bars=range(0, 8), vocal_bars=(range(8, 16),),
                           lead_in_vocal_beats=2)
        a = intro.analyse(x, parts, RATE, BPM)
        source = intro.candidates(a, 4)[0]
        for style in ("full", "build"):
            _, info = intro.render(a, 16, source, 4, style=style)
            self.assertLess(abs(info["timing"]["join_offset_ms"]), JITTER_MS, style)

    def test_a_join_ten_ms_late_is_caught(self):
        audio, info = intro.render(self.a, 16, self.source, 4, style="full")
        j = info["intro_samples"] + round(info["lead_seconds"] * RATE)
        d = int(0.010 * RATE)
        late = audio.copy()
        late[j + d:] = audio[j:-d]
        late[j:j + d] = 0
        report, warnings = timing.check(late, RATE, self.a.grid.period, [("join", j, None)], "join")
        self.assertAlmostEqual(report["join_offset_ms"], 10.0, delta=JITTER_MS)
        self.assertTrue(any(w.startswith("the beat lands") and w.endswith("ms late at the join")
                            for w in warnings), warnings)

    def test_a_song_that_speeds_up_after_the_join_is_caught(self):
        audio, info = intro.render(self.a, 16, self.source, 4, style="full")
        j = info["intro_samples"] + round(info["lead_seconds"] * RATE)
        from scipy.signal import resample_poly
        faster = np.concatenate([audio[:j], resample_poly(audio[j:], 98, 100, axis=0)])
        report, warnings = timing.check(faster, RATE, self.a.grid.period, [("join", j, None)], "join")
        self.assertAlmostEqual(report["join_tempo_step_pct"], -2.0, delta=0.3)
        self.assertTrue(any("faster after the join" in w for w in warnings), warnings)

    def test_too_few_kicks_is_said_not_guessed(self):
        silent = np.zeros((RATE * 20, 2), dtype=np.float32)
        report, warnings = timing.check(silent, RATE, self.a.grid.period,
                                        [("join", RATE * 10, None)], "join")
        self.assertIsNone(report["join_offset_ms"])
        self.assertTrue(any("listen to it" in w for w in warnings))


class TestAnOutro(unittest.TestCase):
    def test_every_style_reads_as_on_the_beat(self):
        x, parts, _ = fading_song()
        a = intro.analyse(x, parts, RATE, BPM)
        source = outro.candidates(a, 4, exit_bar=a.suggested_exit_bar)[0]
        for style in outro.STYLES:
            _, info = outro.render(a, 16, source, 4, style=style)
            t = info["timing"]
            self.assertLess(abs(t["exit_offset_ms"]), JITTER_MS, style)
            self.assertLess(abs(t["worst_seam_ms"]), JITTER_MS, style)
            self.assertFalse([w for w in info["warnings"] if "beat" in w], style)


if __name__ == "__main__":
    unittest.main()
