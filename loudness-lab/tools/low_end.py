#!/usr/bin/env python3
"""Two questions about the bottom end, answered from what the library
already measured -- nothing is processed.

1. Does the bass survive a club's mono sub? Club systems sum left and
   right below the crossover. Bass that differs between the channels
   partly cancels there, and bass largely OUT of step between them (a
   stereo-miked or phase-flipped low end) mostly vanishes. From each
   band's side/mid ratio below 125 Hz (`spectrum.side_mid_db`) this gives
   the dB of bass a mono sum loses against the same bass in the centre:

       lost = 10 log10(mid / (mid + side)),  summed over the bands

   0 dB is a mono bass; -3 dB is side as strong as mid.

2. How much mud? The 200-400 Hz bands (shape, relative to the track's
   own level) against a reference folder's: dB above the reference is
   build-up a dynamic cut could take out, sized per track like the sub.

    .venv/bin/python tools/low_end.py <folder> [--reference-folder PATH]
        [--db ~/Music/LoudnessLab/library.db]
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from loudnesslab import analyze, cli, db  # noqa: E402

MONO_BANDS = (31.5, 40.0, 50.0, 63.0, 80.0, 100.0, 125.0)
MUD_BANDS = (200.0, 250.0, 315.0, 400.0)
LOSES_DB = -1.0          # a mono sum losing more than this is worth a look
DATABASE = Path.home() / "Music" / "LoudnessLab" / "library.db"


def mono_loss(bands: dict) -> tuple[float | None, float | None]:
    """(dB a mono sum loses over MONO_BANDS, the side/mid ratio of their
    total in dB) from {band_hz: (ltas_db, side_mid_db, shape_db)}. The mid level
    weights each band, so a quiet band's stereo counts for little."""
    mid = side = 0.0
    for band in MONO_BANDS:
        ltas, ratio = bands.get(band, (None, None, None))[:2]
        if ltas is None:
            continue
        # No side/mid figure beside a level is a band with no side at all
        # -- identical channels, the log of zero stored as nothing -- so a
        # perfectly mono bass counts, as losing nothing, rather than being
        # left out (a database from before side/mid was stored reads the
        # same way, and so as mono).
        ratio = -99.0 if ratio is None else ratio
        m = 10 ** (ltas / 10)
        mid += m
        side += m * 10 ** (ratio / 10)
    if mid <= 0:
        return None, None
    return 10 * np.log10(mid / (mid + side)), 10 * np.log10(side / mid) if side > 0 else -99.0


def mud_excess(bands: dict, reference: dict) -> float | None:
    """Mean dB the 200-400 Hz shape sits above the reference's."""
    diffs = [bands[b][2] - reference[b] for b in MUD_BANDS
             if b in reference and b in bands and bands[b][2] is not None]
    return float(np.mean(diffs)) if diffs else None


def tracks_under(conn, folder: Path) -> dict[str, dict]:
    """{path: {band_hz: (ltas_db, side_mid_db, shape_db)}} for every
    measured track under `folder`."""
    base = str(folder.resolve()).rstrip(os.sep)
    like = (base.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            + os.sep + "%")
    rows = conn.execute(
        "SELECT t.path, b.band_hz, b.ltas_db, b.side_mid_db, b.shape_db "
        "FROM tracks t JOIN bands b ON b.track_id = t.id "
        "WHERE t.status = 'ok' AND t.path LIKE ? ESCAPE '\\'", (like,)).fetchall()
    out: dict[str, dict] = {}
    for row in rows:
        out.setdefault(row["path"], {})[row["band_hz"]] = (
            row["ltas_db"], row["side_mid_db"], row["shape_db"])
    return out


def report(folder: Path, references: list[Path], database: Path = DATABASE,
           measure: bool = True, out=print) -> dict:
    database.parent.mkdir(parents=True, exist_ok=True)
    if measure:
        # Only what is new or changed is measured; the rest is read back.
        analyze.run(roots=[folder, *references], db_path=database)
    conn = db.connect(database)
    try:
        tracks = tracks_under(conn, folder)
        reference = {}
        if references:
            _, reference, missing = cli._reference_curve_of(
                conn, [str(r) for r in references], bands=MUD_BANDS)
            if missing is not None:
                out(f"The reference {missing} has no measured tracks; mud not compared.")
                reference = {}
    finally:
        conn.close()
    if not tracks:
        out(f"No measured tracks under {folder}.")
        return {}
    rows = []
    for path, bands in tracks.items():
        lost, ratio = mono_loss(bands)
        rows.append({"name": Path(path).name, "lost": lost, "side_mid": ratio,
                     "mud": mud_excess(bands, reference) if reference else None})

    lines = [f"{len(rows)} track(s) under {folder}.", "",
             "1. Bass on a mono club sub (31.5-125 Hz):"]
    measured = [r for r in rows if r["lost"] is not None]
    losing = sorted((r for r in measured if r["lost"] < LOSES_DB), key=lambda r: r["lost"])
    against = [r for r in measured if r["side_mid"] is not None and r["side_mid"] > 0]
    if measured:
        lost = np.array([r["lost"] for r in measured])
        lines.append(f"  lost in a mono sum: {np.median(lost):+.2f} dB (median), "
                     f"{lost.min():+.2f} dB at worst")
    lines.append(f"  {len(losing)} of {len(measured)} lose more than "
                 f"{-LOSES_DB:.0f} dB; {len(against)} have more bass OUT of "
                 f"step between the channels than in it")
    for r in losing[:30]:
        flag = "  <- out of step" if r["side_mid"] is not None and r["side_mid"] > 0 else ""
        lines.append(f"    {r['lost']:+6.2f} dB  {r['name']}{flag}")
    if len(losing) > 30:
        lines.append(f"    ... and {len(losing) - 30} more")

    lines += ["", "2. Mud (200-400 Hz) against the reference:"]
    muddy = [r for r in rows if r["mud"] is not None]
    if not muddy:
        lines.append("  no reference given, so not compared")
    else:
        mud = np.array([r["mud"] for r in muddy])
        over = sorted((r for r in muddy if r["mud"] > 1.0), key=lambda r: -r["mud"])
        lines.append(f"  above the reference: {np.median(mud):+.2f} dB (median), "
                     f"{mud.max():+.2f} at most; {len(over)} of {len(muddy)} "
                     f"more than 1 dB above")
        for r in over[:30]:
            lines.append(f"    {r['mud']:+6.2f} dB  {r['name']}")
        if len(over) > 30:
            lines.append(f"    ... and {len(over) - 30} more")
    out("\n".join(lines))
    return {"rows": rows, "losing": losing, "against": against}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("folder", type=Path)
    parser.add_argument("--reference-folder", dest="references", type=Path,
                        action="append", default=[])
    parser.add_argument("--db", type=Path, default=DATABASE)
    args = parser.parse_args(argv)
    report(args.folder, args.references, args.db)
    return 0


if __name__ == "__main__":
    sys.exit(main())
