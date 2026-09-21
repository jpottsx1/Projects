#!/usr/bin/env python3
"""Emit what the Swift port has to reproduce.

The Python in this project is the reference: BS.1770 validated against
ffmpeg's ebur128, a de-clipper scored against known-clean audio, constants
fitted to measured corpora. A rewrite in another language throws all of that
away unless the rewrite is held to the same numbers, so this writes those
numbers down.

Fixtures are DEFINED rather than shipped -- a formula and a named generator
that both languages implement, so the repository carries a few kilobytes of
expected values instead of megabytes of audio, and any disagreement about the
input shows up as a failing fixture test before it can be mistaken for a
failing DSP test.

Run after changing anything the Swift depends on:

    python3 tools/make_golden.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
from scipy.signal import butter, find_peaks, sosfilt, sosfiltfilt

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from loudnesslab import bs1770, declip, mp3gain, spectrum, subbass  # noqa: E402

RATE = 48000
OUT = Path(__file__).resolve().parents[1] / "macapp/Tests/LoudnessKitTests/Golden"

# Every filter the project builds, by the name the Swift will know it by.
# Shipping the coefficients rather than porting scipy's filter design removes
# an entire class of error: a Butterworth prototype, a frequency transform, a
# bilinear transform and scipy's own pole-zero pairing, none of which the app
# needs to be able to do at runtime because every frequency here is a constant.
FILTERS = {
    "subBand":      (4, [31.5, 63.0], "band"),
    "kickBand":     (4, [30.0, 100.0], "band"),
    "punchBand":    (4, [2000.0, 6000.0], "band"),
    "subFloor":     (2, 28.0, "high"),
    "subCeiling":   (4, 75.0, "low"),
    "envelope20":   (2, 20.0, "low"),
    "envelope200":  (2, 200.0, "low"),
    "envelope60":   (2, 60.0, "low"),
    "envelope3":    (2, 3.0, "low"),
}


def xorshift(seed: int, count: int) -> np.ndarray:
    """A PRNG simple enough to reimplement exactly, which numpy's is not.

    xorshift64*, taken to a double in [-1, 1). The point is not statistical
    quality -- it is that Swift and Python can be made to produce the same
    stream, so a fixture mismatch cannot be confused for a DSP mismatch.
    """
    mask = (1 << 64) - 1
    state = seed & mask
    out = np.empty(count, dtype=np.float64)
    for i in range(count):
        state ^= state >> 12
        state = (state ^ (state << 25)) & mask
        state ^= state >> 27
        value = (state * 0x2545F4914F6CDD1D) & mask
        out[i] = (value >> 11) / float(1 << 53) * 2.0 - 1.0
    return out


TONES = [(55.0, 0.45, 0.0), (110.0, 0.30, 0.7), (330.0, 0.18, 1.9),
         (1480.0, 0.10, 2.6), (5200.0, 0.06, 0.4)]


def fixture(kind: str, seconds: float = 3.0) -> np.ndarray:
    """The shared fixtures, by name. Both languages build these identically."""
    n = int(seconds * RATE)
    t = np.arange(n, dtype=np.float64) / RATE
    if kind == "tones":
        mono = sum(a * np.sin(2 * np.pi * f * t + p) for f, a, p in TONES)
        stereo = np.column_stack([mono, mono * 0.8])
    elif kind == "programme":
        mono = sum(a * np.sin(2 * np.pi * f * t + p) for f, a, p in TONES)
        mono = mono * (0.7 + 0.3 * np.sin(2 * np.pi * 0.6 * t))
        noise = xorshift(0x2BAD, n) * 0.02
        stereo = np.column_stack([mono + noise, mono * 0.9 - noise])
    elif kind == "noise":
        stereo = np.column_stack([xorshift(1, n), xorshift(2, n)]) * 0.35
    elif kind == "quiet":
        mono = 0.001 * np.sin(2 * np.pi * 220.0 * t)
        stereo = np.column_stack([mono, mono])
    else:
        raise ValueError(kind)
    return stereo


def groove(bpm: float, seconds: float = 8.0) -> np.ndarray:
    """Four-on-the-floor over a bassline: what the kick detector is for.

    The bassline changes note on every beat deliberately -- that is the thing
    a plain rising-edge detector kept calling a kick.
    """
    n = int(seconds * RATE)
    t = np.arange(n, dtype=np.float64) / RATE
    beat = 60.0 / bpm
    mix = np.zeros(n)
    steps = [0, 7, 0, 5, 0, 7, 3, 7]

    for index, onset in enumerate(np.arange(0.0, seconds, beat)):
        start = int(onset * RATE)
        span = min(int(0.2 * RATE), n - start)
        if span <= 0:
            break
        u = np.arange(span) / RATE
        sweep = 110.0 * np.exp(-u / 0.02) + 45.0
        mix[start:start + span] += (np.sin(2 * np.pi * np.cumsum(sweep) / RATE)
                                    * np.exp(-u / 0.08))
        mix[start:start + span] += xorshift(0x51DE + index, span) * np.exp(-u / 0.002) * 0.3

    for index, onset in enumerate(np.arange(0.0, seconds, beat / 2)):
        start = int(onset * RATE)
        span = min(int(beat / 2 * RATE * 0.9), n - start)
        if span <= 0:
            break
        u = np.arange(span) / RATE
        freq = 55.0 * 2 ** (steps[index % len(steps)] / 12.0)
        mix[start:start + span] += 0.5 * np.sin(2 * np.pi * freq * u) * np.exp(-u / 0.3)

    stereo = np.column_stack([mix, mix * 0.95])
    return stereo / np.abs(stereo).max() * 0.9


def clipped(kind: str, over_db: float, seconds: float = 3.0) -> np.ndarray:
    x = fixture(kind, seconds)
    x = x / np.abs(x).max() * 10 ** (over_db / 20)
    return np.clip(x, -1.0, 1.0)


def fnv1a(data: bytes) -> str:
    """Matches Checksum.fnv1a in the Swift. As a string, because JSON numbers
    lose the top bits of a 64-bit value once a parser reaches for a double."""
    mask = (1 << 64) - 1
    hashed = 0xCBF29CE484222325
    for byte in data:
        hashed = ((hashed ^ byte) * 0x100000001B3) & mask
    return str(hashed)


def rounded(value, places: int = 9):
    if isinstance(value, (list, tuple, np.ndarray)):
        return [rounded(v, places) for v in np.asarray(value).tolist()]
    if value is None:
        return None
    value = float(value)
    if not np.isfinite(value):
        return "-inf" if value < 0 else "inf"
    return round(value, places)


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    golden: dict = {"rate": RATE, "note": "generated by tools/make_golden.py"}

    # --- the fixtures themselves, so a mismatch is caught before the DSP ---
    golden["fixtures"] = {
        kind: {
            "frames": int(fixture(kind).shape[0]),
            "head": rounded(fixture(kind)[:8, 0]),
            "tail": rounded(fixture(kind)[-4:, 1]),
            "rms": rounded(np.sqrt(np.mean(fixture(kind) ** 2))),
            "peak": rounded(np.abs(fixture(kind)).max()),
        }
        for kind in ("tones", "programme", "noise", "quiet")
    }
    golden["grooves"] = {
        f"{bpm:.0f}": {"frames": int(groove(bpm).shape[0]),
                       "head": rounded(groove(bpm)[:8, 0]),
                       "rms": rounded(np.sqrt(np.mean(groove(bpm) ** 2))),
                       "peak": rounded(np.abs(groove(bpm)).max())}
        for bpm in (100.0, 124.0)
    }

    # --- filter coefficients, and what they do to a known signal ---
    golden["filters"] = {}
    signal = fixture("programme")[:, 0]
    for name, (order, cutoff, kind) in FILTERS.items():
        sos = butter(order, cutoff, btype=kind, fs=RATE, output="sos")
        golden["filters"][name] = {
            "order": order, "btype": kind,
            "cutoff": cutoff if isinstance(cutoff, list) else [cutoff],
            "sos": rounded(sos, 15),
            # Both directions matter and they are different code paths. The
            # zero-phase one is the one this project has been bitten by.
            "sosfilt": {
                "head": rounded(sosfilt(sos, signal)[:6], 12),
                "rms": rounded(np.sqrt(np.mean(sosfilt(sos, signal) ** 2)), 12),
            },
            "sosfiltfilt": {
                "head": rounded(sosfiltfilt(sos, signal)[:6], 12),
                "rms": rounded(np.sqrt(np.mean(sosfiltfilt(sos, signal) ** 2)), 12),
            },
        }

    # --- K-weighting, block loudness, the whole measurement ---
    golden["kWeighting"] = {}
    for kind in ("tones", "programme"):
        y = bs1770.k_weight(fixture(kind))
        golden["kWeighting"][kind] = {
            "head": rounded(y[:6, 0], 12),
            "rms": rounded(np.sqrt(np.mean(y ** 2)), 12),
        }

    golden["measure"] = {}
    for kind in ("tones", "programme", "noise", "quiet"):
        x = fixture(kind)
        result = bs1770.measure(x)
        short = result.pop("_short_term")
        golden["measure"][kind] = {
            **{key: rounded(value) for key, value in result.items()},
            "shortTermCount": int(short.size),
            "shortTermHead": rounded(short[:4]),
        }

    # --- de-clipping ---
    golden["declip"] = {}
    for over_db in (1.0, 3.0, 6.0):
        x = clipped("programme", over_db)
        restored, report = declip.restore(x, RATE)
        runs = declip.find_runs(x[:, 0].astype(np.float64))
        golden["declip"][f"programme+{over_db:.0f}dB"] = {
            "runs": int(report["runs"]),
            "restored": int(report["restored"]),
            "flattened": int(report["flattened"]),
            **{key: int(report[key]) for key in declip.REFUSALS},
            "liftDB": rounded(report["lift_db"]),
            "liftMaxDB": rounded(report["lift_max_db"]),
            "peakChangeDB": rounded(report["peak_change_db"]),
            "firstRuns": [[int(s), int(e), int(sign)] for s, e, sign in runs[:5]],
            "outputRMS": rounded(np.sqrt(np.mean(restored ** 2)), 12),
            "outputPeak": rounded(np.abs(restored).max(), 12),
        }

    # --- 1/3-octave spectrum ---
    # Note for whoever chases a small disagreement here: numpy's rfft on a
    # float32 frame returns complex64, so the Python does this FFT in SINGLE
    # precision while the Swift does it in double. Band levels differ by
    # around a millionth of a decibel, which is why these are compared loosely
    # and the Python rounds to three places on the way to the database anyway.
    golden["spectrum"] = {}
    for kind in ("tones", "programme"):
        rows = spectrum.analyse(fixture(kind, 4.0), RATE)
        golden["spectrum"][kind] = {
            "bands": len(rows),
            "rows": [{"band_hz": r["band_hz"], "ltas_db": r["ltas_db"],
                      "shape_db": r["shape_db"], "p10_db": r["p10_db"],
                      "p90_db": r["p90_db"], "side_mid_db": r["side_mid_db"]}
                     for r in rows],
        }

    # --- peak picking, which decides where every sub burst lands ---
    golden["findPeaks"] = []
    for seed in (11, 29, 71):
        values = np.abs(xorshift(seed, 400)) * 1.6
        for distance in (1, 5, 17):
            found, _ = find_peaks(values, height=0.8, distance=distance)
            golden["findPeaks"].append({
                "seed": seed, "distance": distance,
                "peaks": [int(p) for p in found],
            })

    # --- kick detection and the sub stage ---
    golden["subbass"] = {}
    for bpm in (100.0, 124.0):
        x = groove(bpm)
        kicks, strengths = subbass.detect_kicks(x, RATE)
        out, report = subbass.enhance(x, RATE, amount_db=5.0, punch_db=3.0)
        golden["subbass"][f"groove{bpm:.0f}"] = {
            "kicks": [int(k) for k in kicks],
            "strengths": rounded(strengths, 9),
            "lowBandActivityDB": rounded(subbass.low_band_activity(x, RATE)),
            "attackContrastDB": rounded(
                subbass.attack_contrast(x, RATE, kicks)),
            "appliedDB": rounded(report["applied_db"]),
            "punchDB": rounded(report["punch_db"]),
            "sustainTrimDB": rounded(report["sustain_trim_db"]),
            "bandLevelChangeDB": rounded(report["band_level_change_db"]),
            "safetyTrimDB": rounded(report["safety_trim_db"]),
            "polarityFlipped": bool(report["polarity_flipped"]),
            "outputRMS": rounded(np.sqrt(np.mean(out ** 2)), 12),
            "outputPeak": rounded(np.abs(out).max(), 12),
        }

    # --- clipping detection ---
    golden["countClipping"] = {
        f"programme+{over:.0f}dB": list(bs1770.count_clipping(clipped("programme", over)))
        for over in (0.0, 1.0, 3.0, 6.0)
    }

    # --- lossless MP3 gain ---
    # The fixtures are real files, because an MP3 cannot be defined by a
    # formula the way a sine can. They cover the paths that differ: MPEG-1
    # stereo and mono, MPEG-2 with one granule per frame, a CRC-protected
    # stream whose checksum has to be recomputed over the bytes we change,
    # and one carrying Serato GEOB frames that must come through untouched.
    golden["mp3"] = {}
    for path in sorted((OUT / "mp3").glob("*.mp3")):
        data = path.read_bytes()
        frames = mp3gain.parse_frames(data)
        bits = mp3gain.gain_bits(data, frames)
        gains = [mp3gain._u8_at(data, b) for b in bits]
        entry = {
            "frames": len(frames),
            "infoFrames": sum(1 for f in frames if f.is_info_frame),
            "crcFrames": sum(1 for f in frames if f.has_crc),
            "id3Bytes": mp3gain.skip_id3v2(data),
            "movable": len(bits),
            "firstGainBits": bits[:6],
            "firstGains": gains[:6],
            "lowestGain": min(gains), "highestGain": max(gains),
            "sourceFNV": fnv1a(data),
            "plans": {}, "applied": {},
        }
        for target in (-3.0, -6.0, 1.5, -100.0):
            result = mp3gain.plan(data, target)
            entry["plans"][f"{target:+.1f}"] = {
                "steps": result.steps, "appliedDB": rounded(result.applied_db),
                "granules": result.granules,
                "skippedGranules": result.skipped_granules,
                "protectedFrames": result.protected_frames,
                "clamped": bool(result.clamped),
                "crossingGranules": result.crossing_granules,
                "lowestGain": result.lowest_gain,
                "lowestCount": result.lowest_count,
                "headroomDownDB": rounded(result.headroom_down_db),
            }
        for steps in (-2, -1, 1):
            shifted, crossed = mp3gain.apply_to(data, steps)
            entry["applied"][str(steps)] = {
                "fnv": fnv1a(shifted),
                "crossed": len(crossed),
                "changedBytes": sum(1 for a, b in zip(data, shifted) if a != b),
                "sameLength": len(shifted) == len(data),
            }
        golden["mp3"][path.name] = entry

    write_filter_bank()

    path = OUT / "golden.json"
    path.write_text(json.dumps(golden, indent=1, sort_keys=True))
    print(f"wrote {path} ({path.stat().st_size / 1024:.0f} kB)")
    print(f"  {len(golden['filters'])} filters, "
          f"{len(golden['measure'])} measurements, "
          f"{len(golden['declip'])} de-clip cases")
    return 0




def write_filter_bank() -> None:
    """Emit the coefficients as Swift, rather than porting scipy's design."""
    lines = [
        "// Generated by tools/make_golden.py -- do not edit by hand.",
        "//",
        "// scipy designs these once, here, and the app only runs them. Every",
        "// frequency below is a constant in the Python, so nothing is lost by",
        "// fixing them at build time, and a Butterworth prototype, a frequency",
        "// transform, a bilinear transform and a pole-zero pairing all stop",
        "// being things that could be ported wrongly.",
        "//",
        "// Change a corner frequency in the Python and re-run the generator.",
        "",
        "import Foundation",
        "",
        "public enum FilterBank {",
        f"    public static let rate = {RATE}.0",
        "",
    ]
    for name, (order, cutoff, kind) in FILTERS.items():
        sos = butter(order, cutoff, btype=kind, fs=RATE, output="sos")
        corner = cutoff if isinstance(cutoff, list) else [cutoff]
        where = " to ".join(f"{c:g}" for c in corner)
        lines.append(f"    /// Butterworth order {order}, {kind}, {where} Hz.")
        lines.append(f"    public static let {name} = SOS([")
        for row in sos:
            lines.append("        [" + ", ".join(repr(float(v)) for v in row) + "],")
        lines.append("    ])")
        lines.append("")
    lines.append("}")
    path = (Path(__file__).resolve().parents[1]
            / "macapp/Sources/LoudnessKit/DSP/FilterBank.swift")
    path.write_text("\n".join(lines))
    print(f"wrote {path.name} ({len(FILTERS)} filters)")


if __name__ == "__main__":
    raise SystemExit(main())
