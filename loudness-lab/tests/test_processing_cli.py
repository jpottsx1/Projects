"""The processing command, as the Mac app drives it.

The app does not reimplement the chain any more -- it runs this. That makes
the wire between them a real interface rather than a debugging convenience,
so it is tested like one: every line parseable, a count that only goes up,
and the flags the app needs actually doing what the app assumes.
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
from pathlib import Path

from loudnesslab import cli, decode, subbass, write

from tests.test_subbass import RATE, programme

HAVE_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
TOOL = Path(__file__).resolve().parents[1] / "loudness-lab"


def _fixture(root: Path, names, seconds: float = 6.0) -> None:
    root.mkdir(parents=True, exist_ok=True)
    x, _ = programme(seconds=seconds)
    for name in names:
        subbass.write_flac(root / f"{name}.flac", x, RATE)


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class TestSubbassPorcelain(unittest.TestCase):
    """Progress a program can read, for the half of the work that takes the
    time. Measuring already had this; processing is where the minutes are."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.src = self.dir / "src"
        _fixture(self.src, ("Talk Talk - Its My Life", "Duran Duran - Rio"))

    def _run(self, *extra: str) -> list[dict]:
        out = subprocess.run(
            [sys.executable, str(TOOL), "subbass", str(self.src),
             "--db", str(self.dir / "l.db"), "--out", str(self.dir / "out"),
             "--amount", "3", "--jobs", "1", "--porcelain", *extra],
            capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        return [json.loads(line) for line in out.stdout.splitlines() if line.strip()]

    def test_nothing_but_json_goes_to_stdout(self):
        """A stray print would break the caller on a line it cannot parse.

        This command prints a great deal for a person -- a header, two
        column legends, a table and a policy preview -- so it is a much
        easier thing to get wrong here than in the analysis pass.
        """
        for event in self._run():
            self.assertIn("event", event)

    def test_both_phases_report_progress_separately(self):
        """The app shows one bar. It has to know which half it is in, or
        measuring two tracks then processing two looks like four of two."""
        events = self._run()
        phases = [e.get("phase") for e in events if e["event"] == "progress"]
        self.assertEqual(phases, ["measure", "measure", "process", "process"])
        for phase in ("measure", "process"):
            steps = [e for e in events
                     if e["event"] == "progress" and e["phase"] == phase]
            self.assertEqual([e["done"] for e in steps], [1, 2])
            self.assertTrue(all(e["total"] == 2 for e in steps))

    def test_the_last_line_says_where_the_manifest_is(self):
        """So the app reads the file the run wrote rather than guessing at a
        path and silently showing the previous run's results."""
        events = self._run()
        done = events[-1]
        self.assertEqual(done["event"], "done")
        self.assertEqual(done["written"], 2)
        self.assertEqual(done["errors"], 0)
        manifest = Path(done["manifest"])
        self.assertTrue(manifest.is_file())
        self.assertEqual(len(json.loads(manifest.read_text())["tracks"]), 2)

    def test_a_refusal_is_reported_as_json_too(self):
        """The failure path is the one a caller cannot recover from by
        guessing, so it must not be the one that prints prose."""
        out = subprocess.run(
            [sys.executable, str(TOOL), "subbass", str(self.src),
             "--db", str(self.dir / "l.db"), "--auto", "--porcelain"],
            capture_output=True, text=True)
        self.assertEqual(out.returncode, 2)
        events = [json.loads(line) for line in out.stdout.splitlines() if line.strip()]
        self.assertEqual(events[-1]["event"], "error")
        self.assertIn("reference", events[-1]["message"])


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class TestSelectionAndDuplicates(unittest.TestCase):

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.src = self.dir / "src"
        self.out = self.dir / "out"

    def _run(self, *extra: str) -> int:
        # Porcelain, so the run is exercised the way the app drives it, and
        # swallowed, so the test output stays readable.
        with contextlib.redirect_stdout(io.StringIO()):
            return cli.main(["subbass", str(self.src), "--db",
                             str(self.dir / "l.db"), "--out", str(self.out),
                             "--amount", "3", "--jobs", "1", "--porcelain",
                             *extra])

    def test_select_restricts_the_batch_to_the_listed_paths(self):
        """The app's ticked list. Without this the app could only ever say
        'the thinnest N', which is not what the middle pane shows."""
        _fixture(self.src, ("one", "two", "three"))
        listing = self.dir / "chosen.txt"
        listing.write_text(str(self.src / "two.flac") + "\n")
        self.assertEqual(self._run("--select", str(listing), "--no-compare"), 0)
        self.assertEqual(sorted(p.stem for p in self.out.glob("*.flac")), ["two"])

    def test_select_is_applied_before_the_limit(self):
        """Unticking a track has to promote the next one into range. If the
        limit ran first, unticking would leave a gap instead."""
        _fixture(self.src, ("one", "two", "three"))
        listing = self.dir / "chosen.txt"
        listing.write_text("\n".join(str(self.src / f"{n}.flac")
                                     for n in ("one", "two", "three")))
        self.assertEqual(self._run("--select", str(listing), "--limit", "2",
                                   "--no-compare"), 0)
        self.assertEqual(len(list(self.out.glob("*.flac"))), 2)

    def test_skip_duplicates_does_a_record_once(self):
        """A library of compilations is mostly the same forty songs. Two
        copies is one decode, one encode and one lossy generation wasted."""
        x, _ = programme(seconds=6.0)
        for disc in ("Disc 1", "Disc 2"):
            folder = self.src / disc
            folder.mkdir(parents=True)
            path = folder / "track.flac"
            subbass.write_flac(path, x, RATE)
            subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y",
                            "-i", str(path), "-metadata", "artist=Chic",
                            "-metadata", "title=Le Freak",
                            "-c:a", "copy", str(folder / "tagged.flac")],
                           check=True)
            path.unlink()
        self.assertEqual(self._run("--skip-duplicates", "--no-compare"), 0)
        self.assertEqual(len(list(self.out.glob("*.flac"))), 1)
        # And without it, both -- so the test is about the flag and not
        # about the fixture happening to produce one file.
        shutil.rmtree(self.out)
        self.assertEqual(self._run("--no-compare"), 0)
        self.assertEqual(len(list(self.out.glob("*.flac"))), 2)

    def test_two_tracks_of_the_same_name_do_not_overwrite_each_other(self):
        """Every output lands in one folder, and a library of compilations
        is full of files called "01 Track". Writing both to one path would
        lose one and report both as written."""
        x, _ = programme(seconds=6.0)
        for disc in ("Disc 1", "Disc 2"):
            (self.src / disc).mkdir(parents=True)
            subbass.write_flac(self.src / disc / "01 Track.flac", x, RATE)
        self.assertEqual(self._run("--no-compare"), 0)
        produced = sorted(p.stem for p in self.out.glob("*.flac"))
        self.assertEqual(len(produced), 2, produced)
        self.assertEqual(len(set(produced)), 2, produced)

    def test_untagged_files_are_never_duplicates_of_each_other(self):
        """Identity falls back to the path, which is unique. Folding every
        untagged file into one would silently drop most of a batch."""
        _fixture(self.src, ("one", "two", "three"))
        self.assertEqual(self._run("--skip-duplicates", "--no-compare"), 0)
        self.assertEqual(len(list(self.out.glob("*.flac"))), 3)


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class TestOutputFormats(unittest.TestCase):
    """The format is the app's to choose, so the command has to offer it --
    and both sides of a comparison pair must get the same one, or the
    listener is comparing codecs."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.src = self.dir / "src"
        self.out = self.dir / "out"
        _fixture(self.src, ("track",))

    def _run(self, fmt: str, *extra: str) -> int:
        with contextlib.redirect_stdout(io.StringIO()):
            return cli.main(["subbass", str(self.src), "--db",
                             str(self.dir / "l.db"), "--out", str(self.out),
                             "--amount", "3", "--jobs", "1", "--format", fmt,
                             "--porcelain", *extra])

    def test_each_format_writes_its_own_extension(self):
        for fmt, suffix in (("flac", ".flac"), ("mp3", ".mp3"), ("aac", ".m4a")):
            with self.subTest(fmt=fmt):
                shutil.rmtree(self.out, ignore_errors=True)
                self.assertEqual(self._run(fmt, "--no-compare"), 0)
                produced = [p for p in self.out.iterdir() if p.suffix != ".json"]
                self.assertEqual([p.suffix for p in produced], [suffix])

    def test_both_sides_of_a_pair_get_the_same_format(self):
        self.assertEqual(self._run("mp3"), 0)
        produced = sorted(p.suffix for p in self.out.glob("*A original*")) \
            + sorted(p.suffix for p in self.out.glob("*B *"))
        self.assertEqual(produced, [".mp3", ".mp3"])

    def test_a_lossy_render_still_decodes_to_the_same_length(self):
        """Cue positions are times. A format that shifted the audio would
        move every marker in the file, which is worse than dropping them."""
        self.assertEqual(self._run("flac", "--no-compare"), 0)
        lossless = decode.decode(next(self.out.glob("*.flac")))
        shutil.rmtree(self.out)
        self.assertEqual(self._run("mp3", "--no-compare"), 0)
        lossy = decode.decode(next(self.out.glob("*.mp3")))
        # Within a frame: LAME writes its delay and padding into the header
        # and the decoder gives them back.
        self.assertLess(abs(lossy.shape[0] - lossless.shape[0]), 1152)

    def test_the_manifest_names_the_files_that_were_actually_written(self):
        """It carries paths, and the player opens them. An extension left
        over from the default would give a manifest of files that do not
        exist."""
        self.assertEqual(self._run("aac", "--no-compare"), 0)
        manifest = json.loads((self.out / "manifest.json").read_text())
        for track in manifest["tracks"]:
            for variant in track["variants"]:
                self.assertTrue(Path(variant["path"]).is_file(), variant["path"])
                self.assertEqual(Path(variant["path"]).suffix, ".m4a")

    def test_the_manifest_carries_the_air_figure(self):
        """The app's Results table has an Air column reading this. Without
        it in the manifest, air ran and nothing on screen could say by
        how much."""
        self.assertEqual(self._run("flac", "--no-compare", "--air", "3"), 0)
        manifest = json.loads((self.out / "manifest.json").read_text())
        tracks = manifest["tracks"]
        self.assertTrue(tracks)
        for track in tracks:
            self.assertIsInstance(track["air_db"], (int, float))


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class TestDynamicsThroughTheCommand(unittest.TestCase):
    """The two dynamics stages, as the app drives them.

    Tested here rather than only in test_expand because the wiring is where
    this goes wrong: a stage can be perfect and still never run, because a
    guard decided the profile asked for nothing.
    """

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.src = self.dir / "src"
        self.out = self.dir / "out"
        self.src.mkdir(parents=True)
        from tests.test_expand import peak_limited, sectioned, slow_compressed
        subbass.write_flac(self.src / "squashed.flac",
                           slow_compressed(sectioned(), ratio=8.0,
                                           threshold_db=-28.0), RATE)
        subbass.write_flac(self.src / "limited.flac",
                           peak_limited(sectioned()), RATE)

    def _events(self, *extra: str) -> list[dict]:
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = cli.main(["subbass", str(self.src), "--db",
                             str(self.dir / "l.db"), "--out", str(self.out),
                             "--no-compare", "--jobs", "1", "--porcelain",
                             *extra])
        self.assertEqual(code, 0, buffer.getvalue())
        return [json.loads(line) for line in buffer.getvalue().splitlines()
                if line.strip()]

    def test_dynamics_alone_is_enough_to_have_something_to_do(self):
        """With no sub, no punch and no declip the command normally
        declines, on the grounds that it would decode every track and write
        copies of them. A range or attack setting IS a change, and the
        guard has to know that or the stages are unreachable from a profile
        that asks for nothing else."""
        events = self._events("--amount", "0", "--target-lra", "9")
        self.assertEqual(events[-1]["event"], "done")
        self.assertEqual(events[-1]["written"], 2)

    def test_without_any_of_them_it_still_declines(self):
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            code = cli.main(["subbass", str(self.src), "--db",
                             str(self.dir / "l.db"), "--amount", "0",
                             "--porcelain"])
        self.assertEqual(code, 0)
        self.assertIn("changes nothing", buffer.getvalue())

    def test_the_range_reaches_the_target_through_the_whole_chain(self):
        """End to end, not just in the stage: the levelling that follows
        scales the whole file, which cannot change a ratio of loudnesses,
        so the range asked for is the range that survives to the file."""
        events = self._events("--amount", "0", "--target-lra", "9")
        rows = [e for e in events if e["event"] == "progress"
                and e.get("phase") == "process" and e.get("lra_after")]
        self.assertTrue(rows)
        for row in rows:
            self.assertLess(row["lra_after"], 9.0 + 0.6)
            self.assertGreater(row["lra_after"], row["lra_before"])

    def test_each_stage_declines_on_the_damage_it_does_not_repair(self):
        """The argument the whole module rests on. The squashed fixture has
        range taken out and its peaks intact; the limited one the reverse.
        Each stage should act on one and decline on the other."""
        events = self._events("--amount", "0", "--target-lra", "9",
                              "--transient", "3", "--min-crest", "12")
        rows = {e["name"]: e for e in events
                if e["event"] == "progress" and e.get("phase") == "process"}
        self.assertEqual(set(rows), {"squashed", "limited"})
        # Squashed: range widens a long way, crest is left alone.
        self.assertGreater(rows["squashed"]["lra_after"]
                           - rows["squashed"]["lra_before"], 3.0)
        self.assertIsNone(rows["squashed"]["crest_after"])
        # Limited: crest comes back, and the range stage declines outright
        # -- its LRA is already inside the margin of the target, so there is
        # no `lra_after` at all. That is a stronger result than a small
        # change would have been: the stage did not act, rather than acting
        # to no effect.
        self.assertGreater(rows["limited"]["crest_after"]
                           - rows["limited"]["crest_before"], 0.7)
        self.assertIsNone(rows["limited"]["lra_after"])
        self.assertGreater(rows["limited"]["lra_before"], 9.0 - 0.5)

    def test_the_originals_are_never_written_to(self):
        """The standing rule, checked where a new stage could break it."""
        before = {p: p.read_bytes() for p in self.src.glob("*.flac")}
        self._events("--amount", "0", "--target-lra", "9", "--transient", "3")
        for path, content in before.items():
            self.assertEqual(path.read_bytes(), content, path.name)


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class TestSeratoSurvivesTheCommand(unittest.TestCase):
    """The standing rule, tested where it now actually happens.

    Cue points and beatgrids live in ID3 GEOB frames. ffmpeg drops them --
    measured, two frames in and none out -- so the original's whole tag is
    spliced back on. That used to be the Swift's job and is now the
    command's, which means the rule needs a test on this side of the line.
    """

    def test_a_geob_frame_arrives_unchanged_in_the_processed_mp3(self):
        from tests.test_mp3gain import _id3_with_geob

        with tempfile.TemporaryDirectory() as tmp:
            root, out = Path(tmp) / "src", Path(tmp) / "out"
            _fixture(root, ("marked",))
            bare = root / "marked.mp3"
            subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y",
                            "-i", str(root / "marked.flac"),
                            "-c:a", "libmp3lame", "-b:a", "320k", str(bare)],
                           check=True)
            (root / "marked.flac").unlink()
            # A payload no encoder would produce by accident, so finding it
            # in the output cannot be a coincidence.
            payload = b"Serato Markers2\x00" + bytes(range(64))
            tag = _id3_with_geob(payload)
            bare.write_bytes(tag + bare.read_bytes())

            with contextlib.redirect_stdout(io.StringIO()):
                code = cli.main(["subbass", str(root), "--db",
                                 str(Path(tmp) / "l.db"), "--out", str(out),
                                 "--amount", "3", "--format", "mp3",
                                 "--no-compare", "--jobs", "1", "--porcelain"])
            self.assertEqual(code, 0)
            written = next(out.glob("*.mp3")).read_bytes()

        self.assertTrue(written.startswith(tag),
                        "the original tag is not at the front of the new file")
        self.assertIn(payload, written)
        self.assertEqual(written.count(payload), 1)

    def test_a_flac_source_is_not_given_an_id3_tag_it_never_had(self):
        """Only MP3 to MP3 is a copy. Splicing an ID3 tag onto anything else
        would be inventing a container's contents."""
        with tempfile.TemporaryDirectory() as tmp:
            root, out = Path(tmp) / "src", Path(tmp) / "out"
            _fixture(root, ("plain",))
            with contextlib.redirect_stdout(io.StringIO()):
                code = cli.main(["subbass", str(root), "--db",
                                 str(Path(tmp) / "l.db"), "--out", str(out),
                                 "--amount", "3", "--format", "mp3",
                                 "--no-compare", "--jobs", "1", "--porcelain"])
            self.assertEqual(code, 0)
            written = next(out.glob("*.mp3")).read_bytes()
        self.assertFalse(written.startswith(b"ID3ID3"))


class TestSeratoTagCarry(unittest.TestCase):
    """Serato's cue points live in ID3 GEOB frames, which ffmpeg drops. The
    whole tag is spliced back on instead -- bytes, never interpreted."""

    def test_the_length_is_read_syncsafe(self):
        """Seven bits a byte. Read as a plain integer, a tag of 0x80 bytes
        reads as 0x80 rather than 128 and the splice lands in the audio."""
        header = b"ID3\x04\x00\x00" + bytes([0, 0, 1, 0])
        self.assertEqual(write.id3v2_length(header), 10 + 128)

    def test_a_footer_is_counted(self):
        header = b"ID3\x04\x00\x10" + bytes([0, 0, 1, 0])
        self.assertEqual(write.id3v2_length(header), 10 + 128 + 10)

    def test_a_file_with_no_tag_reads_as_no_tag(self):
        self.assertEqual(write.id3v2_length(b"\xff\xfb\x90\x00" + b"\x00" * 6), 0)
        self.assertEqual(write.id3v2_length(b"ID3"), 0)

    def test_the_whole_tag_arrives_byte_for_byte(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "a.mp3"
            target = Path(tmp) / "b.mp3"
            payload = bytes(range(64)) * 2
            tag = b"ID3\x04\x00\x00" + bytes([0, 0, 1, 0]) + payload \
                + b"\x00" * (128 - len(payload))
            source.write_bytes(tag + b"AUDIO-OF-THE-ORIGINAL")
            target.write_bytes(b"AUDIO-OF-THE-COPY")
            self.assertTrue(write.carry_id3v2(source, target))
            self.assertEqual(target.read_bytes(), tag + b"AUDIO-OF-THE-COPY")

    def test_nothing_is_written_when_there_is_nothing_to_carry(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "a.mp3"
            target = Path(tmp) / "b.mp3"
            source.write_bytes(b"\xff\xfb\x90\x00" + b"\x00" * 64)
            target.write_bytes(b"AUDIO")
            self.assertFalse(write.carry_id3v2(source, target))
            self.assertEqual(target.read_bytes(), b"AUDIO")


if __name__ == "__main__":
    unittest.main()


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class TestWhyTheSubIsWhatItIs(unittest.TestCase):
    """"+0.00 dB" on Mary Jane Girls and Basement Jaxx, with no reason:
    the results now say what the sub was asked for and why."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)

    def manifest(self, *extra: str) -> list[dict]:
        out = subprocess.run(
            [sys.executable, str(TOOL), "subbass", *extra,
             "--db", str(self.dir / "l.db"), "--out", str(self.dir / "out"),
             "--jobs", "1", "--porcelain"],
            capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)
        done = json.loads(out.stdout.splitlines()[-1])
        return json.loads(Path(done["manifest"]).read_text())["tracks"]

    def test_a_track_already_at_the_reference_says_so_with_air_on(self):
        # The same audio in both folders: no shortfall at all. Air on, so
        # the track is still processed -- which is where the reason used
        # to be thrown away.
        ref, src = self.dir / "ref", self.dir / "src"
        _fixture(ref, ("Reference One", "Reference Two"))
        _fixture(src, ("Mary Jane Girls - In My House",))
        listing = self.dir / "chosen.txt"
        listing.write_text(str(src / "Mary Jane Girls - In My House.flac") + "\n")
        tracks = self.manifest(str(src), str(ref), "--auto", "--reference", "ref",
                               "--air", "2", "--air-fixed", "--select", str(listing))
        self.assertEqual(len(tracks), 1)
        self.assertEqual(tracks[0]["sub_db"], 0.0)
        self.assertEqual(tracks[0]["sub_asked_db"], 0.0)
        self.assertIn("already within", tracks[0]["sub_note"])
        self.assertIn("of the reference", tracks[0]["sub_note"])

    def test_a_fixed_amount_is_what_was_asked(self):
        src = self.dir / "src"
        _fixture(src, ("Sheila E. - A Love Bizarre",))
        tracks = self.manifest(str(src), "--amount", "3")
        self.assertEqual(tracks[0]["sub_asked_db"], 3.0)
        self.assertAlmostEqual(tracks[0]["sub_db"], 3.0, delta=0.5)


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class TestTheReferenceAsAFolder(unittest.TestCase):
    """2026-09-27: the app passed a chosen folder as a full path, and
    '/Users/jeff/Downloads/Gathered/FLAC/New Music 2026-09-23' matched
    none -- labels have no leading '/', the folder had not been measured,
    and its tracks were in subfolders."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.src = self.dir / "src"
        _fixture(self.src, ("Mary Jane Girls - In My House",))
        # The reference: two albums in subfolders, nothing loose.
        self.ref = self.dir / "Gathered" / "FLAC" / "New Music 2026-09-23"
        _fixture(self.ref / "Album One", ("One",))
        _fixture(self.ref / "Album Two", ("Two",))

    def run_it(self, reference: str) -> list[dict]:
        out = subprocess.run(
            [sys.executable, str(TOOL), "subbass", str(self.src), "--auto",
             "--reference", reference, "--db", str(self.dir / "l.db"),
             "--out", str(self.dir / "out"), "--jobs", "1", "--porcelain"],
            capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        return [json.loads(line) for line in out.stdout.splitlines() if line.strip()]

    def test_a_full_path_never_measured_with_its_tracks_in_subfolders(self):
        events = self.run_it(str(self.ref))
        selected = [e for e in events if e["event"] == "selected"][0]
        self.assertEqual(selected["reference"], str(self.ref.resolve()))
        # Measured (1 track to process + 2 in the reference), processed: 1.
        measured = [e for e in events if e["event"] == "measured"][0]
        self.assertEqual(measured["analysed"], 3)
        # The same audio as the reference: nothing to add, and it says so.
        # Only the one track was worked on; the reference was not.
        processed = [e for e in events
                     if e["event"] == "progress" and e.get("phase") == "process"]
        self.assertEqual([e["name"] for e in processed],
                         ["Mary Jane Girls - In My House"])
        self.assertIn("already within", processed[0]["reason"])

    def test_a_trailing_slash_and_spaces(self):
        events = self.run_it("  " + str(self.ref) + "/ ")
        self.assertEqual(events[-1]["event"], "done")

    def test_a_folder_that_is_not_there(self):
        out = subprocess.run(
            [sys.executable, str(TOOL), "subbass", str(self.src), "--auto",
             "--reference", str(self.dir / "nowhere"), "--db", str(self.dir / "l.db"),
             "--porcelain"], capture_output=True, text=True)
        self.assertEqual(out.returncode, 2)
        self.assertIn("is not a folder", json.loads(out.stdout.splitlines()[-1])["message"])

    def test_a_label_naming_a_folder_of_subfolders(self):
        # Measure everything first, then name the parent by its label.
        subprocess.run([sys.executable, str(TOOL), "analyze", str(self.dir),
                        "--db", str(self.dir / "l.db")], capture_output=True)
        events = self.run_it("New Music 2026-09-23")
        self.assertEqual(events[-1]["event"], "done")

    def test_two_folders_of_the_same_name_are_not_pooled(self):
        _fixture(self.dir / "Other" / "New Music 2026-09-23", ("Three",))
        subprocess.run([sys.executable, str(TOOL), "analyze", str(self.dir),
                        "--db", str(self.dir / "l.db")], capture_output=True)
        out = subprocess.run(
            [sys.executable, str(TOOL), "subbass", str(self.src), "--auto",
             "--reference", "New Music 2026-09-23", "--db", str(self.dir / "l.db"),
             "--porcelain"], capture_output=True, text=True)
        self.assertEqual(out.returncode, 2)
        self.assertIn("matched none (or matched several)", out.stdout)


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class TestAProfileWithSeveralReferenceFolders(unittest.TestCase):
    """Jeff, 2026-09-28: "build profiles for music to be run against
    specifically -- let the user measure a series of folders per profile,
    such as dance, 2020s, pop, disco". Several folders, one target."""

    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)
        self.src = self.dir / "src"
        _fixture(self.src, ("Bee Gees - Night Fever",))
        self.disco_a = self.dir / "Disco" / "Remasters"
        self.disco_b = self.dir / "Disco" / "12 inch"
        _fixture(self.disco_a, ("One",))
        # Different music in the second folder, or pooling one folder and
        # pooling both would read the same.
        _fixture(self.disco_b, ("Two", "Three"), seconds=11.0)

    def run_it(self, *refs: str, code: int = 0) -> list[dict]:
        args = [sys.executable, str(TOOL), "subbass", str(self.src), "--auto",
                "--db", str(self.dir / "l.db"), "--out", str(self.dir / "out"),
                "--jobs", "1", "--porcelain"]
        for ref in refs:
            args += ["--reference-folder", ref]
        out = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(out.returncode, code, out.stdout + out.stderr)
        return [json.loads(line) for line in out.stdout.splitlines() if line.strip()]

    def test_two_folders_measured_and_pooled(self):
        events = self.run_it(str(self.disco_a), str(self.disco_b))
        measured = [e for e in events if e["event"] == "measured"][0]
        self.assertEqual(measured["analysed"], 4)          # 1 to process + 3 reference
        selected = [e for e in events if e["event"] == "selected"][0]
        self.assertEqual(selected["reference"],
                         f"{self.disco_a.resolve()} + {self.disco_b.resolve()}")
        processed = [e for e in events if e.get("phase") == "process"]
        self.assertEqual([e["name"] for e in processed], ["Bee Gees - Night Fever"])

    def test_one_folder_missing_stops_the_run_naming_it(self):
        events = self.run_it(str(self.disco_a), str(self.dir / "Gone"), code=2)
        self.assertIn("Gone", events[-1]["message"])
        self.assertIn("is not a folder", events[-1]["message"])

    def test_pooled_means_every_track_counts_once(self):
        from loudnesslab import cli, db
        self.run_it(str(self.disco_a), str(self.disco_b))
        conn = db.connect(self.dir / "l.db")
        try:
            name, curve, missing = cli._reference_curve_of(
                conn, [str(self.disco_a), str(self.disco_b)])
            _, values_a = cli._reference_values(conn, str(self.disco_a), report_bands())
            _, values_b = cli._reference_values(conn, str(self.disco_b), report_bands())
        finally:
            conn.close()
        self.assertIsNone(missing)
        import numpy as np
        differs = False
        for band, value in curve.items():
            pooled = values_a[band] + values_b[band]
            self.assertEqual(len(pooled), 3)
            self.assertAlmostEqual(value, float(np.median(pooled)))
            differs |= abs(value - float(np.median(values_a[band]))) > 0.01
        self.assertTrue(differs, "the second folder changed nothing")

    def test_a_folder_name_that_matches_nothing_stops_the_run(self):
        # A name rather than a path: it gets past measuring and has to be
        # caught where the target is built, named, not pooled around.
        events = self.run_it(str(self.disco_a), "No Such Folder", code=2)
        self.assertIn("'No Such Folder' matched none", events[-1]["message"])

    def test_the_manifest_records_them(self):
        self.run_it(str(self.disco_a))   # measure; nothing written for a skipped track
        out = subprocess.run(
            [sys.executable, str(TOOL), "subbass", str(self.src), "--amount", "3",
             "--reference-folder", str(self.disco_a), "--db", str(self.dir / "l.db"),
             "--out", str(self.dir / "out2"), "--jobs", "1", "--porcelain"],
            capture_output=True, text=True)
        done = json.loads(out.stdout.splitlines()[-1])
        settings = json.loads(Path(done["manifest"]).read_text())["settings"]
        self.assertEqual(settings["references"], [str(self.disco_a)])


def report_bands():
    from loudnesslab import report
    return report.LOW_SHAPE_BANDS


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
class TestAirIsSizedFromTheTopOctave(unittest.TestCase):
    """Night Fever got "virtually no air when it clearly needs it"
    (2026-09-28): bright hi-hats made its 8-20 kHz average read as enough
    while its top octave was missing. Sized from 16-20 kHz it is short."""

    def test_bright_hats_do_not_hide_a_missing_top_octave(self):
        import numpy as np
        from scipy.signal import butter, sosfiltfilt
        from loudnesslab import db, report
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory, ignore_errors=True)
        (directory / "ref").mkdir()
        (directory / "src").mkdir()
        x, _ = programme(seconds=8.0)
        rng = np.random.default_rng(1)
        top = sosfiltfilt(butter(4, 14000, btype="high", fs=RATE, output="sos"),
                          rng.standard_normal(x.shape[0]))
        hats = sosfiltfilt(butter(4, [7000, 11000], btype="band", fs=RATE,
                                  output="sos"), rng.standard_normal(x.shape[0]))
        reference = x + 0.02 * np.stack([top] * 2, 1) + 0.03 * np.stack([hats] * 2, 1)
        track = x + 0.8 * np.stack([hats] * 2, 1)
        track = sosfiltfilt(butter(8, 15000, fs=RATE, output="sos"), track, axis=0)
        subbass.write_flac(directory / "ref" / "Reference.flac",
                           reference.astype(np.float32), RATE)
        path = directory / "src" / "Bee Gees - Night Fever.flac"
        subbass.write_flac(path, track.astype(np.float32), RATE)
        # A real run, the way the app drives it: what the track actually got.
        out = subprocess.run(
            [sys.executable, str(TOOL), "subbass", str(directory / "src"),
             "--auto", "--amount", "0", "--air", "12",
             "--reference-folder", str(directory / "ref"),
             "--db", str(directory / "l.db"), "--out", str(directory / "out"),
             "--jobs", "1", "--porcelain"], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        events = [json.loads(line) for line in out.stdout.splitlines() if line.strip()]
        processed = [e for e in events if e.get("phase") == "process"][0]
        self.assertAlmostEqual(processed["air_db"], 12.0, delta=0.1)
        # What the old band made of the same track: nothing to add.
        conn = db.connect(directory / "l.db")
        try:
            _, old, _ = cli._reference_curve_of(conn, [str(directory / "ref")],
                                                bands=report.TOP_SHAPE_BANDS)
            amount, why = cli._auto_amount(conn, str(path), old, 12.0,
                                           bands=report.TOP_SHAPE_BANDS)
        finally:
            conn.close()
        self.assertEqual(amount, 0.0)
        self.assertIn("already within", why)
