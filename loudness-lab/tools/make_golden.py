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
import subprocess
import sys
from pathlib import Path

import numpy as np
from scipy.signal import butter, find_peaks, sosfilt, sosfiltfilt

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from loudnesslab import bs1770, decode, declip, mp3gain, spectrum, subbass  # noqa: E402
from loudnesslab.report import _folder_labels  # noqa: E402

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
    # Same shape as the fixtures above, tail included. It is tempting to
    # leave the tail off -- the head already proves the generator agrees --
    # but the groove is the one fixture whose END carries a kick, and the
    # two sides decode this into the SAME Swift type. A section that is
    # nearly the right shape does not fail its own test; it fails the whole
    # file's decode, somewhere else entirely.
    golden["grooves"] = {
        f"{bpm:.0f}": {"frames": int(groove(bpm).shape[0]),
                       "head": rounded(groove(bpm)[:8, 0]),
                       "tail": rounded(groove(bpm)[-4:, 1]),
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

    # --- the year rule, which is pure logic and must match exactly ---
    golden["yearFromText"] = {
        text: (lambda m: int(m.group(0)) if m else None)(decode._YEAR.search(text))
        for text in ("1981", "1981-06-01", "recorded 1979, issued 2003", "2011",
                     "99", "1899", "2100", "", "abc", "20111", "01981", "12019")
    }
    golden["yearFromTags"] = []
    for tags in (
        {"date": "2011", "originaldate": "1981"},
        {"date": "2011"},
        {"tdrc": "1999-08"},
        {"tory": "1978", "year": "2003"},
        {"album": "no year here"},
        {"originalyear": "not a year", "date": "1984"},
    ):
        year, original = decode._year(tags)
        golden["yearFromTags"].append(
            {"tags": tags, "year": year, "isOriginal": original})

    # --- decode, which has no reference to match, only a second opinion ---
    # The Python shells out to ffmpeg; the app uses Apple's decoder. They do
    # not agree sample for sample and may trim encoder priming differently,
    # so this records what ffmpeg gives and the Swift test reports how far
    # off it lands rather than pretending the two are interchangeable.
    golden["decode"] = {}
    for path in sorted((OUT / "mp3").glob("*.mp3")):
        audio = decode.decode(path)
        measured = bs1770.measure(audio)
        golden["decode"][path.name] = {
            "frames": int(audio.shape[0]),
            "seconds": rounded(audio.shape[0] / decode.TARGET_RATE, 4),
            "lufs_i": rounded(measured["lufs_i"]),
            "s_p95": rounded(measured["s_p95"]),
            "true_peak_dbtp": rounded(measured["true_peak_dbtp"]),
            "sample_peak_dbfs": rounded(measured["sample_peak_dbfs"]),
        }

    # --- a database the Python wrote, which the Swift has to be able to read ---
    # The compatibility claim is only worth making if it is demonstrated, and
    # it cannot be demonstrated from one side. So the Python writes a real
    # scan here and the Swift test opens that exact file.
    from loudnesslab import db as dblib
    database = OUT / "library.db"
    for suffix in ("", "-wal", "-shm"):
        (OUT / f"library.db{suffix}").unlink(missing_ok=True)
    conn = dblib.connect(database)
    expected_tracks = []
    for index, path in enumerate(sorted((OUT / "mp3").glob("*.mp3"))):
        audio = decode.decode(path)
        measured = bs1770.measure(audio)
        measured.pop("_short_term")
        stat = path.stat()
        dblib.store(conn, {
            "track": {"path": str(path), "size_bytes": stat.st_size,
                      "mtime_ns": stat.st_mtime_ns, "analyzed_at": "2026-01-01T00:00:00",
                      "tool_version": "0.1.0", "status": "ok", "error": None,
                      "codec": "mp3", "source_rate": 44100, "source_channels": 2,
                      "bitrate_kbps": 128.0, "duration_s": 4.5,
                      "artist": f"Artist {index}", "title": f"Title {index}",
                      "album": "Fixtures", "genre": "Disco",
                      "year": 1978 + index, "year_is_original": 1,
                      "bpm": 120.0 + index, "musical_key": "8A"},
            "loudness": measured,
            "bands": spectrum.analyse(audio, RATE),
        })
        expected_tracks.append({
            "path": str(path.name), "artist": f"Artist {index}",
            "title": f"Title {index}", "year": 1978 + index,
            "lufs_i": rounded(measured["lufs_i"]),
            "s_p95": rounded(measured["s_p95"]),
        })
    # Checkpointed into the main file, so the fixture is one file and not
    # three, and does not depend on a journal a fresh checkout would not have.
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.commit()
    conn.close()
    for suffix in ("-wal", "-shm"):
        (OUT / f"library.db{suffix}").unlink(missing_ok=True)
    # The per-track sizing, which decides how much every track actually gets.
    conn = dblib.connect(database)
    from loudnesslab import report as reportlib
    bands, shape = reportlib._band_matrix(conn, "shape_db", group_by="folder")
    folder = sorted(shape)[0]
    curve = {b: float(np.median(shape[folder][b]))
             for b in reportlib.LOW_SHAPE_BANDS if shape[folder].get(b)}
    shortfalls = []
    for path in sorted((OUT / "mp3").glob("*.mp3")):
        rows = conn.execute(
            "SELECT b.band_hz, b.shape_db FROM bands b JOIN tracks t "
            "ON t.id = b.track_id WHERE t.path = ? AND b.band_hz IN "
            f"({', '.join(str(b) for b in reportlib.LOW_SHAPE_BANDS)})",
            (str(path),)).fetchall()
        deficits = [curve[r["band_hz"]] - r["shape_db"] for r in rows
                    if curve.get(r["band_hz"]) is not None and r["shape_db"] is not None]
        mean = float(np.mean(deficits)) if deficits else None
        shortfalls.append({"path": path.name, "meanDeficitDB": rounded(mean)})
    conn.close()

    golden["library"] = {
        "schemaVersion": dblib.SCHEMA_VERSION,
        "tracks": expected_tracks,
        "lowBands": len([c for c in spectrum.BAND_CENTRES
                         if c <= spectrum.LOW_BAND_MAX_HZ]),
        "lowShapeBands": [float(b) for b in reportlib.LOW_SHAPE_BANDS],
        "referenceFolder": folder,
        "curve": {str(k): rounded(v) for k, v in sorted(curve.items())},
        "shortfalls": shortfalls,
    }

    # --- folder labelling, where a wrong answer merges two corpora ---
    # The cases that matter are the ones the bare parent name gets wrong.
    golden["folderLabels"] = []
    for case in (
        # Two compilations, each with a CD1: the thing the bare name merges.
        ["/m/Now Yearbook 99 (2026)/CD1/a.mp3", "/m/Now Yearbook 99 (2026)/CD1/b.mp3",
         "/m/NOW 100 Hits Party/CD1/c.mp3"],
        # One folder only: the label is its own name, not an empty string.
        ["/m/Disco/a.mp3", "/m/Disco/b.mp3"],
        # Sibling folders under a common root.
        ["/m/Disco/a.mp3", "/m/Eighties/b.mp3"],
        # A prefix that is not a path prefix: /m/Disco vs /m/Disco Classics.
        ["/m/Disco/a.mp3", "/m/Disco Classics/b.mp3"],
        # Nested, different depths.
        ["/m/A/B/C/a.mp3", "/m/A/b.mp3"],
        # Files sitting directly in the common root.
        ["/m/a.mp3", "/m/b.mp3"],
        [],
    ):
        golden["folderLabels"].append(
            {"paths": case, "labels": _folder_labels(case)})

    write_filter_bank()

    path = OUT / "golden.json"
    path.write_text(json.dumps(golden, indent=1, sort_keys=True))
    print(f"wrote {path} ({path.stat().st_size / 1024:.0f} kB)")
    print(f"  {len(golden['filters'])} filters, "
          f"{len(golden['measure'])} measurements, "
          f"{len(golden['declip'])} de-clip cases")
    warn_about_ignored_outputs()
    # Type-check what was just written against the structs that have to
    # decode it. There is no Swift toolchain here, so without this a wrong
    # key is only found on a Mac, one key per build.
    import check_golden
    if check_golden.main() != 0:
        return 1
    return 0


def warn_about_ignored_outputs() -> None:
    """Say so when git will quietly drop a fixture this just wrote.

    `library.db` spent a while being generated here, passing here, and
    absent on every other machine, because `*.db` in .gitignore is aimed at
    scans of somebody's music library and caught a 57 kB fixture on the way
    past. Nothing failed: the file existed locally, so the local run was
    green, and the remote run reported a missing resource with no hint as
    to why it was missing. A generator that knows what it wrote is the
    cheapest place to notice.
    """
    outputs = sorted(
        p for p in OUT.rglob("*")
        if p.is_file() and not p.name.endswith(("-wal", "-shm"))
    )
    if not outputs:
        return
    try:
        result = subprocess.run(
            ["git", "check-ignore", "--no-index", *[str(p) for p in outputs]],
            capture_output=True, text=True, cwd=Path(__file__).resolve().parents[1],
        )
    except (OSError, subprocess.SubprocessError):
        return  # no git, or no repository -- not this script's problem
    ignored = [line for line in result.stdout.splitlines() if line.strip()]
    if not ignored:
        return
    print("\nWARNING: git is ignoring fixtures this just wrote. They will")
    print("not reach any other machine, and the Swift tests that open them")
    print("will fail there with a missing resource:")
    for line in ignored:
        print(f"  {line}")
    print("Add a negation to .gitignore, e.g. !path/to/the/fixture\n")




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
