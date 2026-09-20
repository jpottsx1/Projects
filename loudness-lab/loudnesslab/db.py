"""SQLite storage. One row per track, plus one row per 1/3-octave band."""

from __future__ import annotations

import sqlite3
from pathlib import Path

from . import SCHEMA_VERSION, __version__

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tracks (
    id              INTEGER PRIMARY KEY,
    path            TEXT UNIQUE NOT NULL,
    size_bytes      INTEGER,
    mtime_ns        INTEGER,
    analyzed_at     TEXT,
    tool_version    TEXT,
    status          TEXT NOT NULL,          -- 'ok' or 'error'
    error           TEXT,
    codec           TEXT,
    source_rate     INTEGER,
    source_channels INTEGER,
    bitrate_kbps    REAL,
    duration_s      REAL,
    artist          TEXT,
    title           TEXT,
    album           TEXT,
    genre           TEXT,
    year            INTEGER,
    year_is_original INTEGER,
    bpm             REAL,
    musical_key     TEXT
);

CREATE TABLE IF NOT EXISTS loudness (
    track_id         INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
    lufs_i           REAL,
    lra              REAL,
    s_max            REAL,
    s_p95            REAL,
    s_p90            REAL,
    s_p50            REAL,
    s_p10            REAL,
    true_peak_dbtp   REAL,
    sample_peak_dbfs REAL,
    crest_db         REAL,
    clipped_samples  INTEGER,
    clip_runs        INTEGER
);

CREATE TABLE IF NOT EXISTS bands (
    track_id    INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    band_hz     REAL NOT NULL,
    ltas_db     REAL,
    shape_db    REAL,
    p10_db      REAL,
    p90_db      REAL,
    side_mid_db REAL,
    PRIMARY KEY (track_id, band_hz)
);

CREATE TABLE IF NOT EXISTS gain_log (
    id          INTEGER PRIMARY KEY,
    path        TEXT NOT NULL,
    output_path TEXT NOT NULL,
    steps       INTEGER NOT NULL,
    applied_db  REAL NOT NULL,
    in_place    INTEGER NOT NULL,
    applied_at  TEXT NOT NULL,
    undone_at   TEXT
);

CREATE INDEX IF NOT EXISTS idx_tracks_year ON tracks(year);
CREATE INDEX IF NOT EXISTS idx_tracks_status ON tracks(status);
CREATE INDEX IF NOT EXISTS idx_bands_hz ON bands(band_hz);
"""

TRACK_FIELDS = (
    "codec", "source_rate", "source_channels", "bitrate_kbps", "duration_s",
    "artist", "title", "album", "genre", "year", "year_is_original", "bpm",
    "musical_key",
)
LOUDNESS_FIELDS = (
    "lufs_i", "lra", "s_max", "s_p95", "s_p90", "s_p50", "s_p10",
    "true_peak_dbtp", "sample_peak_dbfs", "crest_db",
    "clipped_samples", "clip_runs",
)
BAND_FIELDS = ("band_hz", "ltas_db", "shape_db", "p10_db", "p90_db", "side_mid_db")


def connect(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    conn.executescript(SCHEMA)
    stored = conn.execute(
        "SELECT value FROM meta WHERE key = 'schema_version'"
    ).fetchone()
    if stored is None:
        conn.execute("INSERT INTO meta (key, value) VALUES ('schema_version', ?)",
                     (str(SCHEMA_VERSION),))
    else:
        _migrate(conn, int(stored["value"]))
    conn.commit()
    return conn


def _migrate(conn: sqlite3.Connection, version: int) -> None:
    """Bring an older database forward rather than making the user re-run it.

    Re-analysing a large library costs hours, so a schema bump migrates in
    place. Columns added this way stay NULL for existing rows, which reports
    must read as "unknown" rather than as a value.
    """
    if version > SCHEMA_VERSION:
        raise RuntimeError(
            f"database is schema v{version}, newer than this build's "
            f"v{SCHEMA_VERSION}. Update loudness-lab, or analyse into a new file."
        )
    # v3 only adds the gain_log table, which CREATE TABLE IF NOT EXISTS
    # above has already made; nothing to alter.
    if version < 2:
        columns = {row["name"] for row in conn.execute("PRAGMA table_info(tracks)")}
        if "year_is_original" not in columns:
            conn.execute("ALTER TABLE tracks ADD COLUMN year_is_original INTEGER")
    conn.execute("UPDATE meta SET value = ? WHERE key = 'schema_version'",
                 (str(SCHEMA_VERSION),))


def needs_analysis(conn: sqlite3.Connection, path: Path, stat) -> bool:
    """True unless we already have a current, successful result for this file."""
    row = conn.execute(
        "SELECT size_bytes, mtime_ns, status, tool_version FROM tracks WHERE path = ?",
        (str(path),),
    ).fetchone()
    if row is None or row["status"] != "ok":
        return True
    return (row["size_bytes"] != stat.st_size
            or row["mtime_ns"] != stat.st_mtime_ns
            or row["tool_version"] != __version__)


def store(conn: sqlite3.Connection, result: dict) -> None:
    """Write one track's results, replacing any previous attempt."""
    track = result["track"]
    columns = ["path", "size_bytes", "mtime_ns", "analyzed_at", "tool_version",
               "status", "error", *TRACK_FIELDS]
    values = [track.get(name) for name in columns]
    placeholders = ", ".join("?" * len(columns))
    conn.execute(
        f"INSERT INTO tracks ({', '.join(columns)}) VALUES ({placeholders}) "
        f"ON CONFLICT(path) DO UPDATE SET "
        + ", ".join(f"{name} = excluded.{name}" for name in columns[1:]),
        values,
    )
    track_id = conn.execute(
        "SELECT id FROM tracks WHERE path = ?", (track["path"],)
    ).fetchone()["id"]

    conn.execute("DELETE FROM loudness WHERE track_id = ?", (track_id,))
    conn.execute("DELETE FROM bands WHERE track_id = ?", (track_id,))

    loudness = result.get("loudness")
    if loudness:
        names = ("track_id", *LOUDNESS_FIELDS)
        conn.execute(
            f"INSERT INTO loudness ({', '.join(names)}) "
            f"VALUES ({', '.join('?' * len(names))})",
            [track_id, *(loudness.get(name) for name in LOUDNESS_FIELDS)],
        )
    bands = result.get("bands") or []
    if bands:
        names = ("track_id", *BAND_FIELDS)
        conn.executemany(
            f"INSERT INTO bands ({', '.join(names)}) "
            f"VALUES ({', '.join('?' * len(names))})",
            [[track_id, *(b.get(name) for name in BAND_FIELDS)] for b in bands],
        )
    conn.commit()
