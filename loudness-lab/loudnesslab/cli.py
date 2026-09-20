"""Command line entry point."""

from __future__ import annotations

import argparse
import csv
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from . import __version__, analyze, apply_gain, db, decode, mp3gain, report


def _progress_printer(start: float):
    def show(done: int, total: int, result: dict) -> None:
        elapsed = time.monotonic() - start
        rate = done / elapsed if elapsed > 0 else 0
        remaining = (total - done) / rate if rate > 0 else 0
        status = result["track"]["status"]
        mark = "." if status == "ok" else "!"
        name = Path(result["track"]["path"]).name
        sys.stderr.write(
            f"\r[{done}/{total}] {mark} {rate:4.1f}/s  eta {remaining / 60:5.1f}m  "
            f"{name[:48]:<48s}")
        sys.stderr.flush()
        if status != "ok":
            sys.stderr.write(f"\n  {name}: {result['track']['error']}\n")
    return show


def cmd_analyze(args: argparse.Namespace) -> int:
    start = time.monotonic()
    counts = analyze.run(
        roots=args.path, db_path=args.db, jobs=args.jobs,
        force=args.force, limit=args.limit,
        progress=None if args.quiet else _progress_printer(start),
    )
    if not args.quiet:
        sys.stderr.write("\n")
    elapsed = time.monotonic() - start
    print(f"found {counts['found']}  "
          f"skipped {counts['skipped']} (already current)  "
          f"analysed {counts['analysed']}  errors {counts['errors']}  "
          f"in {elapsed / 60:.1f} min")
    if counts["errors"]:
        print(f"run `loudness-lab report errors --db {args.db}` for details")
    return 0


def cmd_gain(args: argparse.Namespace) -> int:
    """Lossless gain. Dry run unless --apply is given.

    Analyses anything not already measured, so pointing this at a folder is
    enough -- no separate scan step, and no database path to keep in step
    with it.
    """
    if args.in_place and args.out:
        sys.stderr.write("error: choose --out or --in-place, not both\n")
        return 2
    out_dir = None if args.in_place else (args.out or Path("gained"))
    database = args.db or (
        Path("scans") / f"{_slug(args.path[0])}.db" if args.path
        else Path("library.db"))
    database.parent.mkdir(parents=True, exist_ok=True)

    if args.path and not args.undo and not args.no_analyze:
        start = time.monotonic()
        counts = analyze.run(
            roots=args.path, db_path=database, jobs=args.jobs,
            progress=None if args.quiet else _progress_printer(start))
        if not args.quiet:
            sys.stderr.write("\n")
        if counts["analysed"] or counts["errors"]:
            print(f"measured {counts['analysed']} new file(s), "
                  f"{counts['skipped']} already current, "
                  f"{counts['errors']} error(s)")
            print()

    conn = db.connect(database)
    try:
        if args.undo:
            counts = apply_gain.undo(conn, args.path or None)
            print(f"undone {counts['undone']}  failed {counts['failed']}  "
                  f"skipped {counts['skipped']}")
            return 1 if counts["failed"] else 0

        proposals = apply_gain.propose(conn, args.path, args.estimator,
                                       args.target, out_dir,
                                       peak_ceiling=args.peak_ceiling)
        if not proposals:
            print("no .mp3 files found under those paths")
            return 1

        usable = [p for p in proposals if p.ok]
        blocked = [p for p in proposals if not p.ok]
        moving = [p for p in usable if p.plan.steps != 0]

        print(f"LOSSLESS GAIN  estimator={args.estimator}  "
              f"target={args.target:+.1f}  step={mp3gain.DB_PER_STEP:.3f} dB")
        print("=" * 100)
        print("  Rewrites global_gain in the audio frames. No decode, no re-encode,")
        print("  no generation loss. The ID3 region -- including Serato's GEOB cue")
        print("  points and beatgrids -- is copied through untouched.")
        print()
        print(f"  {'artist / title':<44s}{'now':>8s}{'want':>8s}"
              f"{'applied':>9s}{'off by':>8s}  note")
        for proposal in sorted(usable, key=lambda p: p.wanted_db)[:args.limit]:
            name = " - ".join(x for x in (proposal.artist, proposal.title) if x) \
                or proposal.path.name
            note = ""
            if proposal.peak_capped_from is not None:
                note = (f"held to {args.peak_ceiling:+.1f} dBTP "
                        f"(wanted {proposal.peak_capped_from:+.1f} dB)")
            if proposal.plan.clamped:
                note = (f"clamped at {proposal.plan.headroom_down_db:+.2f} dB "
                        f"by {proposal.plan.lowest_count} granule(s) at "
                        f"global_gain {proposal.plan.lowest_gain}")
            if proposal.plan.steps == 0:
                note = note or "already within half a step"
            print(f"  {name[:43]:<44s}{proposal.measured:8.1f}"
                  f"{proposal.wanted_db:+8.1f}{proposal.plan.applied_db:+9.2f}"
                  f"{proposal.residual_db:+8.2f}  {note}")
        if len(usable) > args.limit:
            print(f"  ... {len(usable) - args.limit} more")

        if usable:
            residuals = [abs(p.residual_db) for p in usable]
            print()
            print(f"  {len(moving)} of {len(usable)} files would change. "
                  f"Quantisation error: median "
                  f"{sorted(residuals)[len(residuals) // 2]:.2f} dB, "
                  f"worst {max(residuals):.2f} dB.")
            protected = sum(1 for p in usable if p.plan.protected_frames)
            if protected:
                print(f"  {protected} file(s) carry frame CRCs; those are "
                      f"recomputed on write.")
            capped = [p for p in usable if p.peak_capped_from is not None]
            if capped:
                print(f"  {len(capped)} file(s) held back by the "
                      f"{args.peak_ceiling:+.1f} dBTP ceiling rather than "
                      f"being pushed into clipping.")
            clamped = [p for p in usable if p.plan.clamped]
            if clamped:
                print(f"  {len(clamped)} file(s) clamped: a granule sits too "
                      f"close to global_gain 0 to shift the")
                print("  whole file uniformly. Empty granules are already "
                      "ignored, so these carry")
                print("  data. Attenuating only the rest would change the "
                      "track's own dynamics,")
                print("  which is the one thing this tool will not do.")
        if blocked:
            print()
            print(f"  {len(blocked)} file(s) cannot be processed:")
            for proposal in blocked[:10]:
                print(f"    {proposal.path.name}: {proposal.problem}")

        if not args.apply:
            print()
            print("  DRY RUN -- nothing was written. Add --apply to write.")
            if out_dir is not None:
                print(f"  Output would go to: {out_dir}/")
            return 0

        if args.in_place and not args.yes:
            print()
            print("  --in-place rewrites your originals. It is reversible with")
            print("  `gain --undo`, but re-run with --yes to confirm.")
            return 2

        counts = apply_gain.apply(conn, proposals, in_place=args.in_place)
        print()
        print(f"written {counts['written']}  unchanged {counts['unchanged']}  "
              f"skipped {counts['skipped']}  failed {counts['failed']}")
        if counts["failed"]:
            for proposal in proposals:
                if proposal.problem and proposal.plan is not None:
                    print(f"  {proposal.path.name}: {proposal.problem}")
            return 1
        if not args.in_place:
            print(f"Originals untouched. Modified copies are in: {out_dir}/")
        print("Serato's stored auto-gain and waveform overview for these tracks")
        print("are now stale -- let it re-analyse them, and turn its own")
        print("auto-gain off if you want this tool to own loudness.")
        return 0
    finally:
        conn.close()


def _slug(path: Path) -> str:
    """A filesystem-safe name derived from a folder, for default outputs."""
    name = path.name or path.parent.name or "library"
    slug = re.sub(r"[^A-Za-z0-9]+", "-", name).strip("-").lower()
    return (slug or "library")[:60]


def cmd_scan(args: argparse.Namespace) -> int:
    """Analyse a folder and print every report, in one command.

    Saves the same text to a file, because the reports are long and the whole
    point of them is to be read side by side and shared.
    """
    destination = args.db or Path("scans") / f"{_slug(args.path[0])}.db"
    transcript = args.out or destination.with_suffix(".txt")
    destination.parent.mkdir(parents=True, exist_ok=True)
    transcript.parent.mkdir(parents=True, exist_ok=True)

    start = time.monotonic()
    counts = analyze.run(
        roots=args.path, db_path=destination, jobs=args.jobs,
        force=args.force, limit=args.limit,
        progress=None if args.quiet else _progress_printer(start),
    )
    if not args.quiet:
        sys.stderr.write("\n")

    conn = db.connect(destination)
    try:
        sections = [
            f"SCAN  {', '.join(str(p) for p in args.path)}",
            f"      {counts['analysed']} analysed, {counts['skipped']} already "
            f"current, {counts['errors']} errors, in "
            f"{(time.monotonic() - start) / 60:.1f} min",
            "",
            report.loudness_report(conn),
            "",
            report.folders_report(conn),
            "",
            report.lowend_report(conn, reference=args.reference),
        ]
        if counts["errors"]:
            sections += ["", report.errors_report(conn)]
    finally:
        conn.close()

    text = "\n".join(sections)
    print(text)
    transcript.write_text(text + "\n")
    print(f"\nDatabase: {destination}")
    print(f"Reports:  {transcript}")
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    conn = db.connect(args.db)
    try:
        if args.kind == "loudness":
            print(report.loudness_report(conn))
        elif args.kind == "lowend":
            print(report.lowend_report(conn, reference=args.reference))
        elif args.kind == "folders":
            print(report.folders_report(conn))
        elif args.kind == "tracks":
            print(report.tracks_report(conn, estimator=args.estimator,
                                       target=args.target, limit=args.limit))
        else:
            print(report.errors_report(conn))
    finally:
        conn.close()
    return 0


def cmd_export(args: argparse.Namespace) -> int:
    query = {
        "tracks": ("SELECT t.path, t.artist, t.title, t.album, t.year, t.genre, "
                   "t.bpm, t.musical_key, t.codec, t.source_channels, "
                   "t.bitrate_kbps, t.duration_s, l.* "
                   "FROM tracks t LEFT JOIN loudness l ON l.track_id = t.id "
                   "WHERE t.status = 'ok' ORDER BY t.path"),
        "bands": ("SELECT t.path, t.year, b.band_hz, b.ltas_db, b.shape_db, "
                  "b.p10_db, b.p90_db, b.side_mid_db "
                  "FROM bands b JOIN tracks t ON t.id = b.track_id "
                  "ORDER BY t.path, b.band_hz"),
    }[args.what]
    conn = db.connect(args.db)
    try:
        rows = conn.execute(query).fetchall()
        if not rows:
            print("nothing to export", file=sys.stderr)
            return 1
        with open(args.out, "w", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(rows[0].keys())
            writer.writerows(tuple(row) for row in rows)
        print(f"wrote {len(rows)} rows to {args.out}")
    finally:
        conn.close()
    return 0


def cmd_doctor(args: argparse.Namespace) -> int:
    """Check the environment, and optionally a library path, before a long run.

    Printing this is the fastest way to diagnose a machine I cannot see.
    """
    print(f"loudness-lab {__version__}")
    print()
    print("Environment")
    print(f"  python           {sys.version.split()[0]}  ({sys.executable})")
    in_venv = sys.prefix != sys.base_prefix
    print(f"  virtualenv       {'yes' if in_venv else 'no (using system python)'}")
    for module in ("numpy", "scipy"):
        try:
            print(f"  {module:<16} {__import__(module).__version__}")
        except ImportError:
            print(f"  {module:<16} MISSING -- run ./setup.sh")
    for tool in ("ffmpeg", "ffprobe"):
        path = shutil.which(tool)
        if path is None:
            print(f"  {tool:<16} MISSING -- brew install ffmpeg")
            continue
        version = subprocess.run([tool, "-version"], capture_output=True,
                                 text=True).stdout.split()[2]
        print(f"  {tool:<16} {version}  ({path})")
    print(f"  cpus             {os.cpu_count()}  "
          f"(default --jobs {analyze.default_jobs()})")

    if not args.path:
        print()
        print("Pass one or more folders to check them too:")
        print('  ./loudness-lab doctor "/Volumes/Card/Dance Music/Dance"')
        return 0

    worst = 0
    for index, path in enumerate(args.path):
        print()
        worst = max(worst, _doctor_library(path, first=(index == 0)))
    if len(args.path) > 1:
        print()
        print(f"To analyse all {len(args.path)} folders into one database:")
        quoted = " ".join(f'"{p}"' for p in args.path)
        print(f"  ./loudness-lab analyze {quoted} --db library.db")
    return worst


def _doctor_library(path: Path, first: bool = True) -> int:
    """Check one folder. Returns non-zero if it is unusable."""
    print(f"Library  {path}")
    if not path.exists():
        print("  NOT FOUND. If the path has spaces it needs quoting, and if "
              "it is an external\n  volume, check it is still mounted.")
        return 1
    if not os.access(path, os.R_OK):
        print("  EXISTS BUT IS NOT READABLE by this user.")
        return 1

    found = decode.survey(path)
    files = found["audio"]

    if found["single_file"]:
        print("  this is a single FILE, not a folder. Pass the folder that")
        print("  contains your music to analyse all of it.")
    if found["errors"]:
        print(f"  {len(found['errors'])} folder(s) could not be read:")
        for problem in found["errors"][:5]:
            print(f"    {problem}")
        print("  macOS may be withholding access: System Settings > Privacy &")
        print("  Security > Files and Folders (or Full Disk Access) for your")
        print("  terminal app.")

    if not files:
        print("  no audio files found under this path")
        if found["skipped"]:
            print("  but these other file types are present:")
            for suffix, count in sorted(found["skipped"].items(),
                                        key=lambda kv: -kv[1])[:10]:
                print(f"    {suffix:<8} {count}")
        print(f"  recognised audio types: {', '.join(sorted(decode.AUDIO_SUFFIXES))}")
        return 1

    counts, total = {}, 0
    for audio in files:
        counts[audio.suffix.lower()] = counts.get(audio.suffix.lower(), 0) + 1
        try:
            total += audio.stat().st_size
        except OSError:
            pass
    where = f" across {found['folders']} folders" if found["folders"] > 1 else ""
    print(f"  {len(files)} audio files{where}, {total / 1e9:.2f} GB")
    for suffix, count in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"    {suffix:<8} {count}")
    if found["skipped"]:
        ignored = sorted(found["skipped"].items(), key=lambda kv: -kv[1])[:6]
        print("  ignored (not recognised as audio): "
              + ", ".join(f"{suffix} x{count}" for suffix, count in ignored))

    # Only decode a probe file for the first folder; the point is to prove the
    # codec path works and estimate throughput, not to repeat it per folder.
    if not first:
        return 0

    print("  decoding ONE file as a check -- doctor does not analyse anything")
    probe_file = files[0]
    try:
        meta = decode.probe(probe_file)
        started = time.monotonic()
        samples = decode.decode(probe_file)
        elapsed = time.monotonic() - started
    except Exception as exc:
        print(f"    {probe_file.name}: FAILED: {exc}")
        return 1
    seconds = samples.shape[0] / decode.TARGET_RATE
    print(f"    {probe_file.name}")
    print(f"    ok: {meta['codec']}, {meta['source_channels']}ch, "
          f"{meta['source_rate']} Hz, {seconds / 60:.1f} min")
    if elapsed > 0:
        speed = seconds / elapsed
        minutes = len(files) * (seconds / speed) / analyze.default_jobs() / 60
        estimate = ("under a minute" if minutes < 1
                    else f"{minutes:.0f} min" if minutes < 90
                    else f"{minutes / 60:.1f} h")
        print(f"    decoded at {speed:.0f}x realtime; this folder is roughly "
              f"{estimate}")
        if speed < 20:
            print("    that is slow for a decode -- if this sits on an SD card "
                  "or network\n    volume, copying it to the internal disk "
                  "first will be much faster")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="loudness-lab",
        description="Measure a music library's loudness and low-end. Read-only: "
                    "this tool never writes to an audio file.")
    parser.add_argument("--version", action="version", version=__version__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    run = subparsers.add_parser("analyze", help="analyse a folder into a database")
    run.add_argument("path", type=Path, nargs="+",
                     help="one or more files or folders to walk")
    run.add_argument("--db", type=Path, default=Path("library.db"))
    run.add_argument("--jobs", type=int, default=None,
                     help=f"worker processes (default: {analyze.default_jobs()} here)")
    run.add_argument("--force", action="store_true",
                     help="re-analyse files that are already current")
    run.add_argument("--limit", type=int, default=None,
                     help="stop after this many files, for a quick trial run")
    run.add_argument("--quiet", action="store_true")
    run.set_defaults(func=cmd_analyze)

    show = subparsers.add_parser("report", help="print a report")
    show.add_argument("kind",
                      choices=("loudness", "lowend", "folders", "tracks", "errors"))
    show.add_argument("--db", type=Path, default=Path("library.db"))
    show.add_argument("--estimator", default="s_p95", choices=report.ESTIMATORS,
                      help="tracks: which loudness statistic to normalise on")
    show.add_argument("--target", type=float, default=-14.0,
                      help="tracks: target level in LUFS")
    show.add_argument("--limit", type=int, default=40, help="tracks: rows to print")
    show.add_argument("--reference", default=report.REFERENCE_ERA,
                      help="lowend: era to use as the reference curve")
    show.set_defaults(func=cmd_report)

    scan = subparsers.add_parser(
        "scan", help="analyse a folder and print every report in one command")
    scan.add_argument("path", type=Path, nargs="+",
                      help="one or more files or folders to walk")
    scan.add_argument("--db", type=Path, default=None,
                      help="default: scans/<folder-name>.db")
    scan.add_argument("--out", type=Path, default=None,
                      help="where to save the reports (default: alongside the db)")
    scan.add_argument("--jobs", type=int, default=None)
    scan.add_argument("--force", action="store_true")
    scan.add_argument("--limit", type=int, default=None)
    scan.add_argument("--reference", default=report.REFERENCE_ERA)
    scan.add_argument("--quiet", action="store_true")
    scan.set_defaults(func=cmd_scan)

    gain = subparsers.add_parser(
        "gain", help="apply lossless gain by rewriting global_gain (mp3 only)")
    gain.add_argument("path", type=Path, nargs="*",
                      help="files or folders that have already been analysed")
    gain.add_argument("--db", type=Path, default=None,
                      help="default: scans/<folder-name>.db")
    gain.add_argument("--no-analyze", action="store_true",
                      help="fail on unmeasured files instead of measuring them")
    gain.add_argument("--jobs", type=int, default=None)
    gain.add_argument("--quiet", action="store_true")
    gain.add_argument("--estimator", default="s_p95", choices=report.ESTIMATORS)
    gain.add_argument("--target", type=float, default=-12.0)
    gain.add_argument("--peak-ceiling", type=float, default=-1.0,
                      help="never let true peak exceed this, in dBTP "
                           "(default: -1.0)")
    gain.add_argument("--out", type=Path, default=None,
                      help="write modified copies here (default: gained/)")
    gain.add_argument("--in-place", action="store_true",
                      help="rewrite the originals instead; reversible with --undo")
    gain.add_argument("--apply", action="store_true",
                      help="actually write; without it this is a dry run")
    gain.add_argument("--yes", action="store_true",
                      help="confirm --apply --in-place")
    gain.add_argument("--undo", action="store_true",
                      help="reverse in-place changes recorded in the database")
    gain.add_argument("--limit", type=int, default=40)
    gain.set_defaults(func=cmd_gain)

    check = subparsers.add_parser(
        "doctor", help="check the environment and a library path")
    check.add_argument("path", type=Path, nargs="*",
                       help="optional folders to check for readable audio")
    check.set_defaults(func=cmd_doctor)

    dump = subparsers.add_parser("export", help="dump results to CSV")
    dump.add_argument("--db", type=Path, default=Path("library.db"))
    dump.add_argument("--out", type=Path, required=True)
    dump.add_argument("--what", choices=("tracks", "bands"), default="tracks")
    dump.set_defaults(func=cmd_export)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except BrokenPipeError:
        # `| head` closing the pipe is normal, not an error. Redirect stdout
        # to devnull so Python's interpreter shutdown does not complain too.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        return 0
    except KeyboardInterrupt:
        sys.stderr.write("\ninterrupted; results so far are saved\n")
        return 130
    except Exception as exc:
        sys.stderr.write(f"error: {exc}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
