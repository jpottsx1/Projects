"""Writing the processed audio out, in the format the caller asked for.

FLAC is the default and the honest one: this stage has already spent a
decode, and a second lossy encode gives away more than the sub is worth.
But a lossless file is four times the size and not every player wants one,
so MP3 and AAC are offered for the copies that go into a set.

Both A and B of a comparison pair always get the SAME format. Writing a
lossless original against a lossy processed version would have you
listening to the codec and calling it the processing.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import numpy as np

# name on the command line -> (label, extension)
FORMATS = {
    "flac": ("FLAC", "flac"),
    "mp3": ("MP3 320", "mp3"),
    # 256, not the 320 that was asked for, because 320 is not a thing AAC
    # actually does: ffmpeg's native encoder was measured returning about
    # 200 kbps for a 320 request and 208 for a 256 one -- it clamps,
    # silently, and a control labelled 320 would be describing something
    # that never happens. 256 is also where AAC-LC is generally reckoned
    # transparent, and what Apple ship music at.
    "aac": ("AAC 256", "m4a"),
}
DEFAULT_FORMAT = "flac"

_encoders: dict[str, bool] = {}


def label(fmt: str) -> str:
    return FORMATS[fmt][0]


def extension(fmt: str) -> str:
    return FORMATS[fmt][1]


def has_encoder(name: str) -> bool:
    """Is this encoder in the ffmpeg on PATH? Asked once per process.

    It is a build option, not a given: `aac_at` is Apple's and only exists
    on macOS builds compiled against AudioToolbox.
    """
    if name not in _encoders:
        try:
            out = subprocess.run(["ffmpeg", "-v", "quiet", "-encoders"],
                                 capture_output=True, text=True)
            _encoders[name] = any(
                line.split()[1:2] == [name]
                for line in out.stdout.splitlines() if line.strip())
        except OSError:
            _encoders[name] = False
    return _encoders[name]


def _encoder_arguments(fmt: str) -> list[str]:
    if fmt == "flac":
        return ["-c:a", "flac"]
    if fmt == "mp3":
        return ["-c:a", "libmp3lame", "-b:a", "320k"]
    # Apple's encoder where the build has it -- macOS ffmpeg usually does,
    # and it is better than the native one at this bitrate.
    return ["-c:a", "aac_at" if has_encoder("aac_at") else "aac", "-b:a", "256k"]


def write(path: Path, x: np.ndarray, rate: int, source: Path | None = None,
          fmt: str = DEFAULT_FORMAT) -> Path:
    """Write `x` beside `path`, in `fmt`, carrying what tags can travel.

    `path` is named without an extension by the caller having one already;
    the one belonging to the format wins, and the path actually written is
    returned so nothing has to guess it.

    Serato's cue points ARE carried, MP3 to MP3, by copying the original's
    whole ID3v2 tag onto the new file afterwards. ffmpeg will not do it --
    `-map_metadata` carries text and drops GEOB, measured: two frames in,
    none out. Going to FLAC or M4A instead means translating rather than
    copying (Serato keeps markers as base64 Vorbis comments and as
    com.serato.dj atoms respectively), which is a different job and needs a
    real Serato file of each to check against. So text tags travel
    everywhere; markers travel MP3 to MP3.
    """
    if fmt not in FORMATS:
        raise ValueError(f"unknown format {fmt!r}; one of {', '.join(FORMATS)}")
    target = path.with_suffix("." + extension(fmt))
    target.parent.mkdir(parents=True, exist_ok=True)

    # MP3 out of MP3 takes the original tag wholesale rather than letting
    # ffmpeg write a new one, so ffmpeg is told to write none.
    carry_whole_tag = (fmt == "mp3" and source is not None
                       and source.suffix.lower() == ".mp3")

    command = ["ffmpeg", "-nostdin", "-v", "error", "-y",
               "-f", "f32le", "-ar", str(rate), "-ac", "2", "-i", "-"]
    if carry_whole_tag:
        command += ["-map", "0:a", "-map_metadata", "-1",
                    "-write_id3v1", "0", "-id3v2_version", "0"]
    elif source is not None:
        # `1:v?` is the artwork, optional -- without the question mark a
        # track with no cover art fails the whole encode.
        command += ["-i", str(source), "-map", "0:a", "-map", "1:v?",
                    "-map_metadata", "1"]
    else:
        command += ["-map", "0:a"]
    command += _encoder_arguments(fmt)
    if not carry_whole_tag and source is not None:
        command += ["-c:v", "copy", "-disposition:v", "attached_pic"]
    command += [str(target)]

    result = subprocess.run(command, input=np.clip(x, -1.0, 1.0)
                            .astype("<f4").tobytes(), capture_output=True)
    if result.returncode != 0:
        message = result.stderr.decode(errors="replace").strip()[:300]
        if fmt == "mp3" and "libmp3lame" in message:
            raise RuntimeError(
                "this ffmpeg was built without libmp3lame, so it cannot "
                "write MP3. Choose FLAC or AAC. " + message)
        raise RuntimeError(message)
    if carry_whole_tag and source is not None:
        carry_id3v2(source, target)
    return target


def id3v2_length(header: bytes) -> int:
    """Bytes from the start of the file to the end of an ID3v2 tag.

    The size is syncsafe -- seven bits per byte, so the length can never
    contain a run that looks like a frame sync. Reading it as a plain
    integer is the classic way to land in the middle of the audio.
    """
    if len(header) < 10 or header[:3] != b"ID3":
        return 0
    size = ((header[6] & 0x7F) << 21 | (header[7] & 0x7F) << 14
            | (header[8] & 0x7F) << 7 | (header[9] & 0x7F))
    # Bit 4 of the flags is a footer, another ten bytes at the end.
    return 10 + size + (10 if header[5] & 0x10 else 0)


def carry_id3v2(source: Path, target: Path) -> bool:
    """Prepend the original's entire ID3v2 tag to the new file.

    The whole tag, not the GEOB frames alone. Picking frames out means
    re-encoding their sizes between ID3 versions, minding the
    unsynchronisation flag, and deciding what else is worth keeping --
    three chances to get it subtly wrong for no benefit. Copied whole,
    everything the original carried arrives intact: cues, beatgrid,
    artwork, comments, the lot. The bytes are never interpreted, so there
    is nothing to misunderstand.
    """
    with open(source, "rb") as handle:
        head = handle.read(10)
        length = id3v2_length(head)
        if length <= 10:
            return False
        handle.seek(0)
        tag = handle.read(length)
    if len(tag) != length:
        return False
    body = target.read_bytes()
    # Written whole rather than in place: a half-written file here is a
    # track that will not play.
    target.write_bytes(tag + body)
    return True
