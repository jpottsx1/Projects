"""Reading a track's tempo: the TBPM tag, or Serato's own Autotags frame.

A disc whose every track has a BPM in Serato read none from TBPM: Serato
writes TBPM only with a setting on, and always writes its "Serato
Autotags" GEOB frame. These build that frame byte for byte, in both ID3
versions Serato writes and both text encodings a GEOB can use.
"""

from __future__ import annotations

import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from loudnesslab import decode  # noqa: E402


def _syncsafe(n: int) -> bytes:
    return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])


def _geob(description: str, data: bytes, wide: bool = False) -> bytes:
    if wide:
        encoded = b"\x01" + b"application/octet-stream\x00" + b"\xff\xfe\x00\x00" \
            + b"\xff\xfe" + description.encode("utf-16-le") + b"\x00\x00"
    else:
        encoded = (b"\x00" + b"application/octet-stream\x00" + b"\x00"
                   + description.encode("latin-1") + b"\x00")
    return encoded + data


def _autotags(bpm: str) -> bytes:
    return b"\x01\x01" + bpm.encode("ascii") + b"\x00" + b"-3.257\x00" + b"0.000\x00"


def _tag(frames: list[tuple[bytes, bytes]], major: int = 4, padding: int = 64) -> bytes:
    body = b""
    for frame_id, payload in frames:
        size = _syncsafe(len(payload)) if major == 4 else struct.pack(">I", len(payload))
        body += frame_id + size + b"\x00\x00" + payload
    body += b"\x00" * padding
    return b"ID3" + bytes([major, 0, 0]) + _syncsafe(len(body)) + body


def _file(tag: bytes) -> Path:
    handle = tempfile.NamedTemporaryFile(suffix=".mp3", delete=False)
    handle.write(tag + b"\xff\xfb\x90\x00" * 64)     # a few bytes of "audio"
    handle.close()
    return Path(handle.name)


class TestSeratoAutotags(unittest.TestCase):
    def tearDown(self):
        for path in getattr(self, "paths", []):
            path.unlink(missing_ok=True)

    def read(self, tag: bytes):
        path = _file(tag)
        self.paths = getattr(self, "paths", []) + [path]
        return decode.serato_bpm(path)

    def test_the_tempo_serato_keeps(self):
        for major in (3, 4):
            for wide in (False, True):
                tag = _tag([(b"GEOB", _geob("Serato Autotags", _autotags("122.00"), wide))],
                           major=major)
                self.assertEqual(self.read(tag), 122.0, (major, wide))

    def test_it_is_found_among_serato_s_other_frames(self):
        tag = _tag([
            (b"TIT2", b"\x00Nothing Has Been Proved"),
            (b"GEOB", _geob("Serato Overview", b"\x01\x05" + bytes(200))),
            (b"GEOB", _geob("Serato Markers2", b"\x01\x01" + bytes(300))),
            (b"GEOB", _geob("Serato Autotags", _autotags("107.95"))),
        ])
        self.assertAlmostEqual(self.read(tag), 107.95)

    def test_no_autotags_no_tempo(self):
        self.assertIsNone(self.read(_tag([(b"TIT2", b"\x00Untitled")])))
        self.assertIsNone(self.read(_tag([(b"GEOB", _geob("Serato Overview", bytes(50)))])))
        self.assertIsNone(self.read(b"not an mp3 with a tag at all"))

    def test_a_zero_tempo_is_none(self):
        tag = _tag([(b"GEOB", _geob("Serato Autotags", _autotags("0.00")))])
        self.assertIsNone(self.read(tag))


class TestProbeTakesItWhereTbpmIsMissing(unittest.TestCase):
    def probe(self, tags: dict, file_tag: bytes):
        path = _file(file_tag)
        self.addCleanup(path.unlink, missing_ok=True)
        answer = {"streams": [{"codec_name": "mp3", "sample_rate": "44100",
                               "channels": 2}],
                  "format": {"duration": "240.0", "tags": tags}}
        done = mock.Mock(returncode=0, stdout=json.dumps(answer), stderr="")
        with mock.patch.object(decode.subprocess, "run", return_value=done):
            return decode.probe(path)["bpm"]

    def test_tbpm_first_then_serato(self):
        serato = _tag([(b"GEOB", _geob("Serato Autotags", _autotags("122.00")))])
        self.assertEqual(self.probe({"TBPM": "118"}, serato), 118.0)
        self.assertEqual(self.probe({}, serato), 122.0)
        self.assertIsNone(self.probe({}, _tag([])))

    def test_tbpm_written_loosely(self):
        for written, read in (("122", 122.0), ("122.00", 122.0), ("122,5", 122.5),
                              ("122 BPM", 122.0)):
            self.assertEqual(self.probe({"TBPM": written}, _tag([])), read, written)


if __name__ == "__main__":
    unittest.main()
