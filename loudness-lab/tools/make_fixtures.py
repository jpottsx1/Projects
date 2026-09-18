#!/usr/bin/env python3
"""Generate a small synthetic 'library' with known low-end properties.

Each fixture is built to exhibit one thing the reports claim to detect --
missing sub, mono bass, congested low-mid, wide dynamics -- so the test suite
can check the detection rather than trusting it.

Usage: python3 tools/make_fixtures.py OUTPUT_DIR
"""

from __future__ import annotations

import subprocess
import sys
import wave
from pathlib import Path

import numpy as np
from scipy.signal import butter, sosfilt, sosfiltfilt

RATE = 48000
DURATION = 30.0
BPM = 120.0


def _noise(n: int, rng: np.random.Generator, sos) -> np.ndarray:
    return sosfilt(sos, rng.standard_normal(n)).astype(np.float64)


def build(seed: int, sub_hpf_hz: float | None, lowmid_boost_db: float,
          mono_below_hz: float | None, dynamic: str | None) -> np.ndarray:
    rng = np.random.default_rng(seed)
    n = int(DURATION * RATE)
    t = np.arange(n) / RATE

    # Kick: 55 Hz sine, exponentially decaying, on every beat.
    beat = 60.0 / BPM
    phase = np.mod(t, beat)
    kick = np.sin(2 * np.pi * 55 * phase) * np.exp(-phase * 28.0)

    # Bass: 80 Hz, changing note every bar.
    bar = np.floor(t / (beat * 4)).astype(int)
    freq = np.array([80.0, 90.0, 71.0, 80.0])[bar % 4]
    bass = 0.5 * np.sin(2 * np.pi * np.cumsum(freq) / RATE)

    mids = _noise(n, rng, butter(4, [200, 2000], btype="band", fs=RATE, output="sos"))
    highs = _noise(n, rng, butter(4, 3000, btype="high", fs=RATE, output="sos"))
    # Decorrelated second channel, so side energy exists above the bass.
    mids_r = _noise(n, rng, butter(4, [200, 2000], btype="band", fs=RATE, output="sos"))
    highs_r = _noise(n, rng, butter(4, 3000, btype="high", fs=RATE, output="sos"))

    # Independent low-frequency content per channel, so every fixture starts
    # with genuinely wide bass. The mono_below filter below is then what
    # distinguishes a record cut for vinyl from one that was not.
    low_sos = butter(4, 200, btype="low", fs=RATE, output="sos")
    wide_l = _noise(n, rng, low_sos)
    wide_r = _noise(n, rng, low_sos)

    left = 0.9 * kick + bass + 0.30 * wide_l + 0.35 * mids + 0.12 * highs
    right = 0.9 * kick + bass + 0.30 * wide_r + 0.35 * mids_r + 0.12 * highs_r
    x = np.stack([left, right], axis=1)

    if lowmid_boost_db:
        sos = butter(2, [180, 400], btype="band", fs=RATE, output="sos")
        x = x + sosfiltfilt(sos, x, axis=0) * (10 ** (lowmid_boost_db / 20) - 1)

    if mono_below_hz:
        # Zero-phase so that (x - low) is a genuine complementary high-pass;
        # a one-pass filter would leave a phase-shifted stereo residue behind
        # and the bass would not actually end up mono.
        sos = butter(4, mono_below_hz, btype="low", fs=RATE, output="sos")
        low = sosfiltfilt(sos, x, axis=0)
        x = (x - low) + low.mean(axis=1, keepdims=True)

    if sub_hpf_hz:
        x = sosfilt(butter(4, sub_hpf_hz, btype="high", fs=RATE, output="sos"),
                    x, axis=0)

    if dynamic == "wide":
        # Quiet first third, loud remainder. Note this does NOT make the
        # estimators disagree: a section 20 dB down falls outside BS.1770's
        # -10 LU relative gate, so integrated loudness ignores it too.
        envelope = np.where(t < DURATION / 3, 0.10, 1.0)
    elif dynamic == "moderate":
        # Alternating 8-bar sections 6 dB apart. This is the case that
        # separates the estimators, because every section stays inside the
        # gate and so drags the integrated figure down.
        section = np.floor(t / (beat * 32)).astype(int)
        envelope = np.where(section % 2 == 0, 0.5, 1.0)
    else:
        envelope = None
    if envelope is not None:
        smooth = np.convolve(envelope, np.ones(4800) / 4800, mode="same")
        x = x * smooth[:, None]

    peak = np.abs(x).max()
    return (x / peak * 0.89) if peak > 0 else x


FIXTURES = (
    # name,                year, seed, sub_hpf, lowmid, mono_below, dynamic
    ("vinyl_1977_disco",   1977, 1, 42.0,  5.0, 250.0, None),
    ("vinyl_1978_groove",  1978, 8, 42.0,  5.0, 250.0, "moderate"),
    ("vinyl_1979_live",    1979, 2, 45.0,  6.0, 250.0, "wide"),
    ("eighties_1985",      1985, 3, 38.0,  4.0, 200.0, "moderate"),
    ("nineties_1995",      1995, 4, 30.0,  2.0, 120.0, None),
    ("modern_2015_edm",    2015, 5, None,  0.0, None,  None),
    ("modern_2019_house",  2019, 6, None,  0.0, None,  None),
    ("modern_2021_techno", 2021, 7, None, -1.0, None,  None),
)


def write_wav(path: Path, x: np.ndarray) -> None:
    pcm = np.clip(x, -1.0, 1.0)
    data = (pcm * 32767.0).astype("<i2")
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes(data.tobytes())


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for name, year, seed, hpf, lowmid, mono, dynamic in FIXTURES:
        audio = build(seed, hpf, lowmid, mono, dynamic)
        wav = out / f"{name}.wav"
        write_wav(wav, audio)
        mp3 = out / f"{name}.mp3"
        subprocess.run(
            ["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", str(wav),
             "-codec:a", "libmp3lame", "-b:a", "320k",
             "-metadata", f"title={name}",
             "-metadata", "artist=Fixture",
             "-metadata", f"date={year}",
             "-metadata", "genre=Dance",
             "-metadata", "TBPM=120",
             str(mp3)],
            check=True,
        )
        wav.unlink()
        print(f"  {mp3.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
