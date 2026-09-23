"""End-to-end: walk a folder, analyse, store, resume, and report."""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from loudnesslab import (SCHEMA_VERSION, analyze, apply_gain, bs1770, cli,  # noqa: E402
                         db, decode, report)

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


class TestFolderLabels(unittest.TestCase):
    """Two compilations each containing a CD1 must not merge into one row --
    but one compilation's own discs are the opposite case, and must."""

    def test_a_multi_disc_release_collapses_to_one_row(self):
        """Four discs of the same release, nothing measured directly in the
        release folder itself: one label, not four."""
        labels = report._folder_labels([
            f"/music/Now Yearbook 99 (2026)/CD{n}/track.mp3" for n in range(1, 5)
        ])
        self.assertEqual(set(labels.values()), {"Now Yearbook 99 (2026)"})

    def test_a_different_compilations_cd1_stays_separate(self):
        """The collapse is structural, not a name match -- so it must not
        let two DIFFERENT releases' identically-named discs merge."""
        labels = report._folder_labels([
            "/music/Now Yearbook 99 (2026)/CD1/a.mp3",
            "/music/Now Yearbook 99 (2026)/CD2/b.mp3",
            "/music/NOW 100 Hits Party/CD1/c.mp3",
        ])
        self.assertEqual(len(set(labels.values())), 2)
        self.assertEqual(labels["/music/Now Yearbook 99 (2026)/CD1/a.mp3"],
                         labels["/music/Now Yearbook 99 (2026)/CD2/b.mp3"])
        self.assertIn("Now Yearbook 99 (2026)", labels.values())
        self.assertIn("NOW 100 Hits Party/CD1", labels.values())

    def test_a_disc_suffix_after_the_repeated_album_name_still_collapses(self):
        """Ripping software's ordinary naming: the disc folder repeats the
        release name in full and puts the disc number on the end, not a
        bare "CD4". Anchoring to the whole name would miss this -- which
        is the common case, not the rare one."""
        labels = report._folder_labels([
            "/music/NOW 100 Hits Party/NOW - 100 HITS - PARTY - CD1/a.mp3",
            "/music/NOW 100 Hits Party/NOW - 100 HITS - PARTY - CD2/b.mp3",
            "/music/NOW 100 Hits Party/NOW - 100 HITS - PARTY - CD3/c.mp3",
            "/music/NOW 100 Hits Party/NOW - 100 HITS - PARTY - CD4/d.mp3",
        ])
        self.assertEqual(set(labels.values()), {"NOW 100 Hits Party"})

    def test_a_track_alongside_the_discs_blocks_the_collapse(self):
        """A bonus track sitting directly in the release folder means the
        folder is not a pure disc container -- collapsing it would conflate
        "in the folder itself" with "in one of its discs"."""
        labels = report._folder_labels([
            "/music/Now Yearbook 99 (2026)/CD1/a.mp3",
            "/music/Now Yearbook 99 (2026)/CD2/b.mp3",
            "/music/Now Yearbook 99 (2026)/bonus.mp3",
        ])
        self.assertEqual(len(set(labels.values())), 3)

    def test_a_flat_folder_keeps_its_own_name(self):
        labels = report._folder_labels(["/music/Party/a.mp3",
                                        "/music/Party/b.mp3"])
        self.assertEqual(set(labels.values()), {"Party"})

    def test_empty_input(self):
        self.assertEqual(report._folder_labels([]), {})


class TestReferenceResolution(unittest.TestCase):
    def test_exact_name_wins(self):
        groups = {"New Music 2026-09-02": {}, "NOW 100 Hits Party": {}}
        self.assertEqual(
            report.resolve_reference(groups, "NOW 100 Hits Party"),
            "NOW 100 Hits Party")

    def test_unique_substring_matches_case_insensitively(self):
        groups = {"New Music 2026-09-02": {}, "NOW 100 Hits Party": {}}
        self.assertEqual(report.resolve_reference(groups, "new music"),
                         "New Music 2026-09-02")

    def test_an_ambiguous_substring_matches_nothing(self):
        """Silently picking one of two plausible references would produce a
        correction curve measured against the wrong corpus."""
        groups = {"NOW Party CD1": {}, "NOW Party CD2": {}}
        self.assertIsNone(report.resolve_reference(groups, "NOW Party"))

    def test_no_match(self):
        self.assertIsNone(report.resolve_reference({"a": {}}, "zzz"))


class TestNormalisationGuard(unittest.TestCase):
    """A library that has been through a loudness normaliser is fine to
    level but useless as a reference, because its crest, LRA and true peak
    are the normaliser's limiter rather than the records."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.conn = db.connect(Path(self.tmp.name) / "guard.db")
        self.addCleanup(self.conn.close)

    def _populate(self, values) -> None:
        for index, value in enumerate(values):
            path = f"/library/{index}.mp3"
            self.conn.execute(
                "INSERT INTO tracks (path, status) VALUES (?, 'ok')", (path,))
            track_id = self.conn.execute(
                "SELECT id FROM tracks WHERE path = ?", (path,)).fetchone()["id"]
            self.conn.execute(
                "INSERT INTO loudness (track_id, lufs_i) VALUES (?, ?)",
                (track_id, value))
        self.conn.commit()

    def test_a_normalised_library_is_flagged(self):
        self._populate([-11.51 + (i % 3) * 0.01 for i in range(40)])
        warning = report.normalisation_warning(self.conn)
        self.assertIsNotNone(warning)
        self.assertIn("ALREADY NORMALISED", warning)

    def test_a_real_library_is_not_flagged(self):
        self._populate([-16.0 + (i % 11) * 0.9 for i in range(40)])
        self.assertIsNone(report.normalisation_warning(self.conn))

    def test_too_few_tracks_to_judge(self):
        """Five tracks can be similar by chance; do not cry wolf."""
        self._populate([-11.5] * 5)
        self.assertIsNone(report.normalisation_warning(self.conn))

    def test_the_warning_reaches_both_reports(self):
        self._populate([-11.51 + (i % 3) * 0.01 for i in range(40)])
        self.assertIn("ALREADY NORMALISED",
                      report.loudness_report(self.conn))


class TestPerFolderNormalisation(unittest.TestCase):
    """Once several corpora share a database -- which is the point, since the
    reference has to live alongside what it is compared to -- a database-wide
    normalisation check cannot answer "is THIS corpus clean". That is exactly
    when the question gets asked."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.conn = db.connect(Path(self.tmp.name) / "folders.db")
        self.addCleanup(self.conn.close)

    def _add(self, folder, levels):
        for index, level in enumerate(levels):
            path = f"/music/{folder}/{index}.mp3"
            self.conn.execute(
                "INSERT INTO tracks (path, status, year) VALUES (?, 'ok', 1977)",
                (path,))
            track = self.conn.execute(
                "SELECT id FROM tracks WHERE path = ?", (path,)).fetchone()["id"]
            self.conn.execute(
                "INSERT INTO loudness (track_id, lufs_i, s_p95) VALUES (?, ?, ?)",
                (track, level, level + 1.7))
            for band in (31.5, 40.0, 50.0, 63.0):
                self.conn.execute(
                    "INSERT INTO bands (track_id, band_hz, shape_db) "
                    "VALUES (?, ?, ?)", (track, band, -20.0))
        self.conn.commit()

    def test_a_normalised_folder_is_named(self):
        self._add("Processed", [-11.5 + (i % 3) * 0.01 for i in range(25)])
        self._add("Clean", [-16.0 + (i % 11) * 0.9 for i in range(25)])
        text = report.folders_report(self.conn)
        self.assertIn("ALREADY NORMALISED", text)
        self.assertIn("Processed", text.split("ALREADY NORMALISED")[1])
        self.assertNotIn("Clean", text.split("ALREADY NORMALISED")[1].split("\n")[0])

    def test_a_clean_library_is_not_flagged_at_all(self):
        self._add("Clean", [-16.0 + (i % 11) * 0.9 for i in range(25)])
        self.assertNotIn("ALREADY NORMALISED", report.folders_report(self.conn))

    def test_a_handful_of_tracks_is_not_enough_to_judge(self):
        """Five similar tracks happen; they are not evidence of a limiter."""
        self._add("Tiny", [-11.5] * 5)
        self.assertNotIn("ALREADY NORMALISED", report.folders_report(self.conn))


class TestYearTags(unittest.TestCase):
    """Era grouping is only meaningful when the year says when the record was
    MADE. A compilation tags every track with the reissue year."""

    def test_original_date_beats_release_date(self):
        year, is_original = decode._year(
            {"date": "2011", "originaldate": "1982-04-01"})
        self.assertEqual((year, is_original), (1982, 1))

    def test_release_date_is_used_but_flagged(self):
        year, is_original = decode._year({"date": "2011"})
        self.assertEqual((year, is_original), (2011, 0))

    def test_id3_original_frames_are_recognised(self):
        self.assertEqual(decode._year({"tyer": "2004", "tory": "1981"}),
                         (1981, 1))

    def test_no_date_at_all(self):
        self.assertEqual(decode._year({"artist": "Duran Duran"}), (None, None))

    def test_a_year_embedded_in_a_longer_string(self):
        self.assertEqual(decode._year({"date": "1984-11-05T00:00:00"}),
                         (1984, 0))


class TestSchemaMigration(unittest.TestCase):
    """Re-analysing a large library costs hours, so a schema bump migrates an
    existing database in place rather than refusing to open it."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "old.db"
        self.addCleanup(self.tmp.cleanup)

    def _make_v1(self) -> None:
        conn = sqlite3.connect(self.path)
        conn.executescript(
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
            "CREATE TABLE tracks (id INTEGER PRIMARY KEY, path TEXT UNIQUE "
            "  NOT NULL, status TEXT NOT NULL, year INTEGER);"
            "INSERT INTO meta VALUES ('schema_version', '1');"
            "INSERT INTO tracks (path, status, year) "
            "  VALUES ('/a.mp3', 'ok', 1981);")
        conn.commit()
        conn.close()

    def test_v1_is_migrated_not_rejected(self):
        self._make_v1()
        conn = db.connect(self.path)
        try:
            columns = {row["name"] for row in conn.execute("PRAGMA table_info(tracks)")}
            self.assertIn("year_is_original", columns)
            version = conn.execute(
                "SELECT value FROM meta WHERE key = 'schema_version'").fetchone()
            # Against the constant, not a literal: a later schema bump must
            # not silently turn this into a stale assertion.
            self.assertEqual(int(version["value"]), SCHEMA_VERSION)
            tables = {row["name"] for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table'")}
            self.assertIn("gain_log", tables)
        finally:
            conn.close()

    def test_migration_preserves_existing_rows(self):
        self._make_v1()
        conn = db.connect(self.path)
        try:
            row = conn.execute("SELECT path, year, year_is_original "
                               "FROM tracks").fetchone()
        finally:
            conn.close()
        self.assertEqual(row["path"], "/a.mp3")
        self.assertEqual(row["year"], 1981)
        # Unknown, not "not original" -- the old database never recorded it.
        self.assertIsNone(row["year_is_original"])

    def _make_v4(self) -> None:
        """A database as the previous build left it: mono and stereo rows,
        all measured, all marked ok."""
        conn = db.connect(self.path)
        conn.execute("UPDATE meta SET value = '4' WHERE key = 'schema_version'")
        for path, channels in (("/mono.mp3", 1), ("/stereo.mp3", 2),
                               ("/broken.mp3", 1)):
            conn.execute(
                "INSERT INTO tracks (path, status, source_channels, tool_version) "
                "VALUES (?, ?, ?, '0.1.0')",
                (path, "error" if path == "/broken.mp3" else "ok", channels))
        conn.commit()
        conn.close()

    def test_v5_marks_mono_rows_stale_and_leaves_stereo_alone(self):
        """The mono upmix changed by 3.01 LU, so every mono row measured by
        an older build is wrong. Reports filter on status = 'ok', so marking
        them stale stops the wrong figure being averaged in AND makes the
        next scan re-measure them -- without re-measuring a whole library to
        fix the handful of mono singles in it."""
        self._make_v4()
        conn = db.connect(self.path)
        try:
            status = {row["path"]: row["status"] for row in
                      conn.execute("SELECT path, status FROM tracks")}
        finally:
            conn.close()
        self.assertEqual(status["/mono.mp3"], "stale", "mono was left as measured")
        self.assertEqual(status["/stereo.mp3"], "ok",
                         "stereo re-measures for nothing -- it did not change")
        self.assertEqual(status["/broken.mp3"], "error",
                         "a failure was overwritten by the migration")

    def test_a_stale_row_is_analysed_again(self):
        """Marking it stale is only worth anything if a scan acts on it."""
        self._make_v4()
        conn = db.connect(self.path)
        try:
            stat = os.stat_result((0o100644, 0, 0, 1, 0, 0, 0, 0, 0, 0))
            self.assertTrue(db.needs_analysis(conn, Path("/mono.mp3"), stat))
        finally:
            conn.close()

    def test_a_newer_database_is_refused(self):
        conn = sqlite3.connect(self.path)
        conn.executescript(
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
            "INSERT INTO meta VALUES ('schema_version', '99');")
        conn.commit()
        conn.close()
        with self.assertRaises(RuntimeError):
            db.connect(self.path)


class TestSurvey(unittest.TestCase):
    """Walking the library. A library that comes back smaller than the user
    expected must be explainable, not silent."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def touch(self, *relative: str) -> None:
        for name in relative:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"")

    def test_recurses_into_subfolders(self):
        self.touch("a.mp3", "Disco 12s/b.mp3", "Disco 12s/deep/c.flac")
        found = decode.survey(self.root)
        self.assertEqual(len(found["audio"]), 3)
        self.assertEqual(found["folders"], 3)

    def test_ignores_dot_directories_and_appledouble(self):
        """Removable volumes always carry .Trashes and ._ resource forks."""
        self.touch("real.mp3", ".Trashes/ghost.mp3",
                   ".Spotlight-V100/index.mp3", "._real.mp3")
        names = [p.name for p in decode.survey(self.root)["audio"]]
        self.assertEqual(names, ["real.mp3"])

    def test_counts_what_it_passed_over(self):
        self.touch("a.mp3", "art.jpg", "b.mp2", "c.mp2", "list.m3u")
        skipped = decode.survey(self.root)["skipped"]
        self.assertEqual(skipped[".mp2"], 2)
        self.assertEqual(skipped[".jpg"], 1)
        self.assertNotIn(".mp3", skipped)

    def test_uppercase_extensions_are_audio(self):
        self.touch("LOUD.MP3", "Old.AIFF")
        self.assertEqual(len(decode.survey(self.root)["audio"]), 2)

    def test_a_single_file_is_flagged_as_such(self):
        self.touch("only.mp3")
        found = decode.survey(self.root / "only.mp3")
        self.assertTrue(found["single_file"])
        self.assertEqual(len(found["audio"]), 1)

    def test_symlinked_folders_are_followed_without_looping(self):
        self.touch("music/a.mp3")
        (self.root / "link").symlink_to(self.root / "music",
                                        target_is_directory=True)
        (self.root / "music" / "loop").symlink_to(self.root,
                                                  target_is_directory=True)
        found = decode.survey(self.root)  # must terminate
        self.assertGreaterEqual(len(found["audio"]), 1)

    def test_empty_folder_is_not_an_error(self):
        found = decode.survey(self.root)
        self.assertEqual(found["audio"], [])
        self.assertEqual(found["errors"], [])


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class TestPorcelainProgress(unittest.TestCase):
    """Progress a program can read.

    The Mac app drives this CLI rather than reimplementing it, so it needs
    progress it can parse. The human printer writes to stderr with carriage
    returns -- right for a terminal, useless to anything driving a bar.
    """

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        rate = decode.TARGET_RATE
        t = np.arange(int(rate * 1.5)) / rate
        wave_ = np.column_stack([0.4 * np.sin(2 * np.pi * 110 * t)] * 2)
        for name in ("a.wav", "b.wav"):
            with wave.open(str(self.dir / name), "wb") as handle:
                handle.setnchannels(2)
                handle.setsampwidth(2)
                handle.setframerate(rate)
                handle.writeframes(
                    (np.clip(wave_, -1, 1) * 32767).astype("<i2").tobytes())

    def _run(self) -> list[dict]:
        out = subprocess.run(
            [sys.executable, str(Path(__file__).resolve().parents[1] / "loudness-lab"),
             "analyze", str(self.dir), "--db", str(self.dir / "library.db"),
             "--porcelain"],
            capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        return [json.loads(line) for line in out.stdout.splitlines() if line.strip()]

    def test_every_line_is_json_and_the_last_one_is_the_total(self):
        events = self._run()
        self.assertTrue(events, "nothing was written")
        progress = [e for e in events if e["event"] == "progress"]
        self.assertEqual(len(progress), 2)
        # Monotonic and bounded: a bar driven by these cannot go backwards.
        self.assertEqual([e["done"] for e in progress], [1, 2])
        self.assertTrue(all(e["total"] == 2 for e in progress))
        self.assertTrue(all(e["status"] == "ok" for e in progress))
        done = events[-1]
        self.assertEqual(done["event"], "done")
        self.assertEqual(done["analysed"], 2)
        self.assertEqual(done["errors"], 0)

    def test_nothing_but_json_goes_to_stdout(self):
        """A stray print would break the caller on a line it cannot parse."""
        for event in self._run():
            self.assertIn("event", event)


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class TestMonoIsUpmixedAtUnity(unittest.TestCase):
    """The same recording must measure the same stored mono or dual mono.

    It did not. `ffmpeg -ac 2` upmixes one channel to two through a
    1/sqrt(2) rematrix, which preserves total power -- a mixdown convention
    meant to stop a mono source clipping a stereo bus. Applied here it made
    every mono file read 3.01 LU quieter than the identical audio stored as
    stereo, so a mono single was normalised 3 dB LOUD against the stereo
    tracks either side of it in a set. Three decibels is not a rounding
    error; it is the difference between a record sitting in the mix and
    jumping out of it.

    Found by porting the decoder to Swift, where the upmix was written
    explicitly and disagreed. Neither implementation was obviously wrong on
    its own -- it took two of them to see it.
    """

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        # Something with real content: a gated bass tone, so the loudness
        # gate has material to keep and the answer is not -inf.
        t = np.arange(int(decode.TARGET_RATE * 3.0)) / decode.TARGET_RATE
        wave_ = 0.5 * np.sin(2 * np.pi * 110.0 * t)
        wave_ *= (np.sin(2 * np.pi * 2.0 * t) > 0)
        self.signal = wave_

    def _write(self, name: str, channels: int) -> Path:
        path = self.dir / name
        x = (self.signal if channels == 1
             else np.column_stack([self.signal, self.signal]))
        with wave.open(str(path), "wb") as handle:
            handle.setnchannels(channels)
            handle.setsampwidth(2)
            handle.setframerate(decode.TARGET_RATE)
            handle.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())
        return path

    def test_a_mono_file_measures_the_same_as_the_same_audio_in_stereo(self):
        mono = decode.decode(self._write("mono.wav", 1))
        stereo = decode.decode(self._write("stereo.wav", 2))
        self.assertEqual(mono.shape, stereo.shape)
        # Identical audio, identical measurement. Under `-ac 2` these were
        # 3.0103 LU apart.
        self.assertAlmostEqual(bs1770.measure(mono)["lufs_i"],
                               bs1770.measure(stereo)["lufs_i"], places=4)
        self.assertLess(float(np.abs(mono - stereo).max()), 1e-4)

    def test_the_mono_upmix_is_unity_not_power_preserving(self):
        """State the amplitude directly, so the 1/sqrt(2) cannot come back."""
        mono = decode.decode(self._write("mono.wav", 1))
        self.assertAlmostEqual(float(np.abs(mono).max()), 0.5, places=3)
        np.testing.assert_array_equal(mono[:, 0], mono[:, 1])

    def test_a_wrong_channel_hint_does_not_silently_attenuate(self):
        """The hint saves a probe on the scan path; it must not cost truth.

        Passing the wrong count is a caller's bug, but a 3 dB one that no
        test would notice is worse than a loud one.
        """
        path = self._write("mono.wav", 1)
        honest = decode.decode(path)
        hinted = decode.decode(path, source_channels=1)
        np.testing.assert_array_equal(honest, hinted)


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

    def test_parallel_run_through_the_real_launcher(self):
        """The launcher must survive being re-imported by a spawned worker.

        macOS spawns rather than forks, so every worker re-imports the
        launcher script. Without a __main__ guard each one restarts the whole
        CLI and the pool dies with "An attempt has been made to start a new
        process before the current process has finished its bootstrapping
        phase". Linux forks by default and never saw it, which is exactly why
        this drives the real script with real workers instead of calling
        analyze.run() in-process.
        """
        launcher = Path(__file__).resolve().parents[1] / "loudness-lab"
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(
                [sys.executable, str(launcher), "analyze", str(self.root),
                 "--db", str(Path(tmp) / "parallel.db"),
                 "--jobs", "2", "--quiet"],
                capture_output=True, text=True)
        self.assertNotIn("bootstrapping phase", result.stderr)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("analysed 3", result.stdout)
        self.assertIn("errors 0", result.stdout)

    def test_gain_measures_what_it_needs_and_writes_nothing_by_default(self):
        """Pointing gain at a folder should be enough: no separate scan step,
        and a dry run must leave every file untouched."""
        originals = {p: p.read_bytes() for p in self.root.rglob("*.mp3")}
        self.assertTrue(originals)
        with tempfile.TemporaryDirectory() as tmp:
            code = cli.main(["gain", str(self.root), "--db",
                             str(Path(tmp) / "auto.db"), "--out",
                             str(Path(tmp) / "out"), "--target", "-12",
                             "--jobs", "1", "--quiet"])
            self.assertEqual(code, 0)
            self.assertFalse(list(Path(tmp).glob("out/**/*.mp3")))
        for path, before in originals.items():
            self.assertEqual(path.read_bytes(), before, f"{path.name} was modified")

    def test_gain_apply_writes_copies_and_leaves_originals_alone(self):
        originals = {p: p.read_bytes() for p in self.root.rglob("*.mp3")}
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            code = cli.main(["gain", str(self.root), "--db",
                             str(Path(tmp) / "auto.db"), "--out", str(out),
                             "--target", "-20", "--apply", "--jobs", "1",
                             "--quiet"])
            self.assertEqual(code, 0)
            written = list(out.rglob("*.mp3"))
            self.assertTrue(written)
            self.assertFalse(any(p.name.endswith(".partial")
                                 for p in out.rglob("*")))
        for path, before in originals.items():
            self.assertEqual(path.read_bytes(), before, f"{path.name} was modified")

    def test_gain_finds_tracks_through_a_symlinked_root(self):
        """analyze stores the path it walked. If gain resolves symlinks and
        analyze does not, every file reads as unanalysed right after being
        measured -- which is how this looked on a macOS /tmp path."""
        with tempfile.TemporaryDirectory() as tmp:
            link = Path(tmp) / "link"
            link.symlink_to(self.root, target_is_directory=True)
            database = Path(tmp) / "sym.db"
            buffer = io.StringIO()
            with contextlib.redirect_stdout(buffer):
                code = cli.main(["gain", str(link), "--db", str(database),
                                 "--out", str(Path(tmp) / "out"),
                                 "--target", "-12", "--jobs", "1", "--quiet"])
            output = buffer.getvalue()
        self.assertEqual(code, 0)
        self.assertNotIn("not in the database", output)
        self.assertIn("would change", output)

    def test_gain_never_boosts_past_the_true_peak_ceiling(self):
        """Raising a quiet track toward a hot target would drive it into
        inter-sample clipping -- the exact defect found in an already
        normalised library. Headroom is what limiting buys, and this tool
        does not limit."""
        with tempfile.TemporaryDirectory() as tmp:
            database = Path(tmp) / "ceiling.db"
            analyze.run(self.root, database, jobs=1)
            conn = db.connect(database)
            try:
                # A target far above everything, so every track wants a boost.
                proposals = apply_gain.propose(
                    conn, [self.root], "s_p95", target=0.0,
                    out_dir=Path(tmp) / "out", peak_ceiling=-1.0)
                peaks = dict(conn.execute(
                    "SELECT t.path, l.true_peak_dbtp FROM tracks t "
                    "JOIN loudness l ON l.track_id = t.id"))
            finally:
                conn.close()
        self.assertTrue(proposals)
        for proposal in proposals:
            if not proposal.ok:
                continue
            peak = peaks[str(proposal.path)]
            self.assertIsNotNone(proposal.peak_capped_from)
            self.assertLessEqual(peak + proposal.wanted_db, -1.0 + 1e-9)
            self.assertLessEqual(peak + proposal.plan.applied_db, -1.0 + 1e-9)

    def test_attenuation_is_never_held_back_by_the_ceiling(self):
        """Turning a track down cannot raise its peak, so the ceiling must
        not interfere with the ordinary case."""
        with tempfile.TemporaryDirectory() as tmp:
            database = Path(tmp) / "quiet.db"
            analyze.run(self.root, database, jobs=1)
            conn = db.connect(database)
            try:
                proposals = apply_gain.propose(
                    conn, [self.root], "s_p95", target=-30.0,
                    out_dir=Path(tmp) / "out", peak_ceiling=-1.0)
            finally:
                conn.close()
        usable = [p for p in proposals if p.ok]
        self.assertTrue(usable)
        for proposal in usable:
            self.assertIsNone(proposal.peak_capped_from)
            self.assertLess(proposal.wanted_db, 0)

    def test_non_mp3_audio_is_counted_not_dropped(self):
        """A library half levelled and half untouched is worse than one that
        was merely uneven, so what cannot be processed must be reported."""
        counts = apply_gain.unsupported_audio([self.root])
        self.assertEqual(counts.get(".wav"), 2)
        self.assertNotIn(".mp3", counts)

    def test_an_all_mp3_folder_reports_nothing_unsupported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "a.mp3").write_bytes(b"")
            self.assertEqual(apply_gain.unsupported_audio([root]), {})

    def test_piping_into_head_is_not_an_error(self):
        """A closed pipe is how `| head` works; it must not print an error."""
        launcher = Path(__file__).resolve().parents[1] / "loudness-lab"
        report_cmd = subprocess.Popen(
            [sys.executable, str(launcher), "report", "loudness",
             "--db", str(self.db)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env={**os.environ, "LOUDNESS_LAB_REEXEC": "1"})
        head = subprocess.Popen(["head", "-2"], stdin=report_cmd.stdout,
                                stdout=subprocess.DEVNULL)
        report_cmd.stdout.close()
        head.wait()
        stderr = report_cmd.communicate()[1].decode()
        self.assertNotIn("error:", stderr, stderr)

    def test_scan_writes_a_database_and_a_transcript(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_db = Path(tmp) / "scan.db"
            out_txt = Path(tmp) / "scan.txt"
            code = cli.main(["scan", str(self.root), "--db", str(out_db),
                             "--out", str(out_txt), "--jobs", "1", "--quiet"])
            self.assertEqual(code, 0)
            self.assertTrue(out_db.exists())
            text = out_txt.read_text()
            for heading in ("SCAN", "LOUDNESS", "FOLDERS", "LOW END"):
                self.assertIn(heading, text)

    def test_lowend_report_shows_between_track_spread(self):
        """A median low-end curve says nothing about whether the tracks agree
        with each other, which is what decides if levelling alone suffices."""
        conn = db.connect(self.db)
        try:
            text = report.lowend_report(conn)
        finally:
            conn.close()
        self.assertIn("How consistent is the low end BETWEEN tracks?", text)

    def test_lowend_can_group_by_folder(self):
        """Compilations carry reissue dates, so the folder is the only honest
        grouping; the year-provenance warning is then irrelevant."""
        conn = db.connect(self.db)
        try:
            text = report.lowend_report(conn, group_by="folder")
        finally:
            conn.close()
        self.assertIn("Median shape per folder", text)
        self.assertNotIn("RELEASE", text)
        self.assertIn("No reference chosen", text)

    def test_lowend_by_folder_builds_a_curve_against_a_chosen_reference(self):
        conn = db.connect(self.db)
        try:
            text = report.lowend_report(conn, group_by="folder",
                                        reference="nested")
        finally:
            conn.close()
        self.assertIn("Difference from the", text)
        self.assertNotIn("No reference chosen", text)

    def test_reissue_dates_are_flagged_in_the_lowend_report(self):
        """The tagged fixture carries date=1978 and no original date."""
        conn = db.connect(self.db)
        try:
            text = report.lowend_report(conn)
        finally:
            conn.close()
        self.assertIn("RELEASE", text)

    def test_unknown_estimator_is_rejected(self):
        conn = db.connect(self.db)
        try:
            with self.assertRaises(ValueError):
                report.tracks_report(conn, estimator="not_a_column")
        finally:
            conn.close()


if __name__ == "__main__":
    unittest.main()
