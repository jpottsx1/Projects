"""End-to-end: walk a folder, analyse, store, resume, and report."""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from loudnesslab import analyze, db, report  # noqa: E402

RATE = 48000
HAVE_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None


def tone_track(seconds: float, freq: float, amplitude: float) -> np.ndarray:
    t = np.arange(int(seconds * RATE)) / RATE
    rng = np.random.default_rng(int(freq))
    body = np.sin(2 * np.pi * freq * t) + 0.3 * np.sin(2 * np.pi * freq * 5 * t)
    left = body + 0.05 * rng.standard_normal(t.size)
    right = body + 0.05 * rng.standard_normal(t.size)
    out = np.stack([left, right], axis=1)
    return out / np.abs(out).max() * amplitude


def write_wav(path: Path, x: np.ndarray) -> None:
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class TestPipeline(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name) / "library"
        (cls.root / "nested").mkdir(parents=True)
        write_wav(cls.root / "loud.wav", tone_track(6, 110, 0.9))
        write_wav(cls.root / "nested" / "quiet.wav", tone_track(6, 220, 0.2))
        # One tagged MP3, to cover the lossy decode path and tag parsing.
        raw = Path(cls.tmp.name) / "raw.wav"
        write_wav(raw, tone_track(6, 165, 0.6))
        subprocess.run(
            ["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(raw),
             "-codec:a", "libmp3lame", "-b:a", "192k",
             "-metadata", "artist=Test Artist", "-metadata", "title=Test Title",
             "-metadata", "date=1978", "-metadata", "genre=Disco",
             str(cls.root / "tagged.mp3")],
            check=True,
        )
        (cls.root / "notes.txt").write_text("should be ignored")
        cls.db = Path(cls.tmp.name) / "library.db"
        cls.counts = analyze.run(cls.root, cls.db, jobs=1)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_walks_recursively_and_ignores_non_audio(self):
        self.assertEqual(self.counts["found"], 3)
        self.assertEqual(self.counts["analysed"], 3)
        self.assertEqual(self.counts["errors"], 0)

    def test_every_track_has_loudness_and_a_full_band_set(self):
        conn = db.connect(self.db)
        try:
            self.assertEqual(
                conn.execute("SELECT COUNT(*) FROM loudness").fetchone()[0], 3)
            per_track = conn.execute(
                "SELECT COUNT(*) FROM bands GROUP BY track_id").fetchall()
            self.assertTrue(all(row[0] == 31 for row in per_track), per_track)
        finally:
            conn.close()

    def test_tags_are_read(self):
        conn = db.connect(self.db)
        try:
            row = conn.execute(
                "SELECT artist, title, year, genre, codec FROM tracks "
                "WHERE path LIKE '%tagged.mp3'").fetchone()
        finally:
            conn.close()
        self.assertEqual(row["artist"], "Test Artist")
        self.assertEqual(row["year"], 1978)
        self.assertEqual(row["genre"], "Disco")
        self.assertEqual(row["codec"], "mp3")

    def test_relative_loudness_is_ordered_as_built(self):
        conn = db.connect(self.db)
        try:
            rows = dict(conn.execute(
                "SELECT t.path, l.lufs_i FROM tracks t "
                "JOIN loudness l ON l.track_id = t.id").fetchall())
        finally:
            conn.close()
        loud = next(v for k, v in rows.items() if k.endswith("loud.wav"))
        quiet = next(v for k, v in rows.items() if k.endswith("quiet.wav"))
        self.assertGreater(loud, quiet + 5)

    def test_rerun_skips_unchanged_files(self):
        again = analyze.run(self.root, self.db, jobs=1)
        self.assertEqual(again["skipped"], 3)
        self.assertEqual(again["analysed"], 0)

    def test_touching_a_file_makes_it_stale(self):
        target = self.root / "loud.wav"
        target.touch()
        try:
            again = analyze.run(self.root, self.db, jobs=1)
            self.assertEqual(again["analysed"], 1)
            self.assertEqual(again["skipped"], 2)
        finally:
            analyze.run(self.root, self.db, jobs=1)

    def test_a_broken_file_is_recorded_not_raised(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "broken.mp3").write_bytes(b"this is not audio at all")
            counts = analyze.run(root, Path(tmp) / "broken.db", jobs=1)
        self.assertEqual(counts["errors"], 1)
        self.assertEqual(counts["analysed"], 0)

    def test_reports_render(self):
        conn = db.connect(self.db)
        try:
            self.assertIn("LOUDNESS", report.loudness_report(conn))
            self.assertIn("LOW END", report.lowend_report(conn))
            self.assertIn("DRY RUN", report.tracks_report(conn))
            self.assertIn("No failures", report.errors_report(conn))
        finally:
            conn.close()

    def test_dry_run_gain_matches_the_target(self):
        conn = db.connect(self.db)
        try:
            text = report.tracks_report(conn, estimator="lufs_i", target=-14.0)
            rows = conn.execute(
                "SELECT l.lufs_i FROM loudness l ORDER BY ABS(-14.0 - l.lufs_i) DESC"
            ).fetchall()
        finally:
            conn.close()
        expected = f"{-14.0 - rows[0]['lufs_i']:+.1f}"
        self.assertIn(expected, text)

    def test_unknown_estimator_is_rejected(self):
        conn = db.connect(self.db)
        try:
            with self.assertRaises(ValueError):
                report.tracks_report(conn, estimator="not_a_column")
        finally:
            conn.close()


if __name__ == "__main__":
    unittest.main()
