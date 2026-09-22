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
