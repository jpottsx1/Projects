#!/usr/bin/env python3
"""Does a separated drum stem find kicks better than the mix does?

Builds synthetic tracks with known kick times and scores `detect_kicks`
three ways on each:

    mix       the full mix, which is what the sub stage reads today
    oracle    the true drum part, before mixing: a perfect separator, and
              so the best a stem could ever do
    <backend> the drum stem a real separator pulled out of the mix

The scenarios are the ones the mix detector should find hard, alongside
the one it was tuned on:

    groove    a bassline changing note on every beat -- the test fixture
              in tests/test_subbass.py, where the mix already scores well
    octave    a disco octave bass, plucked on every eighth note: a sharp
              attack in the kick's own band between every pair of kicks
    buried    a quiet kick under a loud sustained bass
    slap      a plucked bass on the sixteenths, with the kick at -6 dB

Synthetic tracks are a proxy. A separator is trained on recordings, and a
drum machine made of sines and noise is not one -- so a good score here
says the idea holds and the plumbing is right, not what a real record
will do. The kick times on a real record are not known, which is why the
synthetic ones are used at all.

And they turned out to be a weak proxy. Spleeter's precision on the octave
scenario moved from 0.44 to 0.85 when only the bass's timbre changed -- how
fast its upper harmonics die away -- so the scenarios say what a separator
CAN do and not what it will do on a record.

Which is what `--files` is for. A real record has no known kick times, but
four-on-the-floor has one kick per beat, and the BPM tag Serato wrote says
how many beats there are. So the tempo each detector implies -- from the
median gap between the kicks it found, which a breakdown does not skew --
should equal the tag. A detector firing on an octave bass reads double; one
missing kicks buried under a bassline reads half or reads noisy. Only
meaningful on four-on-the-floor material, which is most of this library.

    python3 tools/measure_stem_kicks.py                 # every backend installed
    python3 tools/measure_stem_kicks.py --backend none  # mix and oracle only
    python3 tools/measure_stem_kicks.py --files ~/Music/Disco --backend demucs
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np
from scipy.signal import butter, sosfilt

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from loudnesslab import stems, subbass  # noqa: E402

RATE = 48000
SCENARIOS = ("groove", "octave", "buried", "slap")


def _kick(n: int, rng) -> np.ndarray:
    d = np.arange(n) / RATE
    freq = 45 + 45 * np.exp(-d * 60)          # a kick's pitch drops
    return (np.sin(2 * np.pi * np.cumsum(freq) / RATE) * np.exp(-d * 22)
            + rng.standard_normal(n) * np.exp(-d * 420) * 0.35)


def _snare(n: int, rng) -> np.ndarray:
    d = np.arange(n) / RATE
    noise = sosfilt(butter(2, [1500, 9000], btype="band", fs=RATE, output="sos"),
                    rng.standard_normal(n))
    return (0.6 * np.sin(2 * np.pi * 190 * d) * np.exp(-d * 35)
            + 1.2 * noise * np.exp(-d * 25))


def _hat(n: int, rng) -> np.ndarray:
    d = np.arange(n) / RATE
    noise = sosfilt(butter(4, 7000, btype="high", fs=RATE, output="sos"),
                    rng.standard_normal(n))
    return noise * np.exp(-d * 90)


def _pluck(n: int, freq: float, decay: float) -> np.ndarray:
    """A bass note with an attack: a few harmonics, a fast filter-like
    brightness decay, and an amplitude decay. The attack is what matters --
    it is sharp, and it is in 30-100 Hz."""
    d = np.arange(n) / RATE
    tone = sum(np.sin(2 * np.pi * freq * k * d) / k
               * np.exp(-d * (8 + 30 * (k - 1))) for k in range(1, 6))
    attack = np.minimum(1.0, d / 0.002)
    return tone * np.exp(-d / decay) * attack


def _place(track: np.ndarray, onset_s: float, sound: np.ndarray) -> None:
    i = int(onset_s * RATE)
    m = min(sound.size, track.size - i)
    if m > 0:
        track[i:i + m] += sound[:m]


def programme(scenario: str, seconds: float = 30.0, bpm: float = 118.0,
              seed: int = 0) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """(mix, true drum part, kick times in seconds). Both arrays stereo."""
    n = int(seconds * RATE)
    rng = np.random.default_rng(seed)
    beat = 60.0 / bpm
    kick_gain = {"groove": 0.9, "octave": 0.9, "buried": 0.35, "slap": 0.45}[scenario]

    kick, snare, hats, bass = (np.zeros(n) for _ in range(4))
    truth = []
    for index, onset in enumerate(np.arange(0, seconds - 0.5, beat)):
        # A breakdown: no kick, which is where false positives show up.
        if 12.0 <= onset < 16.0:
            continue
        truth.append(onset)
        _place(kick, onset, _kick(int(0.3 * RATE), rng) * kick_gain)
        if index % 2 == 1:
            _place(snare, onset, _snare(int(0.25 * RATE), rng) * 0.35)
    for onset in np.arange(beat / 2, seconds - 0.5, beat):
        _place(hats, onset, _hat(int(0.08 * RATE), rng) * 0.25)

    roots = [41.2, 55.0, 49.0, 46.2]            # E1, A1, G1, F#1
    if scenario == "groove":
        t = np.arange(n) / RATE
        note = np.array([80.0, 90.0, 71.0, 107.0])[np.floor(t / beat).astype(int) % 4]
        bass = 0.55 * np.sin(2 * np.pi * np.cumsum(note) / RATE)
    elif scenario == "octave":
        # Root on the beat, octave on the off-beat: the off-beat pluck is
        # the one a mix detector has to reject.
        for step, onset in enumerate(np.arange(0, seconds - 0.5, beat / 2)):
            root = roots[int(onset / (4 * beat)) % 4]
            freq = root * (2 if step % 2 else 1)
            _place(bass, onset, 0.6 * _pluck(int(beat / 2 * RATE), freq, 0.12))
    elif scenario == "buried":
        t = np.arange(n) / RATE
        root = np.array(roots)[np.floor(t / (4 * beat)).astype(int) % 4]
        bass = 0.8 * np.sin(2 * np.pi * np.cumsum(root) / RATE)
        bass += 0.3 * np.sin(2 * np.pi * np.cumsum(root * 2) / RATE)
    elif scenario == "slap":
        pattern = [1, 0, 1, 1, 0, 1, 1, 0]      # a busy sixteenth figure
        for step, onset in enumerate(np.arange(0, seconds - 0.5, beat / 4)):
            if pattern[step % 8]:
                root = roots[int(onset / (4 * beat)) % 4]
                _place(bass, onset, 0.5 * _pluck(int(beat / 4 * RATE), root, 0.06))
    else:
        raise ValueError(scenario)

    chords = sosfilt(butter(4, [300, 4000], btype="band", fs=RATE, output="sos"),
                     rng.standard_normal(n)) * 0.15
    drums = kick + snare + hats
    mix = drums + bass + chords + 0.01 * rng.standard_normal(n)
    scale = 0.8 / np.abs(mix).max()
    stereo = lambda y: np.stack([y, y], axis=1).astype(np.float32) * scale  # noqa: E731
    return stereo(mix), stereo(drums), np.array(truth)


def _thump_snare(n: int, rng) -> np.ndarray:
    """A LinnDrum-style snare: noise, plus a body that starts near 180 Hz and
    falls -- which is what puts it in the kick detector's band."""
    d = np.arange(n) / RATE
    body = np.sin(2 * np.pi * np.cumsum(120 + 70 * np.exp(-d * 40)) / RATE)
    noise = sosfilt(butter(2, [1200, 9000], btype="band", fs=RATE, output="sos"),
                    rng.standard_normal(n))
    return 0.9 * body * np.exp(-d * 18) + 0.8 * noise * np.exp(-d * 22)


def _clap(n: int, rng) -> np.ndarray:
    """An 808 clap: three quick noise bursts and a tail, with low-mid body."""
    d = np.arange(n) / RATE
    env = sum(np.exp(-np.clip(d - t, 0, None) * 300) * (d >= t)
              for t in (0.0, 0.011, 0.022)) + 0.6 * np.exp(-d * 15) * (d >= 0.033)
    noise = sosfilt(butter(2, [150, 4000], btype="band", fs=RATE, output="sos"),
                    rng.standard_normal(n))
    return noise * env


def _tom(n: int, freq: float) -> np.ndarray:
    d = np.arange(n) / RATE
    f = freq * (1 + 0.3 * np.exp(-d * 30))
    return (np.sin(2 * np.pi * np.cumsum(f) / RATE)
            + 0.35 * np.sin(4 * np.pi * np.cumsum(f) / RATE)) * np.exp(-d * 9)


def _scratch(n: int, rng) -> np.ndarray:
    """A record scratch: a sawtooth-rich tone whose pitch swings fast, from
    the low end up, with a hard start."""
    d = np.arange(n) / RATE
    f = 90 + 500 * np.abs(np.sin(2 * np.pi * 7 * d))
    phase = np.cumsum(f) / RATE
    saw = 2 * (phase % 1.0) - 1
    return saw * np.minimum(1.0, d / 0.002) * np.exp(-d * 6)


def backbeat(seconds: float = 30.0, bpm: float = 104.0, seed: int = 0,
             drift: float = 0.0, breakdown: tuple[float, float] | None = None
             ) -> tuple[np.ndarray, np.ndarray, dict]:
    """(drum part, kick times, other hits by kind): the pieces that stopped
    four tracks in the first real run. Kicks on 1 and 3 and a syncopated
    kick on the "and" of 2 every other bar; a snare with a low thump on 2
    and 4, and a clap on 4; a tom fill ending every fourth bar; and two
    scratches every four bars, off the beat. `drift` is a live drummer's
    tempo wander, as a fraction (0.015 swings 1.5% either way).
    `breakdown` (start, end) in seconds drops the kicks there and keeps the
    rest of the kit: snare, clap, toms, hats.

    The drum part only -- this is what a separator hands the detector.
    """
    n = int(seconds * RATE)
    rng = np.random.default_rng(seed)
    track = np.zeros(n)
    # Beat times, with the tempo wandering slowly if asked.
    beats, t = [], 0.0
    while t < seconds - 0.5:
        beats.append(t)
        t += 60.0 / (bpm * (1 + drift * np.sin(2 * np.pi * t / 17.0)))
    beats = np.array(beats)
    truth, other = [], {"snare": [], "clap": [], "tom": [], "scratch": []}
    for i, b in enumerate(beats):
        bar, beat = divmod(i, 4)
        nxt = beats[i + 1] if i + 1 < beats.size else b + 60 / bpm
        silent = breakdown is not None and breakdown[0] <= b < breakdown[1]
        if beat in (0, 2) and not (bar % 4 == 3 and beat == 2) and not silent:
            truth.append(b)
            _place(track, b, 0.9 * _kick(int(0.3 * RATE), rng))
        if beat == 1 and bar % 2 == 1 and not silent:
            s = b + (nxt - b) / 2                   # the "and" of 2
            truth.append(s)
            _place(track, s, 0.8 * _kick(int(0.3 * RATE), rng))
        if beat in (1, 3):
            other["snare"].append(b)
            _place(track, b, 0.55 * _thump_snare(int(0.3 * RATE), rng))
        if beat == 3:
            other["clap"].append(b)
            _place(track, b, 0.4 * _clap(int(0.25 * RATE), rng))
        if bar % 4 == 3 and beat == 2:              # fill: 3, e, &, a, 4-e
            for j, freq in enumerate((140, 120, 100, 85, 72, 64)):
                h = b + j * (nxt - b) / 4
                other["tom"].append(h)
                _place(track, h, 0.7 * _tom(int(0.35 * RATE), freq))
        if bar % 4 == 1 and beat in (0, 2):
            h = b + (nxt - b) * rng.choice([0.3, 0.4, 0.6, 0.7])
            other["scratch"].append(h)
            _place(track, h, 0.5 * _scratch(int(0.2 * RATE), rng))
    track += sosfilt(butter(4, 7000, btype="high", fs=RATE, output="sos"),
                     rng.standard_normal(n)) * 0.01
    track = track / np.abs(track).max() * 0.8
    return (np.stack([track, track], axis=1).astype(np.float32),
            np.array(truth), {k: np.array(v) for k, v in other.items()})


def score(detected: np.ndarray, truth: np.ndarray,
          tol: float = 0.03) -> tuple[float, float, float]:
    """(recall, precision, median |offset| in ms of the kicks found)."""
    found = np.asarray(detected) / RATE
    if found.size == 0 or truth.size == 0:
        return 0.0, 0.0, float("nan")
    offsets = [np.min(np.abs(found - x)) for x in truth]
    hits = [o for o in offsets if o <= tol]
    matched = sum(1 for x in found if np.any(np.abs(truth - x) <= tol))
    return (len(hits) / truth.size, matched / found.size,
            float(np.median(hits) * 1000) if hits else float("nan"))


def implied_bpm(kicks: np.ndarray, rate: int) -> float:
    """The tempo the median gap between detected kicks implies."""
    if kicks.size < 8:
        return float("nan")
    return 60.0 / float(np.median(np.diff(kicks) / rate))


def kick_profile(drums: np.ndarray, bass: np.ndarray, kicks: np.ndarray,
                 rate: int) -> tuple[float, str, str]:
    """(bass share, pitch, tail) of the low end at the kicks.

    Bass share: of the 30-90 Hz energy in the 60 ms after each kick, the
    part the separator put in the BASS stem. An 808 kick is a tuned, slowly
    decaying sine -- to a separator much like a bass note -- so a high
    share says the drum stem holds only its click. Measured on 1988 dance
    records it was 1-18% on eleven of twelve: Demucs keeps them in drums.

    Pitch and tail are `subbass.kick_voice` on drums and bass together,
    where the whole kick is -- what the sub stage tunes its burst to,
    measured there on the drum stem alone.
    """
    if kicks.size == 0:
        return float("nan"), "-", "-"
    from scipy.signal import sosfiltfilt
    d = drums.mean(axis=1).astype(np.float64)
    b = bass.mean(axis=1).astype(np.float64)
    low = butter(4, [30, 90], btype="band", fs=rate, output="sos")
    dl, bl = sosfiltfilt(low, d) ** 2, sosfiltfilt(low, b) ** 2
    span = int(0.06 * rate)
    e_d = sum(float(dl[k:k + span].sum()) for k in kicks)
    e_b = sum(float(bl[k:k + span].sum()) for k in kicks)
    share = e_b / (e_b + e_d) if e_b + e_d > 0 else float("nan")
    voice = subbass.kick_voice(d + b, rate, kicks)
    if voice is None:
        return share, "-", "-"
    return share, f"{voice[0]:.0f} Hz", f"{voice[1] * 1000:.0f} ms"


def _clock(samples: int, rate: int) -> str:
    seconds = samples / rate
    return f"{int(seconds // 60)}:{seconds % 60:04.1f}"


def gaps(drums: np.ndarray, found: np.ndarray, kept: np.ndarray, rate: int,
         bpm: float | None, length: int) -> list[str]:
    """Every stretch longer than two bars with no kept kick, and why the
    drum hits in it were dropped. The sub goes only where kicks are kept,
    so on a track given a large amount these are the places its low end
    falls back to the original -- which by ear can sound like the bottom
    falling out. Listed with times, to hold against what was heard."""
    if kept.size == 0:
        return ["no kicks kept anywhere"]
    span = int((8 * 60.0 / bpm if bpm else 4.0) * rate)
    heavy = (subbass._kick_level_db(drums, rate, found) >= subbass.MIN_KICK_LEVEL_DB
             if found.size else np.zeros(0, dtype=bool))
    kept_set = set(int(k) for k in kept)
    edges = np.concatenate([[0], kept, [length]])
    lines = []
    for a, b in zip(edges[:-1], edges[1:]):
        if b - a <= span:
            continue
        inside = (found > a) & (found < b)
        light = int((inside & ~heavy).sum())
        off = int(sum(1 for k, h in zip(found[inside], heavy[inside])
                      if h and int(k) not in kept_set))
        where = ("from the start" if a == 0 else
                 "to the end" if b == length else "")
        lines.append(f"no kick kept {_clock(a, rate)}-{_clock(b, rate)}"
                     + (f" ({where})" if where else "")
                     + f": {int(inside.sum())} drum hits there, {light} too light, "
                       f"{off} off the grid")
    return lines


def grid_counts(drums: np.ndarray, kicks: np.ndarray, rate: int,
                bpm: float | None, minutes: float) -> str:
    """Kicks a minute that a grid of quarters, eighths and sixteenths would
    keep, after the weight filter. Syncopated grooves -- an 808 tresillo,
    hip-hop -- put real kicks between the beats, which the quarter grid
    drops; finer grids keep them and let more fill notes through."""
    if not bpm or kicks.size < 8:
        return "grid -"
    heavy = kicks[subbass._kick_level_db(drums, rate, kicks)
                  >= subbass.MIN_KICK_LEVEL_DB]
    if heavy.size < 8:
        return "grid -"
    cells = []
    for sub, name in ((1, "1/4"), (2, "1/8"), (4, "1/16")):
        keep, firm = subbass._on_grid(heavy, rate, bpm, sub)
        cells.append(f"{name} {keep.sum() / minutes:.0f}/min ({firm:.2f})")
    return f"heavy hits {heavy.size / minutes:.0f}/min; on a grid of " + ", ".join(cells)


def measure_files(paths: list[Path], backends: list[str]) -> int:
    """Each real track, scored against its BPM tag. For every separator two
    columns: the stem as detected, and after `select_kicks` has dropped the
    hits too light to be a kick and the ones off the beat -- which is what
    the sub stage actually uses."""
    from loudnesslab import decode

    decode.require_tools()
    files = []
    for path in paths:
        files += decode.find_audio(path) if path.is_dir() else [path]
    columns = ["mix"] + [c for b in backends for c in (b, b + "+filter")]
    print(f"{'tagged':>6}  " + "  ".join(f"{name:>14}" for name in columns)
          + "   (implied BPM; kicks/min)  track")
    agree: dict[str, list[bool]] = {}
    for path in files:
        tagged = decode.probe(path).get("bpm")
        x = decode.decode(path, RATE)
        minutes = x.shape[0] / RATE / 60
        found = {"mix": subbass.detect_kicks(x, RATE)[0]}
        # What each column is scored against: the tag, or for a filtered
        # column the grid the filter settled on (double the tag, sometimes).
        against = {name: tagged for name in columns}
        notes = []
        for backend in backends:
            parts = stems.separate(x, RATE, backend)
            drums = parts["drums"]
            kicks, strengths = subbass.detect_kicks(x, RATE, drums)
            found[backend] = kicks
            kept, _, report = subbass.select_kicks(drums, RATE, kicks, strengths,
                                                   tagged)
            found[backend + "+filter"] = kept
            if report["grid_bpm"]:
                against[backend + "+filter"] = report["grid_bpm"] * report["grid_step"]
            step = {1: "quarters", 2: "eighths", 4: "sixteenths"}.get(
                report["grid_step"], "none fitted")
            notes.append(f"dropped {report['not_kick_shaped']} light, "
                         f"{report['off_grid']} off the grid; grid: {step} "
                         f"(fit {report['grid_coherence']}); kept kicks vary "
                         f"{report['strength_spread_db']} dB on the drum stem "
                         f"(10th to 90th percentile) -- the bursts no longer do")
            share, pitch, tail = kick_profile(drums, parts["bass"], kept, RATE)
            notes.append(f"kick low end {share:.0%} in the bass stem; "
                         f"drums and bass together ~{pitch}, tail {tail}")
            voice = subbass.kick_voice(drums, RATE, kept)
            if voice is not None:
                freq, decay = subbass.tuned_burst(*voice)
                notes.append(f"on the drum stem the kick is {voice[0]:.0f} Hz, "
                             f"{voice[1] * 1000:.0f} ms, so the sub is "
                             f"{freq:.0f} Hz, {decay * 1000:.0f} ms (was "
                             f"{subbass.DEFAULT_FREQ_HZ:.0f} Hz, "
                             f"{subbass.DEFAULT_DECAY_S * 1000:.0f} ms)")
            notes.append(grid_counts(drums, kicks, RATE, tagged, minutes))
            notes.extend(gaps(drums, kicks, kept, RATE, tagged, x.shape[0]))
        cells = []
        for name in columns:
            kicks = found[name]
            bpm = implied_bpm(kicks, RATE)
            cells.append(f"{bpm:>6.1f};{kicks.size / minutes:>4.0f}")
            if tagged:
                target = against[name]
                ok = any(abs(bpm - target * m) <= 0.03 * target * m
                         for m in ((1.0,) if "+filter" not in name
                                   else (1.0, 0.5, 0.25)))
                agree.setdefault(name, []).append(ok)
        label = f"{tagged:>6.1f}" if tagged else f"{'-':>6}"
        print(f"{label}  " + "  ".join(f"{c:>14}" for c in cells)
              + f"   {path.name}"
              + "".join(f"\n        {note}" for note in notes))
    if agree:
        print("\nimplied tempo within 3% of the tag (after the filter: of "
              "the grid it used, 1x, 1/2 or 1/4 -- kicks on 1 and 3, or once "
              "a bar, are still kicks):")
        for name, hits in agree.items():
            print(f"  {name:<16} {sum(hits)} of {len(hits)}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--backend", default="all",
                        help="demucs, spleeter, all (every installed one) or none")
    parser.add_argument("--seeds", type=int, default=2)
    parser.add_argument("--files", nargs="+", type=Path,
                        help="real tracks or folders, scored against their BPM tag")
    args = parser.parse_args()

    backends = (stems.available() if args.backend == "all"
                else [] if args.backend == "none" else [args.backend])
    if args.files:
        return measure_files(args.files, backends)
    print(f"backends: {', '.join(backends) or 'none'}\n")
    print(f"{'scenario':<8} {'seed':>4}  {'source':<9} {'recall':>6} "
          f"{'prec':>6} {'offset':>7}  kicks")

    totals: dict[str, list[tuple[float, float]]] = {}
    for scenario in SCENARIOS:
        for seed in range(args.seeds):
            mix, drums, truth = programme(scenario, seed=seed)
            sources = {"mix": None, "oracle": drums}
            for backend in backends:
                started = time.monotonic()
                sources[backend] = stems.separate(mix, RATE, backend)["drums"]
                sources[backend + "_s"] = time.monotonic() - started
            for name, stem in sources.items():
                if name.endswith("_s"):
                    continue
                kicks, _ = subbass.detect_kicks(mix, RATE, stem)
                recall, precision, offset = score(kicks, truth)
                totals.setdefault(name, []).append((recall, precision))
                took = (f"  ({sources[name + '_s']:.1f} s to separate)"
                        if name + "_s" in sources else "")
                print(f"{scenario:<8} {seed:>4}  {name:<9} {recall:>6.2f} "
                      f"{precision:>6.2f} {offset:>5.1f}ms  "
                      f"{kicks.size:>3}/{truth.size}{took}")
        print()

    print("mean over every scenario and seed:")
    for name, rows in totals.items():
        recall, precision = np.mean(rows, axis=0)
        print(f"  {name:<9} recall {recall:.2f}  precision {precision:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
