"""Command line entry point."""

from __future__ import annotations

import argparse
import csv
import json
import os

import numpy as np
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from . import (__version__, analyze, apply_gain, bs1770, db, declip, decode,
               air, expand, mp3gain, profiles, render, report, subbass,
               write)


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


def _progress_json(phase: str = "measure"):
    """One JSON object per line on stdout, for a caller that is not a person.

    The human printer writes to stderr with carriage returns, which is right
    for a terminal and useless to anything trying to drive a progress bar.
    This is the same information, parseable: a UI reads a line, updates, and
    never has to guess at a rewritten line or a partial write.
    """
    def show(done: int, total: int, result: dict) -> None:
        track = result["track"]
        sys.stdout.write(json.dumps({
            "event": "progress",
            "phase": phase,
            "done": done,
            "total": total,
            "name": Path(track["path"]).name,
            "path": track["path"],
            "status": track["status"],
            "error": track.get("error"),
        }) + "\n")
        sys.stdout.flush()
    return show


def cmd_analyze(args: argparse.Namespace) -> int:
    start = time.monotonic()
    porcelain = getattr(args, "porcelain", False)
    if porcelain:
        reporter = _progress_json()
    elif args.quiet:
        reporter = None
    else:
        reporter = _progress_printer(start)

    counts = analyze.run(
        roots=args.path, db_path=args.db, jobs=args.jobs,
        force=args.force, limit=args.limit, progress=reporter,
    )
    if porcelain:
        sys.stdout.write(json.dumps({
            "event": "done",
            "seconds": round(time.monotonic() - start, 3),
            **counts,
        }) + "\n")
        sys.stdout.flush()
        return 0
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


def _reference_curve(conn, wanted: str,
                     bands=report.LOW_SHAPE_BANDS) -> tuple[str | None, dict]:
    """Median shape of the folder named by `wanted`, over `bands`.

    Low bands for the sub stage, top bands for air -- same query, same
    resolution of which folder "the reference" names, different slice of
    the spectrum.
    """
    matrix_bands, shape = report._band_matrix(conn, "shape_db", group_by="folder")
    name = report.resolve_reference(shape, wanted)
    if name is None:
        return None, {}
    curve = {b: float(np.median(shape[name][b]))
             for b in bands if shape[name].get(b)}
    return name, curve


def _auto_amount(conn, path: str, curve: dict, cap: float,
                 bands=report.LOW_SHAPE_BANDS) -> tuple[float, str | None]:
    """How much this track is short of the reference over `bands`, and
    whether it can take it."""
    rows = conn.execute(
        "SELECT b.band_hz, b.shape_db FROM bands b "
        "JOIN tracks t ON t.id = b.track_id WHERE t.path = ? "
        f"AND b.band_hz IN ({', '.join(str(b) for b in bands)})",
        (path,)).fetchall()
    deficits = []
    for row in rows:
        target = curve.get(row["band_hz"])
        if target is None or row["shape_db"] is None:
            continue
        deficits.append(target - row["shape_db"])
    if not deficits:
        return 0.0, "no band data"
    shortfall = float(np.mean(deficits))
    if shortfall <= 0.5:
        return 0.0, f"already within {shortfall:.1f} dB of the reference"
    return min(shortfall, cap), None


def _level_to_target(audio, args, measured: dict):
    """Bring the finished audio to the profile's level. Returns the audio,
    the gain applied, and the resulting true peak.

    Scaling a float buffer is exact, so nothing is lost doing this here
    rather than in a separate pass -- and a separate pass is not available
    anyway, since the lossless gain writer works only on MP3.
    """
    value = measured.get(args.estimator)
    if value is None:
        return audio, 0.0, measured.get("true_peak_dbtp", float("nan"))
    wanted = args.target - value
    peak = measured.get("true_peak_dbtp")
    if peak is not None and peak + wanted > args.peak_ceiling:
        wanted = args.peak_ceiling - peak
    levelled = (audio * (10 ** (wanted / 20))).astype(audio.dtype)
    return levelled, wanted, bs1770.measure(levelled)["true_peak_dbtp"]


def _variant(kind: str, path: Path, label: str, audio) -> dict:
    """One playable rendering of a track, with what the player needs to line
    it up against the others and monitor it fairly."""
    measured = bs1770.measure(audio)
    return {
        "kind": kind, "label": label, "path": str(path),
        "seconds": round(audio.shape[0] / decode.TARGET_RATE, 4),
        "lufs_i": measured["lufs_i"], "s_p95": measured["s_p95"],
        "true_peak_dbtp": measured["true_peak_dbtp"],
    }


def _write_manifest(path: Path, args: argparse.Namespace,
                    tracks: list) -> None:
    """A record of the run that a player can read.

    Every variant of a track is written from the SAME decode at the same
    rate, so they are sample-aligned with each other by construction and a
    player can switch between them mid-bar without seeking. That property is
    the reason this file exists; a player given an original MP3 and a
    processed FLAC would have to find the encoder delay itself.
    """
    payload = {
        "version": 1,
        "rate": decode.TARGET_RATE,
        "aligned": True,
        "settings": {key: getattr(args, key) for key in profiles.FIELDS
                     if key != "description" and hasattr(args, key)},
        "profile": args.profile,
        "tracks": tracks,
    }
    path.write_text(json.dumps(payload, indent=2, default=str))


def _policy_preview(outcomes: list) -> str:
    """What the policy does across the library, folder by folder.

    Per-track rows say what happens to a track. This says what happens to a
    library, which is what makes a policy something you can agree to in
    advance rather than audit afterwards.
    """
    if not outcomes:
        return "  Nothing to summarise."
    grouped: dict = {}
    for folder, amount, reason in outcomes:
        bucket = grouped.setdefault(folder, {"sub": [], "none": 0, "gated": 0})
        if amount is not None and amount > 0:
            bucket["sub"].append(amount)
        elif reason and "barely moves" in reason:
            bucket["gated"] += 1
        else:
            bucket["none"] += 1

    width = max(10, min(38, max(len(f) for f in grouped)))
    lines = ["POLICY PREVIEW  (what the sub does, folder by folder)",
             "-" * 78,
             f"  {'folder'.ljust(width)}{'n':>5}{'level only':>12}{'sub':>6}"
             f"{'gated':>7}{'median':>8}{'max':>7}"]
    for folder in sorted(grouped):
        bucket = grouped[folder]
        subs = bucket["sub"]
        total = len(subs) + bucket["none"] + bucket["gated"]
        median = f"{float(np.median(subs)):+.1f}" if subs else "-"
        largest = f"{max(subs):+.1f}" if subs else "-"
        lines.append(f"  {folder[-width:]:<{width}}{total:>5}{bucket['none']:>12}"
                     f"{len(subs):>6}{bucket['gated']:>7}{median:>8}{largest:>7}")
    lines += ["",
              "  'level only' is a track already at the reference, so it needs no",
              "  sub -- it may still have had range, attack or air work, which",
              "  is the table above. 'gated' is one whose sub octave holds a floor",
              "  rather",
              "  than a bassline. Neither is a failure; both are the policy",
              "  declining to act, which is most of what a good policy does."]
    return "\n".join(lines)


def _label(args: argparse.Namespace, amount: float | None = None) -> str:
    parts = []
    if getattr(args, "declip", None):
        parts.append("declipped")
    amount = args.amount if amount is None else amount
    if amount > 0:
        parts.append(f"sub{amount:+.1f}dB")
    if args.punch > 0:
        parts.append(f"punch{args.punch:+.0f}dB")
    return " ".join(parts) or "unchanged"


def _settings(args: argparse.Namespace) -> dict | None:
    """Merge profile and flags, or print the reason it cannot be done."""
    try:
        available = profiles.load(args.profiles)
        settings = profiles.resolve(available, args.profile)
    except profiles.ProfileError as exc:
        sys.stderr.write(f"error: {exc}\n")
        return None
    for key in profiles.FIELDS:
        if key == "description":
            continue
        if hasattr(args, key):
            setattr(args, key, profiles.setting(getattr(args, key), settings, key))
    return settings


def cmd_profiles(args: argparse.Namespace) -> int:
    try:
        print(profiles.describe(profiles.load(args.profiles)))
    except profiles.ProfileError as exc:
        sys.stderr.write(f"error: {exc}\n")
        return 1
    return 0


def _emit(payload: dict) -> None:
    """One JSON object on stdout, flushed, for a caller that is not a person."""
    sys.stdout.write(json.dumps(payload, default=str) + "\n")
    sys.stdout.flush()


def _identity(artist: str | None, title: str | None, path: str) -> str:
    """What makes two rows the same record.

    Artist and title, with case, punctuation and spacing thrown away,
    because "Earth, Wind & Fire - Let's Groove" and "Earth Wind and Fire -
    Lets Groove" are the same song off two compilations. An untagged file
    falls back to its own path, which is unique -- so a track with no tags
    is never mistaken for another track with no tags.
    """
    if not (artist or title):
        return path
    joined = f"{artist or ''}\x1f{title or ''}".lower()
    return "".join(c for c in joined if c.isalnum() or c == "\x1f")


def _pair(before: float | None, after: float | None) -> str:
    """"6.2>9.0" in seven characters, or the one figure there is.

    Two numbers in one column because the pair is the point: a range or a
    crest that did not move says the stage declined, and a column showing
    only the result cannot tell that from one that never needed to act.
    """
    if before is None:
        return "-"
    if after is None:
        return f"{before:.1f}"
    return f"{before:.1f}>{after:.1f}"


def _unique_stem(stem: str, folder: str, taken: set[str]) -> str:
    """A name no other track in this batch will write to.

    Everything lands in one output folder, and a library of compilations is
    full of files called "01 Track". Two of those would have written to the
    same path, one over the other, and the run would have reported both as
    written -- a silent loss of exactly the kind this project exists to
    avoid. The folder they came from is the natural way to tell them apart,
    and a counter after that, because two folders can share a label too.
    """
    candidate = stem
    if candidate.lower() in taken and folder:
        candidate = f"{stem} ({Path(folder).name or folder})"
    suffix = 2
    while candidate.lower() in taken:
        candidate = f"{stem} ({suffix})"
        suffix += 1
    taken.add(candidate.lower())
    return candidate


def cmd_subbass(args: argparse.Namespace) -> int:
    """PROTOTYPE: kick-synchronised sub-bass, for listening to.

    Lossy and irreversible, unlike everything else here, so it writes into
    a separate folder and picks the tracks that measure thinnest rather
    than processing everything.
    """
    porcelain = getattr(args, "porcelain", False)

    def out(line: str = "") -> None:
        """Human output, silenced under --porcelain.

        Nothing but JSON may reach stdout there: one unparseable line and
        the caller driving the progress bar is finished.
        """
        if not porcelain:
            print(line)

    def fail(message: str, code: int = 2) -> int:
        if porcelain:
            _emit({"event": "error", "message": message})
        else:
            print(message)
        return code

    if _settings(args) is None:
        return 2
    if (not args.auto and args.amount <= 0 and args.punch <= 0
            and not args.declip and args.target_lra <= 0
            and args.transient <= 0 and args.air <= 0):
        # level-only is a gain policy. Running this command under it would
        # decode every track, change nothing, and write pairs of identical
        # files -- worse than useless, because it looks like work happened.
        return fail(
            "This profile changes nothing (sub, punch, declip, range, "
            "attack and air are all off).\nNothing to do -- levelling is the "
            "gain command:\n  ./loudness-lab gain <path> --profile "
            f"{args.profile or 'level-only'}", 0)
    if args.auto and not args.reference:
        return fail("error: --auto needs a reference corpus. Give --reference, "
                    "or set it in the profile.")
    if args.format not in write.FORMATS:
        # argparse already restricts this. The guard is for a caller that
        # built the namespace itself: without it the first worker raises,
        # and the run reports a per-track failure on every track instead of
        # one sentence about the setting.
        return fail(f"error: unknown format {args.format!r}; one of "
                    f"{', '.join(write.FORMATS)}")
    database = args.db or (Path("scans") / f"{_slug(args.path[0])}.db")
    database.parent.mkdir(parents=True, exist_ok=True)
    out_dir = args.out or Path("subbass-preview")

    # The app's ticked list: paths, one per line. A file rather than a flag
    # per track because a batch is hundreds of them, and a file is also
    # what a caller already has.
    selected: list[str] | None = None
    if args.select:
        try:
            selected = [line for line in args.select.read_text().splitlines()
                        if line.strip()]
        except OSError as exc:
            return fail(f"error: could not read --select {args.select}: {exc}")
        if not selected:
            return fail(f"error: --select {args.select} lists no tracks.")

    start = time.monotonic()
    if porcelain:
        reporter = _progress_json("measure")
    elif args.quiet:
        reporter = None
    else:
        reporter = _progress_printer(start)
    counts = analyze.run(roots=args.path, db_path=database, jobs=args.jobs,
                         progress=reporter)
    if porcelain:
        _emit({"event": "measured",
               "seconds": round(time.monotonic() - start, 3), **counts})
    elif not args.quiet:
        sys.stderr.write("\n")

    conn = db.connect(database)
    try:
        bands = ", ".join(str(b) for b in report.LOW_SHAPE_BANDS)
        # Restrict to the folders actually named. The database is shared --
        # the reference corpus has to live in it too -- so without this the
        # selection ranged over every track it held and happily processed
        # records from albums the command never mentioned.
        scope, params = [], []
        for root in args.path:
            base = str(root).rstrip(os.sep)
            scope.append("(t.path = ? OR t.path LIKE ?)")
            params += [base, base + os.sep + "%"]
        clause = " AND (" + " OR ".join(scope) + ")" if scope else ""
        if args.match:
            tests = []
            for pattern in args.match:
                like = f"%{pattern.lower()}%"
                tests.append("(LOWER(COALESCE(t.artist, '')) LIKE ? "
                             "OR LOWER(COALESCE(t.title, '')) LIKE ? "
                             "OR LOWER(t.path) LIKE ?)")
                params += [like, like, like]
            clause += " AND (" + " OR ".join(tests) + ")"
        if selected is not None:
            # A temporary table rather than an IN list: a batch can be
            # thousands of tracks and SQLite has a cap on bound variables
            # that a long enough list walks straight into.
            conn.execute("CREATE TEMP TABLE chosen (path TEXT PRIMARY KEY)")
            conn.executemany("INSERT OR IGNORE INTO chosen VALUES (?)",
                             [(p,) for p in selected])
            clause += " AND t.path IN (SELECT path FROM chosen)"
        rows = conn.execute(
            f"SELECT t.path, t.artist, t.title, AVG(b.shape_db) AS low "
            f"FROM tracks t JOIN bands b ON b.track_id = t.id "
            f"WHERE t.status = 'ok' AND b.band_hz IN ({bands}) "
            f"AND b.shape_db IS NOT NULL{clause} "
            f"GROUP BY t.id ORDER BY low ASC LIMIT ?", (*params, args.limit)
        ).fetchall()
        in_scope = conn.execute(
            "SELECT COUNT(*) FROM tracks t WHERE t.status = 'ok'"
            + (" AND (" + " OR ".join(scope) + ")" if scope else ""),
            [v for root in args.path
             for v in (str(root).rstrip(os.sep),
                       str(root).rstrip(os.sep) + os.sep + "%")]).fetchone()[0]
        analysed = in_scope
        reference_name, curve = (None, {})
        top_curve = {}
        if args.auto:
            reference_name, curve = _reference_curve(conn, args.reference or "")
            if reference_name is None:
                return fail(
                    f"--auto needs a reference folder; {args.reference!r} "
                    f"matched none (or matched several).\nName one of the "
                    f"folders that report lowend --by folder lists.")
            if args.air > 0:
                # Same idea as the sub's shortfall, over the band air is
                # measured in: --air becomes the ceiling per track gets
                # sized up to, rather than a flat amount every track gets
                # regardless of how much brighter the reference already is.
                _, top_curve = _reference_curve(conn, args.reference or "",
                                                bands=report.TOP_SHAPE_BANDS)
        amounts = {}
        air_amounts = {}
        if args.auto:
            for row in rows:
                amounts[row["path"]] = _auto_amount(conn, row["path"], curve,
                                                    args.max_amount)
                if args.air > 0 and top_curve:
                    air_amounts[row["path"]] = _auto_amount(
                        conn, row["path"], top_curve, args.air,
                        bands=report.TOP_SHAPE_BANDS)
    finally:
        conn.close()
    if not rows:
        if args.match:
            return fail(
                f"no track matched {', '.join(repr(m) for m in args.match)} "
                f"among {analysed} analysed.\nMatching is a case-insensitive "
                f"substring of the artist, title or path.", 1)
        return fail("nothing analysed to work from", 1)

    labels = report._folder_labels([r["path"] for r in rows])
    jobs, duplicates = [], 0
    seen: set[str] = set()
    taken: set[str] = set()
    for row in rows:
        # The same record twice in one batch is one decode, one encode and
        # one lossy generation wasted -- and two files in the output that
        # differ only by which compilation they came off. A library of
        # disco compilations is mostly the same forty songs, so this is the
        # normal case rather than an odd one.
        if args.skip_duplicates:
            key = _identity(row["artist"], row["title"], row["path"])
            if key in seen:
                duplicates += 1
                continue
            seen.add(key)
        amount, skip = amounts.get(row["path"], (args.amount, None))
        air_amount, _ = air_amounts.get(row["path"], (args.air, None))
        # `skip` short-circuits the whole track in render.one() -- right,
        # back when the sub was the only thing --auto could size, wrong
        # now that air is a second one. A track can easily be fine on bass
        # and still short on top end; skipping it there would silently
        # skip air too, on tracks air auto-sizing exists to help.
        if air_amount > 0:
            skip = None
        name = " - ".join(p for p in (row["artist"], row["title"]) if p) \
            or Path(row["path"]).stem
        jobs.append({
            "path": row["path"], "name": name,
            "stem": _unique_stem(Path(row["path"]).stem,
                                 labels.get(row["path"], ""), taken),
            "folder": labels.get(row["path"], "(root)"),
            "amount": amount, "skip": skip, "label": _label(args, amount),
            "freq": args.freq, "decay": args.decay,
            "punch": args.punch, "punch_decay": args.punch_decay,
            "declip": bool(args.declip), "declip_max": args.declip_max,
            "min_activity": args.min_activity,
            "target_lra": args.target_lra,
            "max_attenuation": args.max_attenuation,
            "transient": args.transient, "min_crest": args.min_crest,
            "air": air_amount, "air_tune": args.air_tune,
            "target": args.target, "estimator": args.estimator,
            "peak_ceiling": args.peak_ceiling,
            "compare": not args.no_compare, "dry_run": bool(args.dry_run),
            "out_dir": str(out_dir), "fmt": args.format,
        })
    if not jobs:
        return fail("every selected track was a duplicate of another in the "
                    "same batch", 1)

    if porcelain:
        _emit({"event": "selected", "total": len(jobs), "analysed": analysed,
               "duplicates": duplicates, "reference": reference_name,
               "format": write.label(args.format), "out": str(out_dir)})
    out(f"{len(rows)} of {analysed} track(s) under the given path(s) selected"
        + (" by --match" if args.match else ""))
    if duplicates:
        out(f"  {duplicates} duplicate(s) skipped -- same artist and title "
            f"already in this batch.")
    if args.auto:
        out(f"reference: {reference_name}")
    if not args.dry_run:
        out_dir.mkdir(parents=True, exist_ok=True)
    if args.profile:
        out(f"profile: {args.profile}")
    heading = ("sub=auto (per track)" if args.auto
               else f"sub={args.amount:+.1f} dB")
    air_heading = (f"air<=+{args.air:.0f} dB (per track)" if args.auto
                  else f"air+{args.air:.0f} dB")
    out(f"KICK PROTOTYPE  {heading} in "
        f"{subbass.SUB_LOW_HZ:.0f}-{subbass.SUB_HIGH_HZ:.0f} Hz  "
        f"punch={args.punch:+.1f} dB in "
        f"{subbass.PUNCH_LOW_HZ / 1000:.0f}-{subbass.PUNCH_HIGH_HZ / 1000:.0f} kHz"
        + (f"  declip<={args.declip_max:.0f} dB" if args.declip else "")
        + (f"  range->{args.target_lra:.0f} LU" if args.target_lra > 0 else "")
        + (f"  attack+{args.transient:.0f} dB" if args.transient > 0 else "")
        + (f"  {air_heading} from {args.air_tune / 1000:.1f}k"
           if args.air > 0 else ""))
    out("=" * 104)
    out("  Lossy and irreversible, unlike the gain pass. Originals are never")
    out(f"  touched; these are new {write.label(args.format)} files to "
        f"listen to and compare.")
    out()
    if not args.summary_only:
        out("  'shape' is the mean 1/3-octave level relative to the track's own")
        out("  broadband, in the same units as report lowend, so it can be read")
        out("  against the correction curve. 'added' is the energy put into the")
        out("  octave; the two differ because one is a mean of decibels and the")
        out("  other a sum of energies.")
    if not args.summary_only and args.declip:
        out()
        out("  'clips' is how many runs of clipped samples were arced back over,")
        out("  and 'lift' the median height those restored peaks gained -- over the")
        out("  runs, not over the file's own peak, which on an MP3 of a clipped")
        out("  master is set by codec overshoot and hardly moves. The lift is not a")
        out("  volume increase: it is headroom the levelling takes straight back")
        out("  out. De-clipping runs FIRST, on the file as it arrived.")
    workers = args.jobs or render.default_jobs()
    if workers > 1:
        # Before the table, not after: this used to go to stderr as the
        # work started, which on a terminal put it between the column
        # headings and the first row.
        out(f"  {workers} tracks at a time.")
    if not args.summary_only:
        out()
        out(f"  {'artist / title':<40s}{'kicks/min':>10s}{'shape was':>11s}"
            f"{'now':>8s}{'added':>8s}{'trim':>7s}{'dBTP':>7s}"
            f"{'match':>8s}{'snap':>7s}"
            + (f"{'clips':>7s}{'lift':>7s}" if args.declip else "")
            + (f"{'LRA':>10s}" if args.target_lra > 0 else "")
            + (f"{'crest':>10s}" if args.transient > 0 else "")
            + (f"{'air':>7s}" if args.air > 0 else ""))

    blank = (f"{'':>10}{'':>11}{'':>8}{'':>8}{'':>7}{'':>7}{'':>8}{'':>7}"
             + (f"{'':>7}{'':>7}" if args.declip else "")
             + (f"{'':>10}" if args.target_lra > 0 else "")
             + (f"{'':>10}" if args.transient > 0 else "")
             + (f"{'':>7}" if args.air > 0 else ""))

    def report_one(done: int, total: int, result: dict) -> None:
        if porcelain:
            _emit({"event": "progress", "phase": "process",
                   "done": done, "total": total,
                   "name": result["name"], "path": result["path"],
                   "status": result["status"],
                   "reason": result.get("reason"),
                   "sub_db": result.get("applied_db"),
                   "clips_restored": (result.get("clip") or {}).get("restored"),
                   "lra_before": (result.get("range") or {}).get("lra_before"),
                   "lra_after": (result.get("range") or {}).get("lra_after"),
                   "crest_before": (result.get("transient") or {}).get("crest_before"),
                   "crest_after": (result.get("transient") or {}).get("crest_after"),
                   "air_db": (result.get("air") or {}).get("measured_db")})
            return
        if result["status"] == "error":
            print(f"  {result['name'][:39]:<40s}  FAILED: {result['reason']}")
        elif result["status"] == "skipped":
            print(f"  {result['name'][:39]:<40s}{blank}  {result['reason']}")
        elif not args.summary_only:
            note = "" if result["reason"] is None else f"  {result['reason']}"
            clip = result.get("clip") or {"restored": 0, "lift_db": 0.0}
            ranged = result.get("range") or {}
            shaped = result.get("transient") or {}
            print(f"  {result['name'][:39]:<40s}"
                  f"{result['kicks_per_minute']:>10.0f}"
                  f"{result['shape_before']:>11.1f}{result['shape_after']:>8.1f}"
                  f"{result['applied_db']:>+8.2f}{result['safety_trim_db']:>+7.2f}"
                  f"{result['peak_dbtp']:>+7.2f}{result['match_db']:>+8.2f}"
                  f"{result['snap_db']:>+7.2f}"
                  + (f"{clip['restored']:>7d}{clip['lift_db']:>+7.2f}"
                     if args.declip else "")
                  + (f"{_pair(ranged.get('lra_before'), ranged.get('lra_after')):>10s}"
                     if args.target_lra > 0 else "")
                  + (f"{_pair(shaped.get('crest_before'), shaped.get('crest_after')):>10s}"
                     if args.transient > 0 else "")
                  + (f"{(result.get('air') or {}).get('measured_db', 0.0):>+7.2f}"
                     if args.air > 0 else "")
                  + note)

    results = render.run(jobs, workers=workers, progress=report_one)

    written = sum(1 for r in results if r["status"] == "ok")
    outcomes = [(r["folder"], r["amount"], r.get("reason") if r["status"] != "ok"
                 else None) for r in results]
    clips = [r["clip"] for r in results
             if r["status"] == "ok" and r.get("clip") is not None]
    ranges = [r["range"] for r in results
              if r.get("range") and r["status"] != "error"]
    shapes = [r["transient"] for r in results
              if r.get("transient") and r["status"] != "error"]
    airs = [r["air"] for r in results
            if r.get("air") and r["status"] != "error"]
    manifest = [r["manifest"] for r in results if r.get("manifest")]

    out()
    if args.declip:
        out(declip.summarise(clips))
        out()
    if args.target_lra > 0 or args.transient > 0:
        out(expand.summarise(ranges if args.target_lra > 0 else [],
                             shapes if args.transient > 0 else []))
        out()
    if args.air > 0:
        out(air.summarise(airs))
        out()
    out(_policy_preview(outcomes))
    out()
    manifest_path = None
    if args.dry_run:
        out(f"  DRY RUN -- nothing written. {written} track(s) would be "
            f"processed.")
        if porcelain:
            _emit({"event": "done", "dry_run": True, "written": 0,
                   "selected": len(jobs), "out": str(out_dir),
                   "errors": sum(1 for r in results if r["status"] == "error"),
                   "seconds": round(time.monotonic() - start, 3)})
        return 0
    if manifest:
        manifest_path = out_dir / "manifest.json"
        _write_manifest(manifest_path, args, manifest)
    if porcelain:
        _emit({"event": "done", "written": written, "selected": len(jobs),
               "skipped": sum(1 for r in results if r["status"] == "skipped"),
               "errors": sum(1 for r in results if r["status"] == "error"),
               "manifest": str(manifest_path) if manifest_path else None,
               "out": str(out_dir),
               "seconds": round(time.monotonic() - start, 3)})
        return 0
    kind = write.label(args.format)
    if args.no_compare:
        out(f"  {written} file(s) written to {out_dir}/ as {kind}, levelled to "
            f"{args.target:+.1f} on {args.estimator}.")
        out("  That levelling happens here because the gain command cannot "
            "do it:")
        out("  global_gain exists only in an MP3 bitstream.")
    else:
        out(f"  {written} pair(s) written to {out_dir}/ as {kind}: 'A original'")
        out("  and 'B sub', LEVEL-MATCHED so the comparison is about the bass")
        out("  and not about which is louder. 'match' is the dB both were")
        out("  brought down by to meet; neither was boosted, so neither clips.")
        out()
        out("  Knowing which is which biases you. Have someone else shuffle")
        out("  the names, or at least listen to B first on half of them.")
    out("  Listen against the originals before deciding this is worth a")
    out("  generation. Re-run the level pass afterwards: adding energy moves")
    out("  loudness, so whatever happens last has to be the levelling.")
    return 0



def cmd_gain(args: argparse.Namespace) -> int:
    """Lossless gain. Dry run unless --apply is given.

    Analyses anything not already measured, so pointing this at a folder is
    enough -- no separate scan step, and no database path to keep in step
    with it.
    """
    settings = _settings(args)
    if settings is None:
        return 2
    if settings.get("declip"):
        # A silent no-op is the failure mode this project keeps guarding
        # against: the profile says declip, the gain pass cannot, and without
        # this the library comes out levelled and still clipped.
        print("NOTE: this profile asks for de-clipping, which the gain pass "
              "cannot do.")
        print("  Lossless gain moves global_gain in the bitstream and never "
              "touches a sample,")
        print("  so a restored peak has nowhere to live. De-clipping needs a "
              "decode:")
        print(f"  ./loudness-lab subbass <path> --profile "
              f"{args.profile or 'the same profile'} --declip --no-compare")
        print("  Levelling below is unaffected and still correct.")
        print()
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

        unsupported = apply_gain.unsupported_audio(args.path)
        usable = [p for p in proposals if p.ok]
        blocked = [p for p in proposals if not p.ok]
        moving = [p for p in usable if p.plan.steps != 0]

        if args.profile:
            print(f"profile: {args.profile}")
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
        if unsupported:
            total = sum(unsupported.values())
            listed = ", ".join(f"{suffix} x{count}" for suffix, count
                               in sorted(unsupported.items(), key=lambda kv: -kv[1]))
            print()
            print(f"  {total} audio file(s) are NOT mp3 and will be left "
                  f"untouched: {listed}")
            print("  The global_gain trick only exists in the MPEG Layer III")
            print("  bitstream. Levelling everything else while leaving these")
            print("  alone makes the library systematically uneven, so handle")
            print("  them separately before you rely on the result.")
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
        else:
            print(f"Originals were rewritten. {database} is now the ONLY way")
            print("to undo this -- back it up before you need it.")
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
            report.lowend_report(conn, reference=args.reference,
                                 group_by="folder"),
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
            print(report.lowend_report(conn, reference=args.reference,
                                       group_by=args.by))
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
    run.add_argument("--porcelain", action="store_true",
                     help="one JSON object per line on stdout, for the Mac "
                          "app rather than for reading")
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
    show.add_argument("--by", choices=("era", "folder"), default="era",
                      help="lowend: group by year-derived era (default) or by "
                           "the folder each track sits in. Use folder when the "
                           "library is compilations, whose year tags are "
                           "reissue dates")
    show.add_argument("--reference", default=report.REFERENCE_ERA,
                      help="lowend: the era or folder the others are measured "
                           "against; folders match on a unique substring")
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

    sub = subparsers.add_parser(
        "subbass", help="PROTOTYPE: kick-synchronised sub-bass (lossy, writes FLAC)")
    sub.add_argument("path", type=Path, nargs="+")
    sub.add_argument("--profile", default=None,
                     help="a named settings bundle; see the profiles command")
    sub.add_argument("--profiles", type=Path, default=None,
                     help="where profiles live (default: ./profiles.json)")
    sub.add_argument("--db", type=Path, default=None)
    sub.add_argument("--out", type=Path, default=None,
                     help="where the FLACs go (default: subbass-preview/)")
    sub.add_argument("--amount", type=float, default=None,
                     help="dB to add in the 31.5-63 Hz octave")
    sub.add_argument("--target", type=float, default=None,
                     help="level the written file to this, on --estimator. "
                          "Only with --no-compare: a comparison pair is "
                          "matched to itself instead")
    sub.add_argument("--estimator", default=None, choices=report.ESTIMATORS)
    sub.add_argument("--peak-ceiling", type=float, default=None)
    sub.add_argument("--punch", type=float, default=None,
                     help="dB of attack emphasis on each kick, in "
                          "2-6 kHz (default: 0, off). Adds no energy: the band "
                          "is renormalised, so this redistributes rather than "
                          "boosts")
    sub.add_argument("--punch-decay", type=float, default=None,
                     help="ms the attack emphasis decays over (default: 8)")
    sub.add_argument("--freq", type=float, default=subbass.DEFAULT_FREQ_HZ)
    sub.add_argument("--decay", type=float, default=subbass.DEFAULT_DECAY_S)
    sub.add_argument("--auto", action="store_true", default=None,
                     help="set the sub amount -- and, if --air is on, the air "
                          "amount too -- per track from its own measured "
                          "shortfall against --reference, rather than using "
                          "one figure for everything")
    sub.add_argument("--reference", default=None, metavar="TEXT",
                     help="--auto: the folder whose low end is the target")
    sub.add_argument("--min-activity", type=float, default=None,
                     help="skip a track whose sub octave swings less than this "
                          f"many dB (default: {subbass.MIN_LOW_ACTIVITY_DB:.0f}). "
                          "Static rumble measures about 11, a real groove about "
                          "44; values in between are a judgement call")
    sub.add_argument("--max-amount", type=float, default=None,
                     help="--auto: cap on the per-track amount (default: 6)")
    sub.add_argument("--declip", action="store_true", default=None,
                     help="restore peaks that were clipped before the file "
                          "reached us, before anything else is done to it")
    sub.add_argument("--declip-max", type=float, default=None,
                     metavar="DB",
                     help="cap on how far --declip may lift one peak "
                          f"(default {profiles.FIELDS['declip_max']:.0f} dB)")
    sub.add_argument("--target-lra", type=float, default=None, metavar="LU",
                     help="widen the loudness range to this, by pulling the "
                          "quiet passages down (never by pushing the loud "
                          "ones up -- there is no headroom there). 0 is off. "
                          "A DJ caution: a track that drops 8 LU in the "
                          "breakdown disappears under the next record")
    sub.add_argument("--max-attenuation", type=float, default=None,
                     metavar="DB",
                     help="cap on how far --target-lra may pull a quiet "
                          f"passage down (default "
                          f"{profiles.FIELDS['max_attenuation']:.0f} dB)")
    sub.add_argument("--transient", type=float, default=None, metavar="DB",
                     help="dB of emphasis at each onset, for attacks a fast "
                          "limiter flattened. Acts only where the signal is "
                          "rising, so it cannot breathe the way an expander "
                          "does. 0 is off")
    sub.add_argument("--min-crest", type=float, default=None, metavar="DB",
                     help="--transient: skip a track whose peak-to-loudness "
                          "ratio already reaches this, because nothing "
                          f"flattened it (default "
                          f"{profiles.FIELDS['min_crest']:.0f} dB)")
    sub.add_argument("--air", type=float, default=None, metavar="DB",
                     help="dB of generated harmonics added to 8-20 kHz, for "
                          "a top end a shelf cannot help because a codec "
                          "emptied it. This one INVENTS -- the harmonics "
                          "were never in the recording. 0 is off. --auto: "
                          "this becomes the per-track cap, sized from the "
                          "track's own measured shortfall against "
                          "--reference in that same band, same as the sub")
    sub.add_argument("--air-tune", type=float, default=None, metavar="HZ",
                     help="--air: the frequency the harmonics are generated "
                          "from, upward (default "
                          f"{profiles.FIELDS['air_tune'] / 1000:.1f} kHz). "
                          "Lower is fuller and costs less peak; higher is "
                          "more sizzle and costs a great deal more")
    sub.add_argument("--summary-only", action="store_true",
                     help="print only the policy preview, not a row per track")
    sub.add_argument("--dry-run", action="store_true",
                     help="report what would be done and write nothing")
    sub.add_argument("--match", action="append", default=None, metavar="TEXT",
                     help="only tracks whose artist, title or path contains "
                          "TEXT (case-insensitive). Repeatable; any match "
                          "counts. Without it the thinnest tracks are chosen")
    sub.add_argument("--limit", type=int, default=10,
                     help="how many of the thinnest tracks to do (default: 10)")
    sub.add_argument("--no-compare", action="store_true",
                     help="write only the processed file, not a level-matched "
                          "A/B pair")
    sub.add_argument("--format", default=write.DEFAULT_FORMAT,
                     choices=sorted(write.FORMATS),
                     help="what to write: flac (lossless, the default), "
                          "mp3 (320 kbps, and the only one Serato's cue "
                          "points travel through) or aac (256 kbps in an "
                          "m4a). A and B of a pair always match, so the "
                          "comparison is never about the codec")
    sub.add_argument("--select", type=Path, default=None, metavar="FILE",
                     help="restrict to the paths listed in FILE, one per "
                          "line -- what the Mac app's ticked list sends. "
                          "Applied BEFORE --limit, so unticking a track "
                          "promotes the next one into range")
    sub.add_argument("--skip-duplicates", action="store_true",
                     help="do a record only once per batch, matching on "
                          "artist and title with case and punctuation "
                          "ignored. A library of compilations is mostly the "
                          "same songs twice")
    sub.add_argument("--jobs", type=int, default=None,
                     help=f"tracks at a time (default: {render.default_jobs()} "
                          "here). Each one holds several decoded copies in "
                          "memory, so this is bounded by RAM, not cores")
    sub.add_argument("--quiet", action="store_true")
    sub.add_argument("--porcelain", action="store_true",
                     help="one JSON object per line on stdout, for the Mac "
                          "app rather than for reading")
    sub.set_defaults(func=cmd_subbass)

    gain = subparsers.add_parser(
        "gain", help="apply lossless gain by rewriting global_gain (mp3 only)")
    gain.add_argument("path", type=Path, nargs="*",
                      help="files or folders that have already been analysed")
    gain.add_argument("--profile", default=None,
                     help="a named settings bundle; see the profiles command")
    gain.add_argument("--profiles", type=Path, default=None,
                     help="where profiles live (default: ./profiles.json)")
    gain.add_argument("--db", type=Path, default=None,
                      help="default: scans/<folder-name>.db")
    gain.add_argument("--no-analyze", action="store_true",
                      help="fail on unmeasured files instead of measuring them")
    gain.add_argument("--jobs", type=int, default=None)
    gain.add_argument("--quiet", action="store_true")
    gain.add_argument("--estimator", default=None, choices=report.ESTIMATORS)
    gain.add_argument("--target", type=float, default=None)
    gain.add_argument("--peak-ceiling", type=float, default=None,
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

    show_profiles = subparsers.add_parser(
        "profiles", help="list the available settings bundles")
    show_profiles.add_argument("--profiles", type=Path, default=None)
    show_profiles.set_defaults(func=cmd_profiles)

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
