"""Command line entry point."""

from __future__ import annotations

import argparse
import csv
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

from . import __version__, analyze, db, decode, report


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
        root=args.path, db_path=args.db, jobs=args.jobs,
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


def cmd_report(args: argparse.Namespace) -> int:
    conn = db.connect(args.db)
    try:
        if args.kind == "loudness":
            print(report.loudness_report(conn))
        elif args.kind == "lowend":
            print(report.lowend_report(conn, reference=args.reference))
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

    if args.path is None:
        print()
        print("Pass a folder to check it too:")
        print('  ./loudness-lab doctor "/Volumes/Card/DJ Music/Converted Wedding"')
        return 0

    print()
    print(f"Library  {args.path}")
    if not args.path.exists():
        print("  NOT FOUND. If the path has spaces it needs quoting, and if "
              "it is an external\n  volume, check it is still mounted.")
        return 1
    if not os.access(args.path, os.R_OK):
        print("  EXISTS BUT IS NOT READABLE by this user.")
        return 1

    found = decode.survey(args.path)
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
        print(f"  no audio files found under this path")
        if found["skipped"]:
            print("  but these other file types are present:")
            for suffix, count in sorted(found["skipped"].items(),
                                        key=lambda kv: -kv[1])[:10]:
                print(f"    {suffix:<8} {count}")
        print(f"  recognised audio types: {', '.join(sorted(decode.AUDIO_SUFFIXES))}")
        return 1

    counts, total = {}, 0
    for path in files:
        counts[path.suffix.lower()] = counts.get(path.suffix.lower(), 0) + 1
        try:
            total += path.stat().st_size
        except OSError:
            pass
    where = (f" across {found['folders']} folders" if found["folders"] > 1 else "")
    print(f"  {len(files)} audio files{where}, {total / 1e9:.2f} GB")
    for suffix, count in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"    {suffix:<8} {count}")
    if found["skipped"]:
        ignored = sorted(found["skipped"].items(), key=lambda kv: -kv[1])[:6]
        print("  ignored (not recognised as audio): "
              + ", ".join(f"{suffix} x{count}" for suffix, count in ignored))

    print()
    print("Decoding ONE file as a check -- doctor does not analyse anything.")
    first = files[0]
    print(f"  {first.name}")
    try:
        meta = decode.probe(first)
        started = time.monotonic()
        samples = decode.decode(first)
        elapsed = time.monotonic() - started
    except Exception as exc:
        print(f"  FAILED: {exc}")
        return 1
    seconds = samples.shape[0] / decode.TARGET_RATE
    print(f"  ok: {meta['codec']}, {meta['source_channels']}ch, "
          f"{meta['source_rate']} Hz, {seconds / 60:.1f} min")
    if elapsed > 0:
        speed = seconds / elapsed
        print(f"  decoded at {speed:.0f}x realtime")
        minutes = len(files) * (seconds / speed) / analyze.default_jobs() / 60
        estimate = ("under a minute" if minutes < 1
                    else f"{minutes:.0f} min" if minutes < 90
                    else f"{minutes / 60:.1f} h")
        print(f"  rough estimate for all {len(files)} files: {estimate} "
              f"at the default job count")
        if speed < 20:
            print("  that is slow for a decode -- if this folder sits on an "
                  "SD card or network\n  volume, copying it to the internal "
                  "disk first will be much faster")

    print()
    print(f"To actually analyse all {len(files)} files, run:")
    print(f'  ./loudness-lab analyze "{args.path}" --db library.db')
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="loudness-lab",
        description="Measure a music library's loudness and low-end. Read-only: "
                    "this tool never writes to an audio file.")
    parser.add_argument("--version", action="version", version=__version__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    run = subparsers.add_parser("analyze", help="analyse a folder into a database")
    run.add_argument("path", type=Path, help="file or folder to walk")
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
    show.add_argument("kind", choices=("loudness", "lowend", "tracks", "errors"))
    show.add_argument("--db", type=Path, default=Path("library.db"))
    show.add_argument("--estimator", default="s_p95", choices=report.ESTIMATORS,
                      help="tracks: which loudness statistic to normalise on")
    show.add_argument("--target", type=float, default=-14.0,
                      help="tracks: target level in LUFS")
    show.add_argument("--limit", type=int, default=40, help="tracks: rows to print")
    show.add_argument("--reference", default=report.REFERENCE_ERA,
                      help="lowend: era to use as the reference curve")
    show.set_defaults(func=cmd_report)

    check = subparsers.add_parser(
        "doctor", help="check the environment and a library path")
    check.add_argument("path", type=Path, nargs="?",
                       help="optional folder to check for readable audio")
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
