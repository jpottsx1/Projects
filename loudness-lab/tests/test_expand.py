"""Putting dynamic range back: the two stages, and what separates them.

The fixtures matter here more than usual. "Over-compressed" is not one
thing, and a fixture squashed the wrong way tests the wrong stage: a slow
compressor lowers the average and leaves the peaks, which RAISES crest, so
a transient stage measured against one would look like it was fixing
something it had not broken. So there are two fixtures, made two ways, and
each stage is held to the damage it is meant to repair.
"""

from __future__ import annotations

import unittest

import numpy as np
from scipy.signal import butter, sosfiltfilt

from loudnesslab import bs1770, expand

from tests.test_subbass import RATE, programme


def sectioned(seconds: float = 60.0, breakdown_db: float = 9.0) -> np.ndarray:
    """A track with macro structure: loud, a breakdown, loud again."""
    x, _ = programme(seconds=seconds, breakdown=False)
    shape = np.ones(x.shape[0])
    shape[int(20 * RATE):int(32 * RATE)] = 10 ** (-breakdown_db / 20)
    return (x * shape[:, None]).astype(np.float32)


def slow_compressed(x: np.ndarray, ratio: float = 4.0,
                    threshold_db: float = -20.0) -> np.ndarray:
    """Macro damage: a slow compressor riding the whole mix.

    This is what takes the difference between a verse and a chorus out. It
    barely touches the peaks, so it lowers LRA and does not lower crest.
    """
    envelope = sosfiltfilt(butter(2, 1.0, btype="low", fs=RATE, output="sos"),
                           np.abs(x.mean(axis=1)))
    over = np.maximum(20 * np.log10(np.maximum(envelope, 1e-9)) - threshold_db, 0.0)
    return (x * (10 ** (-over * (1 - 1 / ratio) / 20))[:, None]).astype(np.float32)


def peak_limited(x: np.ndarray, drive: float = 2.2,
                 ceiling: float = 0.9) -> np.ndarray:
    """Micro damage: a fast limiter flattening the attacks.

    This is what takes the punch out. It lowers crest and leaves LRA more
    or less where it was.
    """
    driven = (x / np.abs(x).max() * 0.98 * drive).astype(np.float32)
    envelope = sosfiltfilt(butter(2, 300.0, btype="low", fs=RATE, output="sos"),
                           np.abs(driven.mean(axis=1)))
    gain = np.minimum(ceiling / np.maximum(envelope, 1e-9), 1.0)
    gain = sosfiltfilt(butter(2, 200.0, btype="low", fs=RATE, output="sos"), gain)
    return (driven * np.clip(gain, 0, 1)[:, None]).astype(np.float32)


class TestTheFixturesDamageWhatTheyClaimTo(unittest.TestCase):
    """If these drift, every measurement below is against the wrong thing."""

    def test_a_slow_compressor_costs_range_and_not_crest(self):
        clean = sectioned()
        squashed = slow_compressed(clean)
        before, after = bs1770.measure(clean), bs1770.measure(squashed)
        self.assertLess(after["lra"], before["lra"] - 2.0)
        # Up, if anything: the peaks survived and the average came down.
        self.assertGreater(after["crest_db"], before["crest_db"] - 0.5)

    def test_a_peak_limiter_costs_crest_and_not_range(self):
        clean = sectioned()
        limited = peak_limited(clean)
        before, after = bs1770.measure(clean), bs1770.measure(limited)
        self.assertLess(after["crest_db"], before["crest_db"] - 1.0)
        self.assertGreater(after["lra"], before["lra"] - 1.5)


class TestRestoreRange(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.squashed = slow_compressed(sectioned())
        cls.lra = bs1770.measure(cls.squashed)["lra"]

    def test_it_reaches_the_target_it_was_given(self):
        """Not approximately. The stretch is linear in the short-term
        loudness around the 95th percentile, so the range it produces is
        the range asked for."""
        for target in (7.0, 9.0):
            with self.subTest(target=target):
                _, report = expand.restore_range(self.squashed, RATE,
                                                 target_lra=target)
                self.assertTrue(report["applied"])
                self.assertAlmostEqual(report["lra_after"], target, delta=0.35)

    def test_it_only_ever_turns_things_down(self):
        """A loudness-war master has no headroom left -- that is what made
        it one. A stage that raised the loud parts would clip, or be
        trimmed straight back out, which is the same thing done twice."""
        y, report = expand.restore_range(self.squashed, RATE, target_lra=9.0)
        self.assertLessEqual(float(np.abs(y).max()),
                             float(np.abs(self.squashed).max()) + 1e-6)
        self.assertGreater(report["max_attenuation_db"], 0.0)

    def test_the_loudest_passages_are_left_alone(self):
        """The anchor is the 95th percentile, so the drop comes out of this
        stage untouched and gets its impact from everything else moving."""
        y, _ = expand.restore_range(self.squashed, RATE, target_lra=9.0)
        applied = _gain_by_second(self.squashed, y)
        loud = np.concatenate([applied[10:19], applied[35:55]])
        self.assertLess(abs(float(loud.mean())), 0.35)

    def test_the_breakdown_is_what_moves(self):
        y, _ = expand.restore_range(self.squashed, RATE, target_lra=9.0)
        applied = _gain_by_second(self.squashed, y)
        self.assertLess(float(applied[23:31].mean()), -1.5)

    def test_the_attenuation_sits_over_the_breakdown_and_not_after_it(self):
        """Where the gain lands, to within a second.

        A 3 s block beginning at t describes t to t+3, so a curve indexed
        by block STARTS is a second and a half late everywhere -- late
        enough to turn a breakdown down after it has ended and to hold it
        down over the opening of the drop. The fix is to index by block
        centres, and this is what checks it was done: the centre of mass of
        the attenuation against the centre of the breakdown.

        Written this way because the obvious tests do not catch it. Asking
        whether seconds 23-31 are attenuated passes either way -- a second
        and a half of slack sits comfortably inside an eight-second window.
        """
        y, _ = expand.restore_range(self.squashed, RATE, target_lra=9.0)
        pulled = np.maximum(-_gain_by_second(self.squashed, y), 0.0)
        seconds = np.arange(pulled.size) + 0.5
        centre = float((seconds * pulled).sum() / pulled.sum())
        self.assertAlmostEqual(centre, 26.0, delta=0.8)   # 20 s to 32 s

    def test_the_gain_is_out_of_the_way_before_the_drop_lands(self):
        """The one moment the attenuation must not still be there.

        A forward-only slew limiter cannot start recovering until the music
        has already come back, so it holds the breakdown's gain across the
        opening of the drop -- taking the impact out at exactly the point
        the stage exists to give it.

        This needs a fixture that binds the limiter, which a mild one does
        not: the gain is a scaled 3 s moving average, and on ordinary
        material its slope is already under the limit, where the two
        directions differ by 0.07 dB and any test of this would pass either
        way. An earlier version of this test used the mild fixture and did
        exactly that -- it passed with the backward pass deleted.

        So: a master squashed to about 1 LU, asked for 12. Forwards-only
        measures 6 dB behind at the drop and takes seven seconds to clear.
        """
        flat = slow_compressed(sectioned(), ratio=10.0, threshold_db=-34.0)
        y, _ = expand.restore_range(flat, RATE, target_lra=12.0,
                                    max_attenuation_db=9.0)
        applied = _gain_by_second(flat, y)
        self.assertLess(float(applied[25]), -4.0)     # deep in the breakdown
        # The breakdown ends at 32 s. Two seconds later it is nearly clear.
        self.assertGreater(float(applied[34]), -1.5)

    def test_it_cannot_move_faster_than_its_slew_limit(self):
        """The second guard against pumping, after the 3 s window."""
        y, _ = expand.restore_range(self.squashed, RATE, target_lra=12.0,
                                    slew_db_per_s=1.5)
        applied = _gain_by_second(self.squashed, y)
        self.assertLess(float(np.abs(np.diff(applied)).max()), 1.5 + 0.2)

    def test_a_track_already_at_the_target_is_not_touched(self):
        y, report = expand.restore_range(self.squashed, RATE, target_lra=4.0)
        self.assertFalse(report["applied"])
        self.assertIn("already", report["note"])
        np.testing.assert_array_equal(y, self.squashed)

    def test_a_track_close_enough_to_the_target_is_not_touched_either(self):
        """The same margin the sub stage uses, and for the same reason.

        Measured need: CD2 of the 1999 corpus sits at LRA 6.49 against a
        target of 7.0. That is a stretch of 0.079 -- half a decibel at the
        quietest point of the record, which is arithmetic rather than a
        restoration. Without the margin the stage reports it as work done.
        """
        just_under = self.lra + 0.3
        y, report = expand.restore_range(self.squashed, RATE,
                                         target_lra=just_under, margin_lu=0.5)
        self.assertFalse(report["applied"])
        self.assertIn("within", report["note"])
        np.testing.assert_array_equal(y, self.squashed)
        # And past the margin it acts again, so this is a threshold and not
        # a way of never doing anything.
        _, acted = expand.restore_range(self.squashed, RATE,
                                        target_lra=self.lra + 0.8,
                                        margin_lu=0.5)
        self.assertTrue(acted["applied"])

    def test_hitting_the_floor_is_reported_rather_than_hidden(self):
        """Raising the target past what the cap allows should say so, or a
        setting that does nothing looks like a setting that did."""
        _, report = expand.restore_range(self.squashed, RATE, target_lra=30.0,
                                         max_attenuation_db=3.0)
        self.assertTrue(report["capped"])
        self.assertAlmostEqual(report["max_attenuation_db"], 3.0, places=6)
        self.assertIn("floor", report["note"])

    def test_something_too_short_to_measure_is_declined(self):
        brief = np.zeros((RATE // 2, 2), dtype=np.float32)
        y, report = expand.restore_range(brief, RATE)
        self.assertFalse(report["applied"])
        np.testing.assert_array_equal(y, brief)

    def test_a_sub_gate_opening_is_not_given_a_gain_of_its_own(self):
        """An ungated block has no loudness, so it has no gain of its own.

        Letting it take the floor instead puts an audible ramp on the front
        of every track that opens quietly -- several dB of attenuation
        applied to, and then lifted off, something nobody asked to be
        touched.

        The opening here is noise below the -70 LUFS absolute gate rather
        than digital silence, for two reasons: it is what a vinyl rip
        actually looks like, and a gain applied to exact zeros cannot be
        read back off the file, so a test using silence measures nothing.
        An earlier version did, and passed with the hold deleted.
        """
        x = sectioned()
        quiet = np.random.default_rng(0).standard_normal((int(4 * RATE), 2))
        x[:int(4 * RATE)] = (quiet * 10 ** (-85 / 20)).astype(np.float32)
        squashed = slow_compressed(x)
        y, report = expand.restore_range(squashed, RATE, target_lra=9.0,
                                         max_attenuation_db=6.0)
        self.assertTrue(report["applied"])
        opening = _gain_by_second(squashed, y)[0:3]
        self.assertGreater(float(opening.mean()), -0.75)


class TestRestoreTransients(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.limited = peak_limited(sectioned())

    def test_it_puts_crest_back(self):
        """Crest IS the measurement for this stage, unlike the kick punch,
        where a band-limited change lasting eight milliseconds leaves the
        peak-to-loudness ratio where it found it. This one is broadband: a
        crest that did not move means nothing happened."""
        _, report = expand.restore_transients(self.limited, RATE,
                                              amount_db=3.0, min_crest_db=99)
        self.assertGreater(report["crest_after"], report["crest_before"] + 0.7)

    def test_about_half_a_dB_of_crest_per_dB_asked_for(self):
        """Measured, and pinned so it cannot drift quietly. The asking
        figure is a ceiling on the gain at an onset, not a promise about
        the statistic, and the two are not the same number -- so anyone
        setting this from a crest target needs to know the exchange rate."""
        rates = []
        for amount in (2.0, 3.0, 6.0):
            _, report = expand.restore_transients(self.limited, RATE,
                                                  amount_db=amount,
                                                  min_crest_db=99)
            rates.append((report["crest_after"] - report["crest_before"]) / amount)
        for rate in rates:
            self.assertGreater(rate, 0.35)
            self.assertLess(rate, 0.75)

    def test_it_raises_peaks_without_raising_loudness(self):
        """The signature of crest restoration. A stage that moved both
        would just be a volume control."""
        _, report = expand.restore_transients(self.limited, RATE,
                                              amount_db=3.0, min_crest_db=99)
        self.assertGreater(report["peak_change_db"], 1.0)
        self.assertLess(abs(report["lufs_change_db"]), 0.6)

    def test_a_sustained_tone_is_left_alone(self):
        """The property that separates this from an expander. Two envelopes
        of a steady signal read the same, so their ratio is one and the
        gain is zero -- it cannot breathe, because it cannot act on
        anything that is not an onset."""
        t = np.arange(int(RATE * 8)) / RATE
        tone = np.column_stack([0.5 * np.sin(2 * np.pi * 440 * t)] * 2
                               ).astype(np.float32)
        _, report = expand.restore_transients(tone, RATE, amount_db=6.0,
                                              min_crest_db=99)
        # The file's own start is a transient, and the only one there is.
        self.assertLess(report["lifted_fraction"], 0.02)
        self.assertLess(abs(report["lufs_change_db"]), 0.05)

    def test_hiss_between_tracks_is_not_given_transients(self):
        noise = (np.random.default_rng(0).standard_normal((RATE * 4, 2))
                 * 1e-4).astype(np.float32)
        _, report = expand.restore_transients(noise, RATE, amount_db=6.0,
                                              min_crest_db=99)
        self.assertEqual(report["max_lift_db"], 0.0)

    def test_it_never_turns_anything_down(self):
        """filtfilt overshoots a step, and an overshoot going the other way
        would be an expander pulling the quiet parts down -- the exact
        behaviour this stage exists to avoid."""
        y, _ = expand.restore_transients(self.limited, RATE, amount_db=3.0,
                                         min_crest_db=99)
        ratio = np.abs(y) / np.maximum(np.abs(self.limited), 1e-9)
        self.assertGreaterEqual(float(ratio.min()), 1.0 - 1e-6)

    def test_a_track_that_is_already_peaky_is_declined(self):
        """Policy declining to act. Most of what a good policy does."""
        clean = (sectioned() * 0.5).astype(np.float32)
        crest = bs1770.measure(clean)["crest_db"]
        y, report = expand.restore_transients(clean, RATE, amount_db=3.0,
                                              min_crest_db=crest - 0.5)
        self.assertFalse(report["applied"])
        self.assertIn("peaky enough", report["note"])
        np.testing.assert_array_equal(y, clean)

    def test_the_stereo_image_does_not_move(self):
        """One gain, applied to both channels. A gain computed per channel
        would ride each side separately and pull a hard-panned hit towards
        the middle every time it struck."""
        panned = self.limited.copy()
        panned[:, 1] *= 0.25
        y, _ = expand.restore_transients(panned, RATE, amount_db=6.0,
                                         min_crest_db=99)
        was = np.abs(panned[:, 0]).sum() / max(np.abs(panned[:, 1]).sum(), 1e-9)
        now = np.abs(y[:, 0]).sum() / max(np.abs(y[:, 1]).sum(), 1e-9)
        self.assertAlmostEqual(was, now, delta=0.01)

    def test_a_transient_on_one_side_only_is_still_heard(self):
        """The detector sums the channels, so it does not matter which side
        a hit is on. Driving it from one channel would miss every
        hard-panned crack and clap in the record -- silently, because the
        gain it does apply still goes to both sides, so the image still
        does not move and nothing looks wrong.

        Measured at a known onset in the middle of the file, not by
        `max_lift_db`: the start of any file is a transient in its own
        right, so the maximum is reached whatever the detector can hear.
        That is what made an earlier version of this test pass with the
        detector wired to one channel.
        """
        t = np.arange(int(RATE * 4)) / RATE
        bed = 0.25 * np.sin(2 * np.pi * 220 * t)
        track = np.column_stack([bed, bed]).astype(np.float32)
        onsets = (1.0, 2.0, 3.0)
        span = np.arange(int(0.05 * RATE))
        crack = (0.6 * np.exp(-span / (RATE * 0.004))).astype(np.float32)
        for onset in onsets:
            i = int(onset * RATE)
            track[i:i + span.size, 1] += crack        # right channel only

        y, report = expand.restore_transients(track, RATE, amount_db=6.0,
                                              min_crest_db=99)
        self.assertTrue(report["applied"])
        gain = 20 * np.log10(np.maximum(np.abs(y[:, 0]), 1e-12)
                             / np.maximum(np.abs(track[:, 0]), 1e-12))
        gain = np.nan_to_num(gain)
        for onset in onsets:
            i = int(onset * RATE)
            at = float(np.percentile(gain[i:i + int(0.02 * RATE)], 90))
            self.assertGreater(at, 2.0, f"nothing applied at {onset} s")

    def test_asking_for_nothing_does_nothing(self):
        y, report = expand.restore_transients(self.limited, RATE, amount_db=0.0)
        self.assertFalse(report["applied"])
        np.testing.assert_array_equal(y, self.limited)


class TestTheTwoStagesAreSeparate(unittest.TestCase):
    """The argument the module is built on: one gain cannot serve both
    timescales, and two gains each stay in their own."""

    def test_the_range_stage_does_not_move_crest(self):
        squashed = slow_compressed(sectioned())
        y, _ = expand.restore_range(squashed, RATE, target_lra=9.0)
        before, after = bs1770.measure(squashed), bs1770.measure(y)
        self.assertLess(abs(after["crest_db"] - before["crest_db"]), 1.5)

    def test_the_transient_stage_does_not_move_range(self):
        limited = peak_limited(sectioned())
        y, _ = expand.restore_transients(limited, RATE, amount_db=3.0,
                                         min_crest_db=99)
        before, after = bs1770.measure(limited), bs1770.measure(y)
        self.assertLess(abs(after["lra"] - before["lra"]), 1.0)


class TestSummary(unittest.TestCase):

    def test_a_batch_that_needed_nothing_says_so(self):
        text = expand.summarise(
            [expand._blank_range("already 9.0 LU, at or above the target")],
            [expand._blank_transient("crest is already 14.0 dB")])
        self.assertIn("no track needed it", text)
        self.assertIn("already peaky enough", text)

    def test_nothing_asked_for_is_distinct_from_nothing_needed(self):
        text = expand.summarise([], [])
        self.assertIn("not asked for", text)


def _gain_by_second(before: np.ndarray, after: np.ndarray) -> np.ndarray:
    """The gain actually applied, read off the two files a second at a time."""
    ratio = 20 * np.log10(np.maximum(np.abs(after).max(axis=1), 1e-12)
                          / np.maximum(np.abs(before).max(axis=1), 1e-12))
    seconds = before.shape[0] // RATE
    return np.array([np.median(ratio[s * RATE:(s + 1) * RATE])
                     for s in range(seconds)])


if __name__ == "__main__":
    unittest.main()
