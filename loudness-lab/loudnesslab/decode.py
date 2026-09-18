"""ffmpeg/ffprobe wrappers. Read-only: nothing here writes to an audio file."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import numpy as np

TARGET_RATE = 48000
AUDIO_SUFFIXES = {
    ".mp3", ".flac", ".aiff", ".aif", ".aifc", ".wav", ".m4a", ".aac",
    ".ogg", ".opus", ".wv", ".wma", ".caf", ".alac",
}

_YEAR = re.compile(r"(19|20)\d{2}")


class DecodeError(RuntimeError):
    pass


def require_tools() -> None:
    missing = [t for t in ("ffmpeg", "ffprobe") if shutil.which(t) is None]
    if missing:
        raise DecodeError(
            f"missing required tool(s): {', '.join(missing)}. "
            "On macOS: brew install ffmpeg"
        )


def probe(path: Path) -> dict:
    """Container/stream properties and tags, normalised to lowercase keys."""
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-print_format", "json",
         "-show_format", "-show_streams", "-select_streams", "a:0", str(path)],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        raise DecodeError(f"ffprobe failed: {out.stderr.strip()[:200]}")
    try:
        data = json.loads(out.stdout)
    except json.JSONDecodeError as exc:
        raise DecodeError(f"ffprobe returned unparseable JSON: {exc}") from exc

    streams = data.get("streams") or []
    if not streams:
        raise DecodeError("no audio stream")
    stream, fmt = streams[0], data.get("format", {})

    tags = {}
    for source in (fmt.get("tags") or {}, stream.get("tags") or {}):
        for key, value in source.items():
            tags.setdefault(key.lower(), value)

    return {
        "codec": stream.get("codec_name"),
        "source_rate": _int(stream.get("sample_rate")),
        "source_channels": _int(stream.get("channels")),
        "bitrate_kbps": _round(_float(stream.get("bit_rate") or fmt.get("bit_rate")), 1000.0),
        "duration_s": _float(fmt.get("duration") or stream.get("duration")),
        "artist": tags.get("artist") or tags.get("album_artist"),
        "title": tags.get("title"),
        "album": tags.get("album"),
        "genre": tags.get("genre"),
        "year": _year(tags),
        "bpm": _float(tags.get("tbpm") or tags.get("bpm")),
        "musical_key": tags.get("initialkey") or tags.get("tkey") or tags.get("key"),
    }


def decode(path: Path, rate: int = TARGET_RATE) -> np.ndarray:
    """Decode to (n_samples, 2) float32 at `rate`.

    Mono sources are upmixed to dual mono deliberately: a mono record played
    in a club comes out of both stacks, so that is the signal we want to
    measure. `source_channels` in the database records what it really was.
    """
    out = subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-i", str(path),
         "-map", "0:a:0", "-ac", "2", "-ar", str(rate), "-f", "f32le", "-"],
        capture_output=True,
    )
    if out.returncode != 0:
        raise DecodeError(f"ffmpeg failed: {out.stderr.decode(errors='replace').strip()[:200]}")
    samples = np.frombuffer(out.stdout, dtype="<f4")
    if samples.size < 2:
        raise DecodeError("decoded to empty audio")
    return samples[: samples.size // 2 * 2].reshape(-1, 2)


def survey(root: Path) -> dict:
    """Walk `root` once, reporting what was found AND what was passed over.

    A library that comes back smaller than expected is nearly always one of
    three things: an extension not in AUDIO_SUFFIXES, a folder the walk could
    not read, or a path that pointed at a single file. Counting all three
    here means `doctor` can say which, instead of silently finding nothing.
    """
    if root.is_file():
        suffix = root.suffix.lower()
        return {
            "audio": [root] if suffix in AUDIO_SUFFIXES else [],
            "skipped": {} if suffix in AUDIO_SUFFIXES else {suffix: 1},
            "folders": 0,
            "errors": [],
            "single_file": True,
        }

    audio: list[Path] = []
    skipped: dict[str, int] = {}
    errors: list[str] = []
    folders = 0
    seen: set[str] = set()

    def on_error(exc: OSError) -> None:
        errors.append(f"{getattr(exc, 'filename', '?')}: {exc.strerror or exc}")

    # followlinks=True because a library folder is quite often a symlink to
    # somewhere else; `seen` keeps that from looping on a cycle.
    for dirpath, dirnames, filenames in os.walk(root, onerror=on_error,
                                                followlinks=True):
        real = os.path.realpath(dirpath)
        if real in seen:
            dirnames[:] = []
            continue
        seen.add(real)
        folders += 1
        # Skip dot-directories: .Trashes and .Spotlight-V100 live on every
        # removable volume and contain nothing we want.
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for name in sorted(filenames):
            # ._Foo.mp3 are AppleDouble resource forks, not audio.
            if name.startswith("."):
                continue
            suffix = Path(name).suffix.lower()
            if suffix in AUDIO_SUFFIXES:
                audio.append(Path(dirpath) / name)
            elif suffix:
                skipped[suffix] = skipped.get(suffix, 0) + 1

    return {"audio": audio, "skipped": skipped, "folders": folders,
            "errors": errors, "single_file": False}


def find_audio(root: Path) -> list[Path]:
    return survey(root)["audio"]


def _int(value) -> int | None:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _float(value) -> float | None:
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if np.isfinite(result) else None


def _round(value: float | None, divisor: float) -> float | None:
    return None if value is None else round(value / divisor, 1)


def _year(tags: dict) -> int | None:
    for key in ("date", "year", "originalyear", "tdrc", "tyer", "originaldate"):
        match = _YEAR.search(str(tags.get(key, "")))
        if match:
            return int(match.group(0))
    return None
