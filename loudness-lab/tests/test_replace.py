"""Replacing originals, and putting them back.

The one place processing touches an original, so what is tested is that
nothing is ever lost: the original is kept, byte for byte, the swap is
logged, a restore puts every byte back, and a track in another format
than its original is left alone.
"""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from loudnesslab import cli, replace  # noqa: E402
from tests.test_manifest import HAVE_FFMPEG, RATE, groove  # noqa: E402


class Swap(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.library = self.root / "Music" / "Album"
        self.library.mkdir(parents=True)
        self.original = self.library / "01 Song.mp3"
        self.original.write_bytes(b"original bytes")
        self.processed = self.root / "out" / "01 Song.mp3"
        self.processed.parent.mkdir()
        self.processed.write_bytes(b"processed bytes")
        self.batch = replace.new_batch(self.root / "kept")

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_original_is_kept_and_the_processed_file_takes_its_place(self):
        done, _ = replace.replace(self.original, self.processed, self.batch)
        self.assertTrue(done)
        self.assertEqual(self.original.read_bytes(), b"processed bytes")
        self.assertFalse(self.processed.exists())
        entry, = [json.loads(line) for line in
                  (self.batch / replace.LOG).read_text().splitlines()]
        self.assertEqual(Path(entry["kept"]).read_bytes(), b"original bytes")
        # Its whole path is mirrored, so same-named tracks never meet.
        self.assertTrue(entry["kept"].endswith("Music/Album/01 Song.mp3"))

    def test_restore_puts_every_byte_back_and_keeps_what_it_undid(self):
        replace.replace(self.original, self.processed, self.batch)
        restored, problems = replace.restore(self.batch)
        self.assertEqual((restored, problems), (1, []))
        self.assertEqual(self.original.read_bytes(), b"original bytes")
        undone = list((self.batch / "undone").rglob("01 Song.mp3"))
        self.assertEqual([p.read_bytes() for p in undone], [b"processed bytes"])
        # A second restore finds nothing left to do and harms nothing.
        self.assertEqual(replace.restore(self.batch), (0, []))
        self.assertEqual(self.original.read_bytes(), b"original bytes")

    def test_another_format_is_left_alone(self):
        flac = self.processed.with_suffix(".flac")
        self.processed.rename(flac)
        done, message = replace.replace(self.original, flac, self.batch)
        self.assertFalse(done)
        self.assertIn("format", message)
        self.assertEqual(self.original.read_bytes(), b"original bytes")
        self.assertTrue(flac.exists())

    def test_a_folder_that_is_not_a_batch_is_refused(self):
        restored, problems = replace.restore(self.root)
        self.assertEqual(restored, 0)
        self.assertTrue(problems)


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class Command(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.library = self.root / "library"
        self.library.mkdir()
        wav = self.root / "groove.wav"
        with wave.open(str(wav), "wb") as handle:
            handle.setnchannels(2)
            handle.setsampwidth(2)
            handle.setframerate(RATE)
            handle.writeframes((groove() * 32767).astype("<i2").tobytes())
        self.song = self.library / "groove.mp3"
        subprocess.run(["ffmpeg", "-v", "error", "-i", str(wav), "-b:a",
                        "320k", str(self.song)], check=True)
        self.before = self.song.read_bytes()
        self.kept = self.root / "kept"
        patcher = mock.patch.object(replace, "backup_root",
                                    lambda: self.kept)
        patcher.start()
        self.addCleanup(patcher.stop)

    def tearDown(self):
        self.tmp.cleanup()

    def run_subbass(self, *extra: str) -> tuple[int, str]:
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = cli.main(["subbass", str(self.library), "--quiet",
                             "--amount", "5", "--db", str(self.root / "m.db"),
                             "--out", str(self.root / "out"), *extra])
        return code, buffer.getvalue()

    def test_it_must_be_confirmed_and_cannot_replace_with_a_comparison(self):
        for extra in (["--no-compare"], ["--yes"],
                      ["--no-compare", "--yes", "--dry-run"]):
            code, text = self.run_subbass("--format", "mp3",
                                          "--replace-originals", *extra)
            self.assertNotEqual(code, 0, text)
            self.assertEqual(self.song.read_bytes(), self.before)

    def test_a_run_replaces_the_original_and_restore_undoes_it(self):
        code, text = self.run_subbass("--format", "mp3", "--no-compare",
                                      "--replace-originals", "--yes")
        self.assertEqual(code, 0, text)
        self.assertNotEqual(self.song.read_bytes(), self.before)
        batch, = self.kept.iterdir()
        manifest = json.loads((self.root / "out" / "manifest.json").read_text())
        variant, = manifest["tracks"][0]["variants"]
        self.assertEqual(Path(variant["path"]), self.song)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(["restore", str(batch)]), 0)
        self.assertEqual(self.song.read_bytes(), self.before)

    def test_a_different_format_leaves_the_original_where_it_is(self):
        code, text = self.run_subbass("--format", "flac", "--no-compare",
                                      "--replace-originals", "--yes")
        self.assertEqual(code, 0, text)
        self.assertEqual(self.song.read_bytes(), self.before)
        self.assertIn("not replaced", text)


if __name__ == "__main__":
    unittest.main()
