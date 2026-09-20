"""Lossless MP3 gain: rewrite the global_gain field instead of re-encoding.

Every MPEG-1/2 Layer III granule carries an 8-bit `global_gain` in its side
information, and the decoder scales that granule by 2^((global_gain-210)/4).
Subtracting 1 from every global_gain therefore attenuates the whole file by
exactly 2^(1/4), or 1.505 dB, and the audio data itself is never touched:
no decode, no re-encode, no generation loss, and the change is exactly
reversible by adding the step back.

The cost is quantisation -- level can only move in 1.5 dB steps. For a
library that needs a couple of dB of attenuation to sit level, that is a far
better trade than a second lossy generation.

Two properties this module guarantees, because the alternative is silently
damaging someone's records:

  * The ID3 region is never read or written. Serato keeps cue points,
    beatgrids and waveform overviews in GEOB frames there; only bytes inside
    audio frames are modified, so those survive byte-for-byte.

  * A step is applied uniformly to every granule or not at all. Clamping
    individual granules at the ends of the 0-255 range would alter the
    relative level of one part of a track against another, which is exactly
    the dynamics change this project exists to avoid.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

# 2^(1/4) expressed in dB: one global_gain step.
DB_PER_STEP = 20.0 * 0.25 * 0.3010299956639812 / 0.25  # = 20*log10(2)/4
DB_PER_STEP = 20.0 * 0.3010299956639812 / 4.0  # 1.50515 dB

GAIN_MIN, GAIN_MAX = 0, 255

_BITRATES_V1 = (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0)
_BITRATES_V2 = (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0)
_SAMPLE_RATES = {
    3: (44100, 48000, 32000),   # MPEG-1
    2: (22050, 24000, 16000),   # MPEG-2
    0: (11025, 12000, 8000),    # MPEG-2.5
}


class Mp3Error(RuntimeError):
    pass


@dataclass(frozen=True)
class Frame:
    offset: int          # byte offset of the frame header in the file
    length: int          # total frame length in bytes
    side_info_at: int    # byte offset of the side information
    gain_bits: tuple     # absolute bit offsets of each global_gain field
    has_crc: bool
    is_info_frame: bool  # Xing/Info/VBRI header frame, decodes to silence


def _bits_at(data, bit_offset: int, count: int) -> int:
    """Read `count` bits starting at an arbitrary bit offset (MSB first)."""
    value = 0
    for index in range(count):
        position = bit_offset + index
        value = (value << 1) | ((data[position >> 3] >> (7 - (position & 7))) & 1)
    return value


def _u8_at(data, bit_offset: int) -> int:
    """Read 8 bits starting at an arbitrary bit offset (MSB first)."""
    index, shift = bit_offset >> 3, bit_offset & 7
    if shift == 0:
        return data[index]
    window = (data[index] << 8) | data[index + 1]
    return (window >> (8 - shift)) & 0xFF


def _set_u8_at(data: bytearray, bit_offset: int, value: int) -> None:
    index, shift = bit_offset >> 3, bit_offset & 7
    if shift == 0:
        data[index] = value
        return
    window = (data[index] << 8) | data[index + 1]
    mask = 0xFF << (8 - shift)
    window = (window & ~mask) | (value << (8 - shift))
    data[index] = (window >> 8) & 0xFF
    data[index + 1] = window & 0xFF


def skip_id3v2(data) -> int:
    """Byte offset of the first thing after an ID3v2 tag."""
    if len(data) < 10 or data[:3] != b"ID3":
        return 0
    size = 0
    for byte in data[6:10]:          # syncsafe: 7 bits per byte
        size = (size << 7) | (byte & 0x7F)
    offset = 10 + size
    if data[5] & 0x10:               # footer present
        offset += 10
    return min(offset, len(data))


def parse_header(data, offset: int):
    """Decode a frame header, or return None if this is not a Layer III frame."""
    if offset + 4 > len(data):
        return None
    b0, b1, b2, b3 = data[offset:offset + 4]
    if b0 != 0xFF or (b1 & 0xE0) != 0xE0:
        return None
    version_bits = (b1 >> 3) & 0x03
    if version_bits == 1:            # reserved
        return None
    if (b1 >> 1) & 0x03 != 0x01:     # layer must be III
        return None
    has_crc = not (b1 & 0x01)

    bitrate_index = (b2 >> 4) & 0x0F
    sample_index = (b2 >> 2) & 0x03
    if bitrate_index in (0, 15) or sample_index == 3:
        return None                  # free-format or invalid
    padding = (b2 >> 1) & 0x01
    channel_mode = (b3 >> 6) & 0x03
    mono = channel_mode == 3

    is_v1 = version_bits == 3
    bitrate = (_BITRATES_V1 if is_v1 else _BITRATES_V2)[bitrate_index] * 1000
    sample_rate = _SAMPLE_RATES[version_bits][sample_index]

    if is_v1:
        length = (144 * bitrate) // sample_rate + padding
        side_info_size = 17 if mono else 32
        granules, block_bits = 2, 59
        header_bits = 9 + (5 if mono else 3) + (4 if mono else 8)
    else:
        length = (72 * bitrate) // sample_rate + padding
        side_info_size = 9 if mono else 17
        granules, block_bits = 1, 63
        header_bits = 8 + (1 if mono else 2)

    channels = 1 if mono else 2
    return {
        "length": length, "side_info_size": side_info_size,
        "granules": granules, "channels": channels, "block_bits": block_bits,
        "header_bits": header_bits, "has_crc": has_crc,
        "sample_rate": sample_rate, "bitrate": bitrate, "mono": mono,
    }


def _frame_from_header(data, offset: int, info: dict) -> Frame:
    side_info_at = offset + 4 + (2 if info["has_crc"] else 0)
    base_bit = side_info_at * 8 + info["header_bits"]
    gain_bits = tuple(
        base_bit + block * info["block_bits"] + 21   # global_gain sits at bit 21
        for block in range(info["granules"] * info["channels"])
    )
    payload = data[offset + 4: offset + 4 + info["side_info_size"] + 8]
    is_info = any(tag in payload for tag in (b"Xing", b"Info", b"VBRI"))
    return Frame(offset=offset, length=info["length"], side_info_at=side_info_at,
                 gain_bits=gain_bits, has_crc=info["has_crc"],
                 is_info_frame=is_info)


def parse_frames(data) -> list[Frame]:
    """Every Layer III audio frame in the file, in order.

    A candidate is accepted only when a second valid header follows it at the
    computed length, so ID3 text and album art cannot masquerade as audio.
    """
    frames: list[Frame] = []
    offset = skip_id3v2(data)
    limit = len(data)
    while offset + 4 <= limit:
        info = parse_header(data, offset)
        if info is None:
            offset += 1
            continue
        end = offset + info["length"]
        if end > limit:
            break
        following = parse_header(data, end)
        if following is None and end + 4 <= limit:
            offset += 1              # not really a frame; keep scanning
            continue
        frames.append(_frame_from_header(data, offset, info))
        offset = end
    return frames


def granule_has_data(data, gain_bit: int) -> bool:
    """False when this granule carries no spectral data at all.

    part2_3_length is the first 12 bits of the granule's side info block, and
    global_gain sits 21 bits in. A zero-length granule has nothing to scale,
    so the decoder outputs silence whatever its global_gain says -- which is
    why such granules can be left alone rather than counted against the
    file's headroom.

    The test is on part2_3_length rather than on how small global_gain is,
    because it does not change when we shift gains. A threshold on
    global_gain would move granules in and out of the excluded set between
    applying a step and reversing it, and the reversal would stop being
    byte-exact.
    """
    return _bits_at(data, gain_bit - 21, 12) != 0


def gain_bits(data, frames: list[Frame]) -> list[int]:
    """Bit offsets of every global_gain we are willing to move."""
    return [bit for frame in frames if not frame.is_info_frame
            for bit in frame.gain_bits if granule_has_data(data, bit)]


def read_gains(data, frames: list[Frame]) -> list[int]:
    return [_u8_at(data, bit) for bit in gain_bits(data, frames)]


def headroom(gains: list[int]) -> tuple[int, int]:
    """(most we may subtract, most we may add) without clamping any granule."""
    if not gains:
        return 0, 0
    return min(gains) - GAIN_MIN, GAIN_MAX - max(gains)


def steps_for_db(db: float) -> int:
    return int(round(db / DB_PER_STEP))


def crc16(payload: bytes) -> int:
    """MPEG audio frame CRC: x^16 + x^15 + x^2 + 1, seeded with 0xFFFF.

    Covers the last two header bytes plus the side information -- which is
    exactly what we modify, so a protected frame needs its CRC recomputed or
    a checking decoder will drop it.
    """
    crc = 0xFFFF
    for byte in payload:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x8005) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def frame_crc(data, frame: Frame, side_info_size: int) -> int:
    covered = bytes(data[frame.offset + 2: frame.offset + 4]) + bytes(
        data[frame.side_info_at: frame.side_info_at + side_info_size])
    return crc16(covered)


@dataclass(frozen=True)
class GainPlan:
    requested_db: float
    steps: int               # global_gain steps actually applicable
    applied_db: float        # steps * DB_PER_STEP
    granules: int            # granules carrying data, i.e. ones we would move
    skipped_granules: int    # empty granules, left alone
    protected_frames: int    # frames carrying a CRC that must be recomputed
    clamped: bool            # requested more than the file had headroom for
    lowest_gain: int         # the global_gain that limits attenuation
    lowest_count: int        # how many granules sit at it
    headroom_down_db: float  # most attenuation this file can take


def plan(data, target_db: float, max_steps: int | None = None) -> GainPlan:
    """Work out the uniform step this file can take toward `target_db`.

    `max_steps` is a hard ceiling on the result, used to keep true peak under
    a limit. It matters because rounding to the nearest 1.5 dB step can round
    UP: a gain capped at +0.9 dB would otherwise become +1.505 and overshoot
    the very ceiling that capped it. Callers pass a floored step count, and
    this never exceeds it.
    """
    frames = parse_frames(data)
    if not frames:
        raise Mp3Error("no MPEG Layer III frames found")
    gains = read_gains(data, frames)
    if not gains:
        raise Mp3Error("no audio granules found (header-only file?)")

    wanted = steps_for_db(target_db)
    if max_steps is not None:
        wanted = min(wanted, max_steps)
    down, up = headroom(gains)
    allowed = max(-down, min(up, wanted))
    lowest = min(gains)
    total_granules = sum(len(f.gain_bits) for f in frames if not f.is_info_frame)
    return GainPlan(
        requested_db=target_db,
        steps=allowed,
        applied_db=allowed * DB_PER_STEP,
        granules=len(gains),
        skipped_granules=total_granules - len(gains),
        protected_frames=sum(1 for f in frames if f.has_crc),
        clamped=allowed != wanted,
        lowest_gain=lowest,
        lowest_count=sum(1 for g in gains if g == lowest),
        headroom_down_db=-down * DB_PER_STEP,
    )


def apply_steps(data: bytes, steps: int) -> bytes:
    """Return a copy of `data` with every global_gain shifted by `steps`.

    Only bytes inside audio frames change. The ID3 region, album art and any
    Serato GEOB frames are copied through untouched.
    """
    out = bytearray(data)
    if steps == 0:
        return bytes(out)
    frames = parse_frames(out)
    movable = set(gain_bits(out, frames))
    for frame in frames:
        if frame.is_info_frame:
            continue
        touched = False
        for bit in frame.gain_bits:
            if bit not in movable:
                continue          # empty granule: silent either way, leave it
            value = _u8_at(out, bit) + steps
            if not GAIN_MIN <= value <= GAIN_MAX:
                raise Mp3Error(
                    f"global_gain {value} out of range at bit {bit}; "
                    "plan() should have prevented this")
            _set_u8_at(out, bit, value)
            touched = True
        if touched and frame.has_crc:
            info = parse_header(out, frame.offset)
            recomputed = frame_crc(out, frame, info["side_info_size"])
            out[frame.offset + 4] = (recomputed >> 8) & 0xFF
            out[frame.offset + 5] = recomputed & 0xFF
    return bytes(out)
