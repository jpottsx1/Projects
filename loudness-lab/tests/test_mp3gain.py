"""Lossless gain tests.

This is the only module that writes to audio files, so the bar is higher:
every claim it makes -- exact dB steps, byte-exact reversal, untouched ID3 --
is checked against real encoder output rather than asserted.
"""

from __future__ import annotations

import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from loudnesslab import bs1770, decode, mp3gain  # noqa: E402

RATE = 44100
HAVE_FFMPEG = shutil.which("ffmpeg") is not None
HAVE_LAME = shutil.which("lame") is not None


def _programme(seconds: float = 8.0) -> np.ndarray:
    """Something with real spectral content; a pure tone is too easy."""
    t = np.arange(int(seconds * RATE)) / RATE
    rng = np.random.default_rng(3)
    beat = np.mod(t, 0.5)
    kick = np.sin(2 * np.pi * 55 * beat) * np.exp(-beat * 24)
    bass = 0.5 * np.sin(2 * np.pi * 82 * t)
    hiss = 0.05 * rng.standard_normal(t.size)
    mix = np.stack([kick + bass + hiss, kick + bass + 0.05 * rng.standard_normal(t.size)], axis=1)
    return mix / np.abs(mix).max() * 0.7


def _write_wav(path: Path, x: np.ndarray) -> None:
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())


def _encode(wav: Path, mp3: Path, protected: bool = False) -> None:
    command = ["lame", "--quiet", "-b", "192"]
    if protected:
        command.append("-p")
    subprocess.run([*command, str(wav), str(mp3)], check=True)


def _id3_with_geob(payload: bytes) -> bytes:
    """A minimal ID3v2.3 tag carrying a GEOB frame, as Serato writes."""
    frame = b"GEOB" + struct.pack(">I", len(payload)) + b"\x00\x00" + payload
    size = len(frame)
    syncsafe = bytes(((size >> 21) & 0x7F, (size >> 14) & 0x7F,
                      (size >> 7) & 0x7F, size & 0x7F))
    return b"ID3" + b"\x03\x00" + b"\x00" + syncsafe + frame


@unittest.skipUnless(HAVE_LAME and HAVE_FFMPEG, "lame/ffmpeg not installed")
class TestLosslessGain(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        wav = root / "source.wav"
        _write_wav(wav, _programme())
        cls.plain = root / "plain.mp3"
        cls.protected = root / "protected.mp3"
        _encode(wav, cls.plain)
        _encode(wav, cls.protected, protected=True)

        # A real track starts and ends in digital silence. Encoders emit
        # empty granules there, and those must not be able to hold the whole
        # file hostage when it is asked to attenuate.
        padded = root / "padded.wav"
        quiet = np.zeros((int(1.5 * RATE), 2))
        _write_wav(padded, np.concatenate([quiet, _programme(), quiet]))
        cls.with_silence = root / "with_silence.mp3"
        _encode(padded, cls.with_silence)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_frame_count_matches_the_duration(self):
        data = self.plain.read_bytes()
        frames = mp3gain.parse_frames(data)
        expected = 8.0 * RATE / 1152
        self.assertAlmostEqual(len(frames), expected, delta=4)

    def test_crc_matches_what_lame_wrote(self):
        """If our CRC differed, a checking decoder would drop every frame."""
        data = self.protected.read_bytes()
        frames = [f for f in mp3gain.parse_frames(data) if f.has_crc]
        self.assertGreater(len(frames), 100)
        for frame in frames:
            info = mp3gain.parse_header(data, frame.offset)
            stored = (data[frame.offset + 4] << 8) | data[frame.offset + 5]
            self.assertEqual(
                mp3gain.frame_crc(data, frame, info["side_info_size"]), stored,
                f"CRC mismatch at frame offset {frame.offset}")

    def test_unprotected_file_has_no_crc_frames(self):
        data = self.plain.read_bytes()
        self.assertFalse(any(f.has_crc for f in mp3gain.parse_frames(data)))

    def test_applied_gain_measures_exactly_as_predicted(self):
        for source in (self.plain, self.protected):
            data = source.read_bytes()
            before = bs1770.measure(decode.decode(source))["lufs_i"]
            for steps in (-3, -1, 1, 2):
                with self.subTest(file=source.name, steps=steps):
                    output = Path(self.tmp.name) / "shifted.mp3"
                    output.write_bytes(mp3gain.apply_steps(data, steps))
                    after = bs1770.measure(decode.decode(output))["lufs_i"]
                    self.assertAlmostEqual(after - before,
                                           steps * mp3gain.DB_PER_STEP, places=3)

    def test_true_peak_moves_by_the_same_amount(self):
        data = self.plain.read_bytes()
        before = bs1770.measure(decode.decode(self.plain))["true_peak_dbtp"]
        output = Path(self.tmp.name) / "peak.mp3"
        output.write_bytes(mp3gain.apply_steps(data, -2))
        after = bs1770.measure(decode.decode(output))["true_peak_dbtp"]
        self.assertAlmostEqual(after - before, -2 * mp3gain.DB_PER_STEP, places=3)

    def test_reversal_is_byte_exact(self):
        """The whole claim of losslessness rests on this."""
        for source in (self.plain, self.protected):
            data = source.read_bytes()
            restored = mp3gain.apply_steps(mp3gain.apply_steps(data, -6), 6)
            self.assertEqual(restored, data, source.name)

    def test_zero_steps_changes_nothing(self):
        data = self.plain.read_bytes()
        self.assertEqual(mp3gain.apply_steps(data, 0), data)

    def test_output_still_decodes_without_errors(self):
        output = Path(self.tmp.name) / "decodes.mp3"
        output.write_bytes(mp3gain.apply_steps(self.protected.read_bytes(), -2))
        result = subprocess.run(
            ["ffmpeg", "-nostdin", "-v", "error", "-i", str(output), "-f", "null", "-"],
            capture_output=True, text=True)
        self.assertEqual(result.stderr.strip(), "")

    def test_id3_region_including_geob_is_untouched(self):
        """Serato keeps cue points and beatgrids in GEOB frames. Losing them
        would be far worse than uneven loudness."""
        payload = b"Serato Markers2\x00" + bytes(range(256)) * 4
        tag = _id3_with_geob(payload)
        tagged = Path(self.tmp.name) / "tagged.mp3"
        tagged.write_bytes(tag + self.plain.read_bytes())

        shifted = mp3gain.apply_steps(tagged.read_bytes(), -2)
        self.assertEqual(shifted[:len(tag)], tag, "ID3 region was modified")
        self.assertIn(payload, shifted)
        # ...and the audio really did change.
        self.assertNotEqual(shifted[len(tag):], tagged.read_bytes()[len(tag):])

    def test_frames_are_found_past_an_id3_tag(self):
        tagged = _id3_with_geob(b"x" * 2048) + self.plain.read_bytes()
        plain_frames = mp3gain.parse_frames(self.plain.read_bytes())
        tagged_frames = mp3gain.parse_frames(tagged)
        self.assertEqual(len(tagged_frames), len(plain_frames))

    def test_silent_granules_exist_in_a_padded_track(self):
        """Guards the premise of the tests below."""
        data = self.with_silence.read_bytes()
        frames = mp3gain.parse_frames(data)
        total = sum(len(f.gain_bits) for f in frames if not f.is_info_frame)
        movable = len(mp3gain.gain_bits(data, frames))
        self.assertGreater(total - movable, 0, "no empty granules to test with")

    def test_empty_granules_do_not_limit_headroom(self):
        """An empty granule decodes to silence whatever its global_gain says,
        so it must not block the file from being attenuated."""
        data = self.with_silence.read_bytes()
        frames = mp3gain.parse_frames(data)
        every_gain = [mp3gain._u8_at(data, bit) for frame in frames
                      if not frame.is_info_frame for bit in frame.gain_bits]
        audible = mp3gain.read_gains(data, frames)
        self.assertLess(len(audible), len(every_gain))
        computed = mp3gain.plan(data, -3.0)
        self.assertFalse(computed.clamped)
        self.assertEqual(computed.steps, -2)
        self.assertEqual(computed.granules, len(audible))
        self.assertEqual(computed.skipped_granules,
                         len(every_gain) - len(audible))

    def test_empty_granules_are_left_untouched(self):
        data = self.with_silence.read_bytes()
        shifted = mp3gain.apply_steps(data, -2)
        frames = mp3gain.parse_frames(data)
        movable = set(mp3gain.gain_bits(data, frames))
        for frame in frames:
            if frame.is_info_frame:
                continue
            for bit in frame.gain_bits:
                before = mp3gain._u8_at(data, bit)
                after = mp3gain._u8_at(shifted, bit)
                expected = before - 2 if bit in movable else before
                self.assertEqual(after, expected, f"granule at bit {bit}")

    def test_reversal_stays_exact_with_silent_granules(self):
        """Skipping granules must not break the losslessness claim: the
        excluded set is chosen by part2_3_length, which a gain shift does not
        change, so the same granules are skipped in both directions."""
        data = self.with_silence.read_bytes()
        self.assertEqual(
            mp3gain.apply_steps(mp3gain.apply_steps(data, -4), 4), data)

    def test_padded_track_still_gains_exactly(self):
        before = bs1770.measure(decode.decode(self.with_silence))["lufs_i"]
        output = Path(self.tmp.name) / "padded_shifted.mp3"
        output.write_bytes(mp3gain.apply_steps(self.with_silence.read_bytes(), -2))
        after = bs1770.measure(decode.decode(output))["lufs_i"]
        self.assertAlmostEqual(after - before, -2 * mp3gain.DB_PER_STEP, places=3)

    def test_plan_clamps_rather_than_exceeding_headroom(self):
        data = self.plain.read_bytes()
        computed = mp3gain.plan(data, -200.0)     # far more than any file allows
        self.assertTrue(computed.clamped)
        down, _ = mp3gain.headroom(
            mp3gain.read_gains(data, mp3gain.parse_frames(data)))
        self.assertEqual(computed.steps, -down)
        # Whatever it clamped to must still be applicable without error.
        mp3gain.apply_steps(data, computed.steps)

    def test_plan_rounds_to_the_nearest_step(self):
        data = self.plain.read_bytes()
        self.assertEqual(mp3gain.plan(data, -3.0).steps, -2)
        self.assertEqual(mp3gain.plan(data, -0.7).steps, 0)
        self.assertEqual(mp3gain.plan(data, -0.8).steps, -1)

    def test_step_size_is_a_quarter_power_of_two(self):
        self.assertAlmostEqual(mp3gain.DB_PER_STEP,
                               20 * np.log10(2 ** 0.25), places=9)

    def test_garbage_is_rejected(self):
        with self.assertRaises(mp3gain.Mp3Error):
            mp3gain.plan(b"not an mp3 at all" * 100, -3.0)


if __name__ == "__main__":
    unittest.main()
