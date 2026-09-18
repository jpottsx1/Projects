"""Text reports over an analysed library.

These are built to test the claims the project rests on, not to confirm them:

  * `loudness` measures how much the choice of estimator actually changes the
    gain decision, and whether that disagreement really does grow with
    loudness range. If it turns out to be a few tenths of a dB across your
    records, the integrated-vs-short-term argument is moot and you should
    just run mp3gain.

  * `lowend` prints the median 1/3-octave shape per era against a modern
    reference, which is the candidate EQ curve for stage 2. It also separates
    "no sub" from "congested low-mid", which are different problems with
    different fixes, and flags bands where the content does not modulate
    enough to be music.
"""

from __future__ import annotations

import sqlite3

import numpy as np

from .spectrum import (BAND_CENTRES, LOW_BAND_MAX_HZ,
                       MIN_SHAPE_FOR_WIDTH_DB)

ERAS = (
    ("pre-1980", 0, 1979),
    ("1980s", 1980, 1989),
    ("1990s", 1990, 1999),
    ("2000s", 2000, 2009),
    ("2010s", 2010, 2019),
    ("2020s", 2020, 9999),
)
REFERENCE_ERA = "2010s"
ESTIMATORS = ("lufs_i", "s_p50", "s_p90", "s_p95", "s_max")
# Aim here rather than at -0.1: 4x oversampling is only good to about 0.5 dB,
# and an MP3 re-encode moves peaks around on top of that.
TRUE_PEAK_CEILING = -1.0


def _era(year: int | None) -> str:
    if year is None:
        return "unknown"
    for name, lo, hi in ERAS:
        if lo <= year <= hi:
            return name
    return "unknown"


def _era_order(name: str) -> int:
    names = [e[0] for e in ERAS]
    return names.index(name) if name in names else len(names)


def _fetch_loudness(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    return conn.execute(
        "SELECT t.id, t.artist, t.title, t.year, t.genre, t.source_channels, "
        "       l.* FROM tracks t JOIN loudness l ON l.track_id = t.id "
        "WHERE t.status = 'ok' AND l.lufs_i IS NOT NULL"
    ).fetchall()


def _spread(values: np.ndarray) -> str:
    if values.size == 0:
        return "n/a"
    return (f"sd {values.std():5.2f}   "
            f"p10 {np.percentile(values, 10):7.2f}   "
            f"med {np.median(values):7.2f}   "
            f"p90 {np.percentile(values, 90):7.2f}   "
            f"span {np.percentile(values, 90) - np.percentile(values, 10):5.2f}")


def loudness_report(conn: sqlite3.Connection) -> str:
    rows = _fetch_loudness(conn)
    if not rows:
        return "No analysed tracks with loudness results yet."

    out = [f"LOUDNESS  ({len(rows)} tracks)", "=" * 78, "",
           "Where the library sits now", "-" * 78]
    columns = {}
    for name in ESTIMATORS + ("lra", "true_peak_dbtp", "crest_db"):
        values = np.array([r[name] for r in rows if r[name] is not None], dtype=float)
        columns[name] = values
        out.append(f"  {name:16s} {_spread(values)}")

    out += ["", "How much the estimator choice changes the gain decision", "-" * 78,
            "  Each row is (estimator - LUFS-I) per track: the dB by which normalising",
            "  on that estimator differs from normalising on integrated loudness.",
            "  If these are near zero the whole argument is academic.", ""]
    base = np.array([r["lufs_i"] for r in rows], dtype=float)
    for name in ESTIMATORS:
        if name == "lufs_i":
            continue
        pairs = np.array([[r[name], r["lufs_i"]] for r in rows
                          if r[name] is not None], dtype=float)
        if pairs.size:
            out.append(f"  {name:16s} {_spread(pairs[:, 0] - pairs[:, 1])}")

    out += ["", "  ...broken down by loudness range (the prediction being tested is that",
            "  the disagreement grows with LRA):", "",
            f"  {'LRA band':>12s} {'n':>6s} {'median s_p95 - lufs_i':>24s} {'p90':>8s}"]
    lra = np.array([r["lra"] if r["lra"] is not None else np.nan for r in rows])
    delta = np.array([r["s_p95"] - r["lufs_i"] if r["s_p95"] is not None else np.nan
                      for r in rows])
    for lo, hi in ((0, 3), (3, 6), (6, 9), (9, 12), (12, 99)):
        mask = (lra >= lo) & (lra < hi) & np.isfinite(delta)
        if mask.sum() == 0:
            continue
        label = f"{lo}-{hi} LU" if hi < 99 else f"{lo}+ LU"
        out.append(f"  {label:>12s} {mask.sum():6d} {np.median(delta[mask]):24.2f} "
                   f"{np.percentile(delta[mask], 90):8.2f}")

    out += ["", "Choosing a target: how many tracks would need a BOOST", "-" * 78,
            "  A negative gain is free. A positive gain eventually needs a limiter,",
            "  which is the one thing this project is trying to avoid, so the useful",
            "  target is the one where almost nothing gets turned up.", "",
            f"  {'target':>8s}  {'estimator':>10s}  {'need boost':>11s}  "
            f"{'> +3 dB':>8s}  {'clip -1 dBTP':>13s}"]
    peak = np.array([r["true_peak_dbtp"] if r["true_peak_dbtp"] is not None else np.nan
                     for r in rows])
    for name in ("lufs_i", "s_p95"):
        values = np.array([r[name] if r[name] is not None else np.nan for r in rows])
        for target in (-10, -12, -14, -16, -18):
            gain = target - values
            ok = np.isfinite(gain)
            if ok.sum() == 0:
                continue
            boosted = (gain[ok] > 0).mean() * 100
            big = (gain[ok] > 3).mean() * 100
            over = np.isfinite(peak) & ok & ((peak + gain) > TRUE_PEAK_CEILING)
            out.append(f"  {target:8d}  {name:>10s}  {boosted:10.1f}%  "
                       f"{big:7.1f}%  {over.mean() * 100:12.1f}%")

    out += ["", "Masters that were already clipped", "-" * 78]
    runs = np.array([r["clip_runs"] or 0 for r in rows])
    out.append(f"  tracks with runs of consecutive full-scale samples: "
               f"{(runs > 0).sum()} of {len(rows)} ({(runs > 0).mean() * 100:.1f}%)")
    out.append(f"  tracks with more than 100 such runs:                "
               f"{(runs > 100).sum()} ({(runs > 100).mean() * 100:.1f}%)")
    return "\n".join(out)


def _band_matrix(conn: sqlite3.Connection, field: str) -> tuple[list[float], dict]:
    """{era: {band_hz: [values]}} for one bands column."""
    rows = conn.execute(
        f"SELECT t.year, b.band_hz, b.{field} AS value FROM bands b "
        "JOIN tracks t ON t.id = b.track_id "
        f"WHERE t.status = 'ok' AND b.{field} IS NOT NULL"
    ).fetchall()
    bands, by_era = set(), {}
    for row in rows:
        bands.add(row["band_hz"])
        by_era.setdefault(_era(row["year"]), {}).setdefault(row["band_hz"], []).append(row["value"])
    return sorted(bands), by_era


def _era_counts(conn: sqlite3.Connection) -> dict:
    counts = {}
    for row in conn.execute("SELECT year FROM tracks WHERE status = 'ok'"):
        counts[_era(row["year"])] = counts.get(_era(row["year"]), 0) + 1
    return counts


def lowend_report(conn: sqlite3.Connection, reference: str = REFERENCE_ERA) -> str:
    bands, shape = _band_matrix(conn, "shape_db")
    if not bands:
        return "No analysed tracks with band results yet."
    low = [b for b in bands if b <= LOW_BAND_MAX_HZ]
    counts = _era_counts(conn)
    eras = sorted(shape, key=_era_order)

    def median_curve(era: str, table: dict) -> dict:
        return {b: float(np.median(table[era][b])) for b in table.get(era, {})}

    out = ["LOW END  (1/3-octave, relative to each track's own broadband level)",
           "=" * 78, "",
           "Median shape per era, in dB relative to broadband", "-" * 78,
           "  A number here is level-independent: it says what fraction of the",
           "  track's energy sits in that band, not how loud the track is.", "",
           "  " + "era".ljust(10) + "n".rjust(6) + "".join(f"{b:>8.0f}" for b in low)]
    for era in eras:
        curve = median_curve(era, shape)
        cells = "".join(f"{curve[b]:8.1f}" if b in curve else "       -" for b in low)
        out.append(f"  {era:<10s}{counts.get(era, 0):6d}{cells}")

    if reference in shape:
        ref = median_curve(reference, shape)
        out += ["", f"Difference from the {reference} reference "
                    f"(positive = this era has LESS energy here)", "-" * 78,
                "  This is the candidate stage-2 correction curve. Values are",
                "  deliberately un-smoothed; stage 2 should fit 3-4 gentle filters to",
                "  them and cap the result at about 5 dB.", "",
                "  " + "era".ljust(10) + "n".rjust(6) + "".join(f"{b:>8.0f}" for b in low)]
        for era in eras:
            if era == reference:
                continue
            curve = median_curve(era, shape)
            cells = "".join(
                f"{ref[b] - curve[b]:8.1f}" if b in curve and b in ref else "       -"
                for b in low)
            out.append(f"  {era:<10s}{counts.get(era, 0):6d}{cells}")
        out += ["",
                "  Read the two halves separately: a positive number at 25-50 Hz means",
                "  missing sub, which EQ can only fix if the content is actually there",
                "  (check the modulation table below). A NEGATIVE number at 200-315 Hz",
                "  means this era has MORE low-mid than modern masters -- that is",
                "  congestion, and cutting it is cheap, safe and often does more for",
                "  perceived weight than any sub boost."]

    def is_empty(era: str, band: float) -> bool:
        """True where this era's median band level is too low to interpret."""
        values = shape.get(era, {}).get(band)
        return values is None or float(np.median(values)) < MIN_SHAPE_FOR_WIDTH_DB

    _, modulation_hi = _band_matrix(conn, "p90_db")
    _, modulation_lo = _band_matrix(conn, "p10_db")
    out += ["", "Does the low end modulate like music? (median p90 - p10, dB)", "-" * 78,
            "  A band carrying a bassline swings with the arrangement. A band holding",
            "  rumble, hiss or cutting noise sits still. CAVEAT: the narrow low bands",
            "  contain few FFT bins, so they show 8-9 dB of spread on noise alone --",
            "  compare across eras, not against an absolute threshold.", "",
            "  " + "era".ljust(10) + "n".rjust(6) + "".join(f"{b:>8.0f}" for b in low)]
    for era in eras:
        hi_curve = median_curve(era, modulation_hi)
        lo_curve = median_curve(era, modulation_lo)
        cells = "".join(
            "       ." if is_empty(era, b)
            else (f"{hi_curve[b] - lo_curve[b]:8.1f}"
                  if b in hi_curve and b in lo_curve else "       -")
            for b in low)
        out.append(f"  {era:<10s}{counts.get(era, 0):6d}{cells}")
    out.append("  '.' = the band is more than 40 dB down, so there is nothing "
               "there to measure.")

    _, side = _band_matrix(conn, "side_mid_db")
    if side:
        out += ["", "Stereo width in the low end (median side/mid, dB)", "-" * 78,
                "  Strongly negative values low down mean the bass is effectively mono:",
                "  the signature of a record cut for vinyl. Those tracks have a hard",
                "  floor on how much genuine sub can be recovered.", "",
                "  " + "era".ljust(10) + "n".rjust(6) + "".join(f"{b:>8.0f}" for b in low)]
        for era in sorted(side, key=_era_order):
            curve = median_curve(era, side)
            cells = "".join(
                "       ." if is_empty(era, b)
                else (f"{curve[b]:8.1f}" if b in curve else "       -")
                for b in low)
            out.append(f"  {era:<10s}{counts.get(era, 0):6d}{cells}")
        out.append("  '.' = the band is more than 40 dB down; width there is "
                   "filter residue, not music.")
    return "\n".join(out)


# The bands where restoring an old record's low end is actually feasible:
# above the vinyl-era roll-off, below where it stops being sub. Derived from
# BAND_CENTRES rather than written out, because the nominal centre is 31.5 Hz
# and a hardcoded 32.0 silently matches nothing.
LOW_SHAPE_BANDS = tuple(b for b in BAND_CENTRES if 31.0 <= b <= 63.0)


def folders_report(conn: sqlite3.Connection) -> str:
    """Loudness and low-end shape grouped by the folder each track sits in.

    Useful whenever a library is sorted into folders that mean something. If
    those folders are Camelot keys, this is the direct test of whether
    1/3-octave shape tracks the KEY of the music rather than its mastering --
    which is the thing that would make spectral matching dangerous, because
    an EQ fitted to it would be 'correcting' tracks for being in F.
    """
    rows = conn.execute(
        "SELECT t.path, t.year, l.lufs_i, l.s_p95, l.lra, l.true_peak_dbtp "
        "FROM tracks t JOIN loudness l ON l.track_id = t.id "
        "WHERE t.status = 'ok' AND l.lufs_i IS NOT NULL"
    ).fetchall()
    if not rows:
        return "No analysed tracks with loudness results yet."

    from pathlib import Path as _Path

    grouped: dict[str, dict[str, list]] = {}
    for row in rows:
        folder = _Path(row["path"]).parent.name or "(root)"
        bucket = grouped.setdefault(folder, {"lufs_i": [], "s_p95": [],
                                             "lra": [], "tp": [], "year": []})
        for key, column in (("lufs_i", "lufs_i"), ("s_p95", "s_p95"),
                            ("lra", "lra"), ("tp", "true_peak_dbtp")):
            if row[column] is not None:
                bucket[key].append(row[column])
        if row["year"] is not None:
            bucket["year"].append(row["year"])

    band_rows = conn.execute(
        "SELECT t.path, b.band_hz, b.shape_db FROM bands b "
        "JOIN tracks t ON t.id = b.track_id "
        "WHERE t.status = 'ok' AND b.shape_db IS NOT NULL "
        f"AND b.band_hz IN ({', '.join(str(b) for b in LOW_SHAPE_BANDS)})"
    ).fetchall()
    shapes: dict[str, dict[float, list]] = {}
    for row in band_rows:
        folder = _Path(row["path"]).parent.name or "(root)"
        shapes.setdefault(folder, {}).setdefault(row["band_hz"], []).append(
            row["shape_db"])

    out = [f"FOLDERS  ({len(rows)} tracks in {len(grouped)} folders)", "=" * 88,
           "  Medians per folder. The last four columns are 1/3-octave shape,",
           "  in dB relative to each track's own broadband level.", "",
           f"  {'folder':<14s}{'n':>5s}{'yr':>6s}{'LUFS-I':>9s}{'s_p95':>8s}"
           f"{'LRA':>7s}{'dBTP':>7s}"
           + "".join(f"{band:>8.0f}" for band in LOW_SHAPE_BANDS)]

    def median(values: list) -> float | None:
        return float(np.median(values)) if values else None

    for folder in sorted(grouped):
        bucket = grouped[folder]
        curve = shapes.get(folder, {})
        cells = "".join(
            f"{median(curve[band]):8.1f}" if curve.get(band) else "       -"
            for band in LOW_SHAPE_BANDS)
        year = median(bucket["year"])
        out.append(
            f"  {folder[:13]:<14s}{len(bucket['lufs_i']):5d}"
            f"{('' if year is None else f'{year:.0f}'):>6s}"
            f"{_fmt(median(bucket['lufs_i'])):>9s}{_fmt(median(bucket['s_p95'])):>8s}"
            f"{_fmt(median(bucket['lra'])):>7s}{_fmt(median(bucket['tp'])):>7s}{cells}")

    spread = {}
    for band in LOW_SHAPE_BANDS:
        per_folder = [median(shapes[f][band]) for f in shapes
                      if shapes[f].get(band)]
        if len(per_folder) > 1:
            spread[band] = max(per_folder) - min(per_folder)
    if spread:
        out += ["",
                "  Spread of the folder medians in each band (max - min):",
                "    " + "   ".join(f"{band:.0f} Hz: {value:.1f} dB"
                                    for band, value in spread.items()),
                "",
                "  If these folders are musical keys and this spread is large,",
                "  low-end shape is tracking the key, not the mastering -- and a",
                "  spectral match fitted to it would 'correct' tracks for the key",
                "  they are in. Broad smoothing is what protects against that.",
                "  A small spread means the risk is not real in this library."]
    return "\n".join(out)


def tracks_report(conn: sqlite3.Connection, estimator: str = "s_p95",
                  target: float = -14.0, limit: int = 40) -> str:
    if estimator not in ESTIMATORS:
        raise ValueError(f"estimator must be one of {', '.join(ESTIMATORS)}")
    rows = _fetch_loudness(conn)
    if not rows:
        return "No analysed tracks with loudness results yet."

    out = [f"DRY RUN  estimator={estimator}  target={target:+.1f}  "
           f"ceiling={TRUE_PEAK_CEILING:+.1f} dBTP", "=" * 108,
           "  'limit' marks tracks where the gain would push true peak past the",
           "  ceiling, so a limiter would have to engage. Nothing is written.", "",
           f"  {'artist / title':<46s}{'yr':>5s}{'LUFS-I':>8s}{'s_p95':>7s}"
           f"{'LRA':>6s}{'dBTP':>7s}{'gain':>7s}  {'result':<9s}"]
    scored = []
    for row in rows:
        value = row[estimator]
        if value is None:
            continue
        gain = target - value
        peak_after = (row["true_peak_dbtp"] + gain
                      if row["true_peak_dbtp"] is not None else None)
        scored.append((abs(gain), row, gain, peak_after))
    scored.sort(key=lambda item: -item[0])

    for _, row, gain, peak_after in scored[:limit]:
        name = " - ".join(p for p in (row["artist"], row["title"]) if p) or "(untagged)"
        flag = "limit" if peak_after is not None and peak_after > TRUE_PEAK_CEILING else "gain only"
        out.append(
            f"  {name[:45]:<46s}{row['year'] or '':>5}{row['lufs_i']:8.1f}"
            f"{_fmt(row['s_p95']):>7s}{_fmt(row['lra']):>6s}"
            f"{_fmt(row['true_peak_dbtp']):>7s}{gain:+7.1f}  {flag:<9s}")
    if len(scored) > limit:
        out.append(f"  ... {len(scored) - limit} more (sorted by largest gain first)")
    return "\n".join(out)


def _fmt(value) -> str:
    return "-" if value is None else f"{value:.1f}"


def errors_report(conn: sqlite3.Connection) -> str:
    rows = conn.execute(
        "SELECT path, error FROM tracks WHERE status = 'error' ORDER BY path"
    ).fetchall()
    if not rows:
        return "No failures."
    out = [f"FAILURES ({len(rows)})", "=" * 78]
    out += [f"  {r['path']}\n      {r['error']}" for r in rows]
    return "\n".join(out)
