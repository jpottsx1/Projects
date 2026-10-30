"""The LUFS tag a processed MP3 carries: its own level, not the original's."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from loudnesslab import decode, write  # noqa: E402

AUDIO = b"\xff\xfb\x90\x00" + bytes(400)


def _size(n: int, major: int) -> bytes:
    if major == 4:
        return bytes(((n >> s) & 0x7F) for s in (21, 14, 7, 0))
    return n.to_bytes(4, "big")


def _frame(fid: bytes, body: bytes, major: int) -> bytes:
    return fid + _size(len(body), major) + b"\0\0" + body


def _mp3(major: int, frames: list[bytes], flags: int = 0, padding: int = 64) -> bytes:
    tag = b"".join(frames) + bytes(padding)
    return b"ID3" + bytes([major, 0, flags]) + _size(len(tag), 4) + tag + AUDIO


def _txxx(description: str, value: str, wide: bool = False) -> bytes:
    if wide:
        return (b"\x01" + description.encode("utf-16") + b"\0\0"
                + value.encode("utf-16"))
    return b"\0" + description.encode("latin-1") + b"\0" + value.encode("latin-1")


class SetLufsTests(unittest.TestCase):

    def _check(self, major: int) -> None:
        frames = [_frame(b"TIT2", b"\0Summer of Love", major),
                  _frame(b"TXXX", _txxx("LUFS", "-6.1"), major),
                  _frame(b"TXXX", _txxx("LUFS P95", "-4.0"), major),
                  _frame(b"TXXX", _txxx("lufs", "-6.1", wide=True), major),
                  _frame(b"TXXX", _txxx("MODE", "A Aeolian"), major)]
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "track.mp3"
            path.write_bytes(_mp3(major, frames))
            self.assertTrue(write.set_lufs(path, -9.34, p95=-7.46))
            found_major, read = decode._id3_frames(path)
            self.assertEqual(found_major, major)
            names = [decode._frame_name(fid, body) for fid, body in read]
            self.assertEqual(names, ["TIT2", "TXXX(MODE)", "TXXX(LUFS)", "TXXX(LUFS P95)"])
            self.assertEqual(read[-2][1], b"\0LUFS\0-9.3")
            self.assertEqual(read[-1][1], b"\0LUFS P95\0-7.5")
            self.assertEqual(read[0][1], b"\0Summer of Love")
            self.assertTrue(path.read_bytes().endswith(AUDIO))

    def test_v23(self) -> None:
        self._check(3)

    def test_v24(self) -> None:
        self._check(4)

    def test_a_tag_needing_undoing_is_left_alone(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "track.mp3"
            original = _mp3(3, [_frame(b"TXXX", _txxx("LUFS", "-6.1"), 3)], flags=0x80)
            path.write_bytes(original)
            self.assertFalse(write.set_lufs(path, -9.3))
            self.assertEqual(path.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
