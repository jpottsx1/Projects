"""Reading a track's tempo: the TBPM tag, or Serato's own Autotags frame.

A disc whose every track has a BPM in Serato read none from TBPM: Serato
writes TBPM only with a setting on, and always writes its "Serato
Autotags" GEOB frame. These build that frame byte for byte, in both ID3
versions Serato writes and both text encodings a GEOB can use.
"""

from __future__ import annotations

import json
import shutil
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

    def test_a_tempo_field(self):
        # A "Tempo" field (TXXX:TEMPO, or FLAC's TEMPO), and the others
        # taggers use -- each as ffprobe names it, checked against ffprobe.
        for key in ("TEMPO", "tempo", "BPM", "fBPM", "TBPM"):
            self.assertEqual(self.probe({key: "124"}, _tag([])), 124.0, key)

    def test_tbpm_written_loosely(self):
        for written, read in (("122", 122.0), ("122.00", 122.0), ("122,5", 122.5),
                              ("122 BPM", 122.0)):
            self.assertEqual(self.probe({"TBPM": written}, _tag([])), read, written)


def _field(name: bytes, value: bytes) -> bytes:
    return name + struct.pack(">I", len(value)) + value


def _library(tracks: dict[str, str]) -> bytes:
    """A Serato `database V2` listing each track path with its BPM."""
    out = _field(b"vrsn", "2.0/Serato Scratch LIVE Database".encode("utf-16-be"))
    for where, bpm in tracks.items():
        out += _field(b"otrk", _field(b"ttyp", "mp3".encode("utf-16-be"))
                      + _field(b"pfil", where.encode("utf-16-be"))
                      + _field(b"tsng", "A Song".encode("utf-16-be"))
                      + _field(b"tbpm", bpm.encode("utf-16-be"))
                      + _field(b"uadd", struct.pack(">I", 1)))
    return out


class TestSeratoLibrary(unittest.TestCase):
    """Disc 4 again: no TBPM and no Autotags frame in the files, and Serato
    still showing a BPM for every track -- which it keeps in its library."""

    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.home)
        patcher = mock.patch.object(Path, "home", return_value=self.home)
        patcher.start()
        self.addCleanup(patcher.stop)
        decode._LIBRARIES.clear()
        self.music = self.home / "Downloads" / "Disc 4"
        self.music.mkdir(parents=True)

    def track(self, name: str) -> Path:
        path = self.music / name
        path.write_bytes(_tag([(b"TIT2", b"\x00Untitled")]) + b"\xff\xfb\x90\x00" * 64)
        return path

    def library(self, tracks: dict[Path, str], root: Path | None = None):
        root = root or self.home / "Music"
        folder = root / "_Serato_"
        folder.mkdir(parents=True, exist_ok=True)
        base = Path("/") if root == self.home / "Music" else root
        (folder / "database V2").write_bytes(_library(
            {str(p.relative_to(base)): bpm for p, bpm in tracks.items()}))

    def test_the_bpm_serato_shows_is_read_from_its_library(self):
        one, two = self.track("01 Nothing Has Been Proved.mp3"), self.track("02 Black Man Ray.mp3")
        self.library({one: "117.95", two: "77.00"})
        self.assertAlmostEqual(decode.serato_bpm(one), 117.95)
        self.assertEqual(decode.serato_bpm(two), 77.0)
        self.assertIsNone(decode.serato_bpm(self.track("03 Not In Serato.mp3")))

    def test_accents_and_case_written_either_way(self):
        import unicodedata
        path = self.track(unicodedata.normalize("NFD", "Café Society.mp3"))
        self.library({Path(str(path).replace("Downloads", "DOWNLOADS")
                           .replace(unicodedata.normalize("NFD", "é"), "é")): "120"})
        self.assertEqual(decode.serato_bpm(path), 120.0)

    def test_the_file_s_own_frame_comes_first(self):
        path = self.track("04 Both.mp3")
        path.write_bytes(_tag([(b"GEOB", _geob("Serato Autotags", _autotags("99.00")))]))
        self.library({path: "130.00"})
        self.assertEqual(decode.serato_bpm(path), 99.0)

    def test_an_external_drive_has_its_own_library(self):
        drive = Path("/Volumes/DJ Drive")
        places = decode._serato_databases(drive / "Music" / "Song.mp3")
        self.assertEqual(places[0], (drive / "_Serato_" / "database V2", "Music/Song.mp3"))
        self.assertEqual(places[1][1], "Volumes/DJ Drive/Music/Song.mp3")

    def test_it_says_where_it_looked(self):
        path = self.track("05 Nowhere.mp3")
        said = decode.where_the_tempo_was_looked_for(path)
        self.assertIn("ID3v2.4, 1 frames; Serato frames: none", said)
        self.assertIn("no Serato library at", said)
        self.library({self.track("06 Other.mp3"): "100"})
        said = decode.where_the_tempo_was_looked_for(path)
        self.assertIn("1 tracks with a BPM, not this one", said)
        self.assertIn("Downloads/Disc 4/05 Nowhere.mp3", said)


class TestTheTagReadLeniently(unittest.TestCase):
    def read(self, tag: bytes):
        path = _file(tag)
        self.addCleanup(path.unlink, missing_ok=True)
        return decode._autotags_in_file(path)

    def test_v24_sizes_written_as_plain_integers(self):
        # A frame over 127 bytes, its size written plain: read as syncsafe
        # it points into the middle of the next frame.
        big = b"\x00" + b"x" * 300
        payload = _geob("Serato Autotags", _autotags("111.00"))
        body = (b"TXXX" + struct.pack(">I", len(big)) + b"\x00\x00" + big
                + b"GEOB" + struct.pack(">I", len(payload)) + b"\x00\x00" + payload
                + b"\x00" * 32)
        tag = b"ID3\x04\x00\x00" + _syncsafe(len(body)) + body
        self.assertEqual(self.read(tag), 111.0)

    def test_unsynchronised_and_with_a_data_length(self):
        data = _geob("Serato Autotags", _autotags("123.00"), wide=True)
        self.assertIn(b"\xff", data)
        framed = struct.pack(">I", len(data)) + data.replace(b"\xff", b"\xff\x00")
        body = (b"GEOB" + _syncsafe(len(framed)) + b"\x00\x03" + framed + b"\x00" * 16)
        tag = b"ID3\x04\x00\x00" + _syncsafe(len(body)) + body
        self.assertEqual(self.read(tag), 123.0)

    def test_big_endian_utf16_without_a_bom(self):
        data = (b"\x02" + b"application/octet-stream\x00" + b"\x00\x00"
                + "Serato Autotags".encode("utf-16-be") + b"\x00\x00" + _autotags("98.50"))
        self.assertEqual(self.read(_tag([(b"GEOB", data)])), 98.5)


if __name__ == "__main__":
    unittest.main()
