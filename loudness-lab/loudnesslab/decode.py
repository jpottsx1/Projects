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

# Original-recording tags are checked first and release tags second. On a
# compilation or remaster the plain `date` tag is the reissue year: "100 Hits
# - The New Romantics (2011)" is a 2011 release of 1980-84 recordings, and
# filing it under the 2010s would put early-eighties mastering into the
# modern reference curve.
ORIGINAL_YEAR_TAGS = ("originaldate", "originalyear", "original_year",
                      "original date", "tdor", "tory")
RELEASE_YEAR_TAGS = ("date", "year", "tdrc", "tyer", "tdrl", "release_date")


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

    year, year_is_original = _year(tags)

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
        "year": year,
        "year_is_original": year_is_original,
        "bpm": (_bpm(tags.get("tbpm") or tags.get("bpm") or tags.get("tmpo"))
                or serato_bpm(path)),
        "musical_key": tags.get("initialkey") or tags.get("tkey") or tags.get("key"),
    }


def decode(path: Path, rate: int = TARGET_RATE,
           source_channels: int | None = None) -> np.ndarray:
    """Decode to (n_samples, 2) float32 at `rate`.

    Mono sources are upmixed to dual mono deliberately: a mono record played
    in a club comes out of both stacks, so that is the signal we want to
    measure. `source_channels` in the database records what it really was.

    The upmix is done HERE rather than by `-ac 2`, which is not the same
    thing. ffmpeg's mono-to-stereo rematrix multiplies by 1/sqrt(2) so that
    total power is preserved -- a mixdown convention, meant to stop a mono
    source clipping a stereo bus. It is wrong for this tool: it makes the
    SAME recording measure 3.01 LU quieter stored as mono than stored as
    dual-mono stereo, so a mono single gets normalised 3 dB loud against
    the stereo tracks either side of it in a set. Both stacks get the
    signal at the fader setting, so both channels get it at unity.

    `source_channels` is a hint from a `probe` of the same file, so the
    scan path does not pay for a second one; without it this probes.
    Anything other than 1 channel is left to ffmpeg, whose 5.1 downmix
    normalisation IS wanted.
    """
    if source_channels is None:
        source_channels = probe(path).get("source_channels") or 2
    mono = source_channels == 1
    out = subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-i", str(path),
         "-map", "0:a:0", "-ac", "1" if mono else "2",
         "-ar", str(rate), "-f", "f32le", "-"],
        capture_output=True,
    )
    if out.returncode != 0:
        raise DecodeError(f"ffmpeg failed: {out.stderr.decode(errors='replace').strip()[:200]}")
    samples = np.frombuffer(out.stdout, dtype="<f4")
    if samples.size < (1 if mono else 2):
        raise DecodeError("decoded to empty audio")
    if mono:
        return np.repeat(samples.reshape(-1, 1), 2, axis=1)
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


def _bpm(value) -> float | None:
    """A tempo tag read leniently: "122", "122.00", "122,5", "122 BPM".
    Zero or less is no tempo."""
    if value is None:
        return None
    match = re.search(r"\d+(?:[.,]\d+)?", str(value))
    if not match:
        return None
    bpm = _float(match.group(0).replace(",", "."))
    return bpm if bpm and bpm > 0 else None


def serato_bpm(path: Path) -> float | None:
    """The tempo Serato keeps in its own "Serato Autotags" frame, or None.

    Serato shows a BPM for every analysed track, but writes it to the
    standard TBPM tag only with a setting on; the Autotags frame it always
    writes. A whole disc of the New Romantics set read no tempo from TBPM
    while Serato showed one for every track. MP3 (ID3v2.3/2.4) only: read
    straight from the tag at the head of the file, nothing decoded.

    The frame is a GEOB: encoding byte, MIME type, file name and
    description (each terminated), then the object -- two version bytes
    (1, 1) and the BPM as ASCII, zero-terminated, then the auto-gain.
    """
    try:
        with open(path, "rb") as f:
            head = f.read(10)
            if len(head) < 10 or head[:3] != b"ID3" or head[3] not in (3, 4):
                return None
            major, flags = head[3], head[5]
            size = _syncsafe(head[6:10])
            tag = f.read(size)
    except OSError:
        return None
    at = 0
    if flags & 0x40:                          # extended header, skipped
        at = _syncsafe(tag[:4]) if major == 4 else 4 + int.from_bytes(tag[:4], "big")
    while at + 10 <= len(tag):
        frame_id = tag[at:at + 4]
        if not frame_id.strip(b"\0"):
            break                              # padding
        raw = tag[at + 4:at + 8]
        length = _syncsafe(raw) if major == 4 else int.from_bytes(raw, "big")
        body = tag[at + 10:at + 10 + length]
        at += 10 + length
        if frame_id != b"GEOB" or not body:
            continue
        found = _autotags_bpm(body)
        if found is not None:
            return found
    return None


def _syncsafe(four: bytes) -> int:
    return (four[0] << 21) | (four[1] << 14) | (four[2] << 7) | four[3]


def _autotags_bpm(body: bytes) -> float | None:
    encoding, rest = body[0], body[1:]
    wide = encoding in (1, 2)                 # UTF-16: two-byte terminators
    end = b"\0\0" if wide else b"\0"

    def cut(data: bytes, terminator: bytes) -> tuple[bytes, bytes]:
        i = 0
        while True:
            i = data.find(terminator, i)
            if i < 0:
                return data, b""
            if not wide or i % 2 == 0:
                return data[:i], data[i + len(terminator):]
            i += 1

    _, rest = cut(rest, b"\0")               # MIME type: always Latin-1
    _, rest = cut(rest, end)                  # file name
    description, rest = cut(rest, end)
    text = description.decode("utf-16" if wide else "latin-1", "replace")
    if text.strip("\ufeff").strip() != "Serato Autotags" or len(rest) < 3:
        return None
    number = rest[2:].split(b"\0", 1)[0].decode("ascii", "replace")
    return _bpm(number)


def _round(value: float | None, divisor: float) -> float | None:
    return None if value is None else round(value / divisor, 1)


def _year(tags: dict) -> tuple[int | None, int | None]:
    """(year, 1 if it came from an original-recording tag else 0).

    The flag matters because era grouping is only meaningful when the year
    describes when the record was MADE. A library of compilations whose years
    are all reissue dates will produce an era table that says nothing.
    """
    for key in ORIGINAL_YEAR_TAGS:
        match = _YEAR.search(str(tags.get(key, "")))
        if match:
            return int(match.group(0)), 1
    for key in RELEASE_YEAR_TAGS:
        match = _YEAR.search(str(tags.get(key, "")))
        if match:
            return int(match.group(0)), 0
    return None, None
