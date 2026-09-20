"""Plan and apply lossless gain across a library, with a log that can undo it.

Nothing here writes without being asked twice: the caller must pass apply=True,
and writing over originals additionally requires in_place=True. The default is
a copy into an output folder, leaving the source untouched.
"""

from __future__ import annotations

import datetime as dt
import shutil
from dataclasses import dataclass
from pathlib import Path

from . import db, decode, mp3gain

SUPPORTED_SUFFIXES = {".mp3"}


@dataclass
class Proposal:
    path: Path
    output: Path | None
    artist: str | None
    title: str | None
    measured: float | None          # the estimator's value for this track
    wanted_db: float                # target - measured
    plan: mp3gain.GainPlan | None
    problem: str | None = None

    @property
    def ok(self) -> bool:
        return self.problem is None and self.plan is not None

    @property
    def residual_db(self) -> float | None:
        """How far off target the 1.5 dB quantisation leaves this track."""
        if self.plan is None:
            return None
        return self.plan.applied_db - self.wanted_db


def _stale(row, path: Path) -> str | None:
    try:
        stat = path.stat()
    except OSError as exc:
        return f"cannot stat: {exc}"
    if row["size_bytes"] != stat.st_size or row["mtime_ns"] != stat.st_mtime_ns:
        return "file changed since analysis -- re-run analyze first"
    return None


def propose(conn, roots: list[Path], estimator: str, target: float,
            out_dir: Path | None) -> list[Proposal]:
    """Work out what would happen, touching nothing."""
    rows = conn.execute(
        f"SELECT t.path, t.artist, t.title, t.size_bytes, t.mtime_ns, "
        f"       l.{estimator} AS measured "
        f"FROM tracks t LEFT JOIN loudness l ON l.track_id = t.id "
        f"WHERE t.status = 'ok' ORDER BY t.path"
    ).fetchall()
    by_path = {row["path"]: row for row in rows}

    proposals: list[Proposal] = []
    for root in roots:
        # Walk exactly as analyze did, and do NOT resolve: analyze stores the
        # path it walked, so resolving here would turn every symlinked root
        # (/tmp -> /private/tmp on macOS, any symlinked volume) into a lookup
        # miss and report files as unanalysed straight after measuring them.
        files = [path for path in decode.find_audio(root)
                 if path.suffix.lower() in SUPPORTED_SUFFIXES]
        for path in files:
            row = by_path.get(str(path))
            output = None
            if out_dir is not None:
                relative = path.name if root.is_file() else path.relative_to(root)
                output = out_dir / relative
            if row is None:
                proposals.append(Proposal(path, output, None, None, None, 0.0,
                                          None, "not in the database -- analyze it first"))
                continue
            problem = _stale(row, path)
            if problem is None and row["measured"] is None:
                problem = f"no {estimator} measurement"
            if problem is not None:
                proposals.append(Proposal(path, output, row["artist"], row["title"],
                                          row["measured"], 0.0, None, problem))
                continue

            wanted = target - row["measured"]
            try:
                computed = mp3gain.plan(path.read_bytes(), wanted)
            except (mp3gain.Mp3Error, OSError) as exc:
                computed, problem = None, f"{type(exc).__name__}: {exc}"
            proposals.append(Proposal(path, output, row["artist"], row["title"],
                                      row["measured"], wanted, computed, problem))
    return proposals


def apply(conn, proposals: list[Proposal], in_place: bool) -> dict:
    """Write the planned gains. Verifies every file it touches.

    Verification re-parses the written file and checks each global_gain moved
    by exactly the planned step. That proves the write structurally without a
    decode, so it is cheap enough to run unconditionally.
    """
    counts = {"written": 0, "skipped": 0, "unchanged": 0, "failed": 0}
    for proposal in proposals:
        if not proposal.ok:
            counts["skipped"] += 1
            continue
        if proposal.plan.steps == 0:
            counts["unchanged"] += 1
            continue

        destination = proposal.path if in_place else proposal.output
        try:
            source = proposal.path.read_bytes()
            before = mp3gain.read_gains(source, mp3gain.parse_frames(source))
            written = mp3gain.apply_steps(source, proposal.plan.steps)

            if not in_place:
                destination.parent.mkdir(parents=True, exist_ok=True)
            # Write beside the destination and rename, so an interrupted run
            # cannot leave a half-written file where a playable one was.
            temporary = destination.with_suffix(destination.suffix + ".partial")
            temporary.write_bytes(written)
            if not in_place:
                shutil.copystat(proposal.path, temporary)
            temporary.replace(destination)

            check = destination.read_bytes()
            after = mp3gain.read_gains(check, mp3gain.parse_frames(check))
            if len(after) != len(before) or any(
                    b + proposal.plan.steps != a for b, a in zip(before, after)):
                raise mp3gain.Mp3Error("verification failed after write")
        except Exception as exc:
            proposal.problem = f"{type(exc).__name__}: {exc}"
            counts["failed"] += 1
            continue

        _log(conn, proposal, destination, in_place)
        counts["written"] += 1
    conn.commit()
    return counts


def _log(conn, proposal: Proposal, destination: Path, in_place: bool) -> None:
    conn.execute(
        "INSERT INTO gain_log (path, output_path, steps, applied_db, "
        "                      in_place, applied_at) VALUES (?, ?, ?, ?, ?, ?)",
        (str(proposal.path), str(destination), proposal.plan.steps,
         proposal.plan.applied_db, 1 if in_place else 0,
         dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")),
    )


def undo(conn, limit_to: list[Path] | None = None) -> dict:
    """Reverse every in-place change still on record, newest first."""
    rows = conn.execute(
        "SELECT id, output_path, steps FROM gain_log "
        "WHERE in_place = 1 AND undone_at IS NULL ORDER BY id DESC"
    ).fetchall()
    wanted = {str(p.resolve()) for p in limit_to} if limit_to else None

    counts = {"undone": 0, "failed": 0, "skipped": 0}
    for row in rows:
        path = Path(row["output_path"])
        if wanted is not None and str(path) not in wanted:
            counts["skipped"] += 1
            continue
        try:
            data = path.read_bytes()
            path.write_bytes(mp3gain.apply_steps(data, -row["steps"]))
        except Exception:
            counts["failed"] += 1
            continue
        conn.execute("UPDATE gain_log SET undone_at = ? WHERE id = ?",
                     (dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
                      row["id"]))
        counts["undone"] += 1
    conn.commit()
    return counts
