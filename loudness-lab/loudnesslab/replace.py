"""Putting a processed track where its original was -- and back again.

Originals are never written to (CLAUDE.md). This is the one exception Jeff
asked for, so it is built to be undone: the original is MOVED, never
deleted, into a dated folder that mirrors its full path, every swap is
logged beside it, and `restore` puts a whole batch back.

    ~/Music/LoudnessLab/Replaced originals/2026-09-28 213005/
        replaced.jsonl                 one line per swap
        Users/jeff/Music/.../Song.mp3  the original, where it was

Only a finished track replaces its original: one written at its level
(a comparison's B is level-matched for listening, not for a set), and in
the original's own format, so Serato's library path still points at a
file of the kind it expects. MP3 to MP3 carries the whole tag across,
cue points and beatgrid included (`write.carry_id3v2`).
"""

from __future__ import annotations

import datetime as _dt
import json
import shutil
from pathlib import Path

LOG = "replaced.jsonl"


def backup_root() -> Path:
    return Path.home() / "Music" / "LoudnessLab" / "Replaced originals"


def new_batch(root: Path | None = None, now: _dt.datetime | None = None) -> Path:
    stamp = (now or _dt.datetime.now()).strftime("%Y-%m-%d %H%M%S")
    batch = (root or backup_root()) / stamp
    suffix = 1
    while batch.exists():
        suffix += 1
        batch = batch.with_name(f"{stamp} ({suffix})")
    return batch


def _kept_at(batch: Path, original: Path) -> Path:
    """Where in the batch an original is kept: its whole path, mirrored,
    so two "01 Track.mp3" from two albums never meet."""
    absolute = original.resolve()
    return batch / absolute.relative_to(absolute.anchor)


def replace(original: Path, processed: Path, batch: Path) -> tuple[bool, str]:
    """Move `original` into `batch` and `processed` into its place.
    (done, what happened, in words). Either both moves happen or neither."""
    original, processed = Path(original), Path(processed)
    if not original.is_file():
        return False, "the original is no longer there"
    if not processed.is_file():
        return False, "the processed file is missing"
    if processed.suffix.lower() != original.suffix.lower():
        return False, (f"not replaced: the processed file is "
                       f"{processed.suffix}, the original {original.suffix} "
                       f"-- a different format would break its library path")
    kept = _kept_at(batch, original)
    kept.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(original), str(kept))
    try:
        shutil.move(str(processed), str(original))
    except OSError as exc:
        shutil.move(str(kept), str(original))      # put it back as it was
        return False, f"not replaced: {exc}"
    with open(batch / LOG, "a", encoding="utf-8") as log:
        log.write(json.dumps({"original": str(original), "kept": str(kept)}) + "\n")
    return True, f"replaced; the original is kept in {batch}"


def restore(batch: Path) -> tuple[int, list[str]]:
    """Put every original in `batch` back where it was. The processed
    file standing there now is moved into the batch's "undone" folder,
    not deleted. (how many restored, problems in words)."""
    batch = Path(batch)
    log = batch / LOG
    if not log.is_file():
        return 0, [f"{batch} is not a batch of replaced originals (no {LOG})"]
    restored, problems = 0, []
    for line in log.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        entry = json.loads(line)
        original, kept = Path(entry["original"]), Path(entry["kept"])
        if not kept.is_file():
            continue                     # restored already
        if original.exists():
            undone = _kept_at(batch / "undone", original)
            undone.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(original), str(undone))
        original.parent.mkdir(parents=True, exist_ok=True)
        try:
            shutil.move(str(kept), str(original))
            restored += 1
        except OSError as exc:
            problems.append(f"{original}: {exc}")
    return restored, problems
