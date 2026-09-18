"""Per-track analysis and the parallel walk over a library.

One decode per track feeds both the loudness engine and the spectrum
analysis. Results are written from the parent process only -- SQLite and
multiprocessing do not mix well in the other direction.
"""

from __future__ import annotations

import datetime as dt
import os
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

from . import __version__, bs1770, db, decode, spectrum


def analyse_file(path_str: str) -> dict:
    """Analyse one file. Never raises: failures come back as status='error'.

    Runs in a worker process, so it takes and returns plain data.
    """
    path = Path(path_str)
    try:
        stat = path.stat()
    except OSError as exc:
        return _failure(path_str, None, f"stat failed: {exc}")

    base = {
        "path": path_str,
        "size_bytes": stat.st_size,
        "mtime_ns": stat.st_mtime_ns,
        "analyzed_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "tool_version": __version__,
    }

    try:
        meta = decode.probe(path)
        samples = decode.decode(path)
        loudness = bs1770.measure(samples)
        loudness.pop("_short_term", None)
        bands = spectrum.analyse(
            samples, decode.TARGET_RATE,
            source_is_mono=(meta.get("source_channels") == 1),
        )
    except Exception as exc:  # decode/probe/DSP failures are per-file, not fatal
        return _failure(path_str, base, f"{type(exc).__name__}: {exc}")

    return {
        "track": {**base, **meta, "status": "ok", "error": None},
        "loudness": loudness,
        "bands": bands,
    }


def _failure(path_str: str, base: dict | None, message: str) -> dict:
    track = base or {"path": path_str, "size_bytes": None, "mtime_ns": None,
                     "analyzed_at": None, "tool_version": __version__}
    return {"track": {**track, "status": "error", "error": message[:500]},
            "loudness": None, "bands": []}


def default_jobs() -> int:
    """Half the cores by default.

    Each worker holds a whole decoded track in memory -- a 12-minute extended
    mix is about 280 MB at 48 kHz stereo float32 -- so saturating the CPU
    count costs more in RAM than it buys in throughput.
    """
    return max(1, (os.cpu_count() or 2) // 2)


def run(root: Path, db_path: Path, jobs: int | None = None,
        force: bool = False, limit: int | None = None,
        progress=None) -> dict:
    """Analyse everything under `root` into `db_path`. Resumable."""
    decode.require_tools()
    conn = db.connect(db_path)
    try:
        candidates = decode.find_audio(root)
        pending = []
        for path in candidates:
            try:
                stat = path.stat()
            except OSError:
                pending.append(path)
                continue
            if force or db.needs_analysis(conn, path, stat):
                pending.append(path)
        skipped = len(candidates) - len(pending)
        if limit is not None:
            pending = pending[:limit]

        counts = {"found": len(candidates), "skipped": skipped,
                  "analysed": 0, "errors": 0}
        if not pending:
            return counts

        workers = jobs or default_jobs()
        if workers == 1:
            results = map(analyse_file, (str(p) for p in pending))
            for done, result in enumerate(results, 1):
                _record(conn, result, counts, done, len(pending), progress)
        else:
            with ProcessPoolExecutor(max_workers=workers) as pool:
                results = pool.map(analyse_file, [str(p) for p in pending],
                                   chunksize=1)
                for done, result in enumerate(results, 1):
                    _record(conn, result, counts, done, len(pending), progress)
        return counts
    finally:
        conn.close()


def _record(conn, result, counts, done, total, progress) -> None:
    db.store(conn, result)
    if result["track"]["status"] == "ok":
        counts["analysed"] += 1
    else:
        counts["errors"] += 1
    if progress:
        progress(done, total, result)
