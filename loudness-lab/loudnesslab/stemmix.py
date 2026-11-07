"""The stem mix: four stems, the sub and the air, heard live before anything
is written.

Everywhere else here a stem only FINDS things (stems.py): the kicks the sub
goes under, the voices air follows. This is the one place the stems are
heard. The track is split into drums, bass, other and vocals; the app plays
them together with the sub and the air as separate layers, and every fader
is a gain on a buffer it already holds -- no re-render while a slider moves.
When the mix is right, Commit runs the ordinary processing command for that
track with the choice attached, and this module builds the audio from the
same layers with the same gains. What was heard is what is written.

    out = residual + sum(level(stem) * stem)        the four stem faders
        + tone_gain(sub) * sub_tone + kick_gain(sub) * sub_kick
        + air_gain(air) * air

- `residual` is the track as the chain had it just before the sub (de-
  clipped, ranged, shaped, mud and body as the settings ask), minus the four
  stems. A separation never sums back exactly; the residual carries the
  difference, so with every fader at 0 dB the mix IS that track, bit for
  bit, not the separator's idea of it.
- `sub_tone`, `sub_kick` are `subbass.sub_layers`: what `enhance` adds,
  split so each part's gain is a function of the amount alone.
- `air` is the exciter's harmonics (`air._air_plan`), guided where the
  settings ask for the guide.

The gains are solved by the stage's own quadratic (`gain_from_stats`) from
sums kept in the bundle's mix.json, so the app sizes a slider exactly as
the stage would without the audio. Amounts are against the track as it
came into the sub, as a processing run sizes them: Bass +5 means the 31.5-63
Hz octave five dB above where the track had it. The stem faders then sit on
top.

Two things a run does that the stem mix does not, because neither is a gain
on a layer: punch (`shape_attacks`) and the sub's safety trim. The trim is
a level change the levelling that follows makes anyway; punch is left to a
processing run. Levelling to the target still happens at the end, on Commit,
as it does for every finished track.

A bundle is scratch: four stereo stems and up to four layers more, float32
at 48 kHz -- about 115 MB a layer for five minutes. The app removes it on
Cancel and after Commit.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
from scipy.io import wavfile

from . import air, decode, stems, subbass

VERSION = 1
STEMS = stems.STEMS                     # drums, bass, other, vocals
# In the order they are summed, here and in the app.
LAYERS = ("residual",) + STEMS + ("sub_tone", "sub_kick", "air")
# A stem fader at or under this is off: silence, not -30 dB.
FLOOR_DB = -30.0
LEVEL_MAX_DB = 12.0
SUB_MAX_DB = 16.0                       # the Cap slider's top
AIR_MAX_DB = 12.0
BUNDLE_FILE = "mix.json"
SHARED_DIR = Path.home() / "Music" / "LoudnessLab" / "stem-mix"


def level_gain(db: float) -> float:
    """A stem fader's gain. `StemMix.levelGain` in the app is this."""
    db = float(db)
    if not math.isfinite(db) or db <= FLOOR_DB:
        return 0.0
    return 10.0 ** (min(db, LEVEL_MAX_DB) / 20.0)


def layer_gains(info: dict, choice: dict) -> dict[str, float]:
    """Every layer's gain for a choice -- {"levels_db": {stem: dB},
    "sub_db": dB, "air_db": dB} -- over a bundle's mix.json. The app
    computes the same numbers (`StemMix.gains`) to play them."""
    levels = choice.get("levels_db") or {}
    gains = {"residual": 1.0}
    for name in STEMS:
        gains[name] = level_gain(levels.get(name, 0.0))
    sub = info["sub"]
    amount = min(max(float(choice.get("sub_db", 0.0)), 0.0), SUB_MAX_DB)
    gains["sub_tone"] = gains["sub_kick"] = 0.0
    if sub["available"] and amount > 0:
        gains["sub_tone"] = subbass.gain_from_stats(
            sub["energy"], sub["tone_cross"], sub["tone_energy"], amount)
        if sub["kick"]:
            gains["sub_kick"] = subbass.gain_from_stats(
                sub["energy"], sub["kick_cross"], sub["kick_energy"], amount)
    lift = info["air"]
    amount = min(max(float(choice.get("air_db", 0.0)), 0.0), AIR_MAX_DB)
    gains["air"] = 0.0
    if lift["available"] and amount > 0:
        gains["air"] = air.gain_from_stats(lift["before"], lift["cross"],
                                           lift["added"], amount)
    return {name: float(g) for name, g in gains.items()}


def mix(layers: dict[str, np.ndarray], gains: dict[str, float],
        only: tuple[str, ...] = LAYERS) -> np.ndarray:
    """The sum the app plays: each layer times its gain, in LAYERS order,
    in float32 as the app's mixer does it."""
    out = np.zeros_like(layers["residual"], dtype=np.float32)
    for name in only:
        gain = gains.get(name, 0.0)
        if name in layers and gain != 0.0:
            out += np.float32(gain) * layers[name]
    return out


def _plain(value):
    """JSON-safe: numpy scalars to Python, non-finite to null, arrays out."""
    if isinstance(value, dict):
        return {str(k): _plain(v) for k, v in value.items()
                if not isinstance(v, np.ndarray)}
    if isinstance(value, (list, tuple)):
        return [_plain(v) for v in value]
    if isinstance(value, (np.bool_, bool)):
        return bool(value)
    if isinstance(value, (np.integer, int)):
        return int(value)
    if isinstance(value, (np.floating, float)):
        value = float(value)
        return value if math.isfinite(value) else None
    return value


def _stereo(y: np.ndarray) -> np.ndarray:
    y = np.asarray(y, dtype=np.float32)
    return np.column_stack([y, y]) if y.ndim == 1 else y


def _write(path: Path, y: np.ndarray) -> None:
    """float32 WAV: exact, and what AVAudioFile reads without converting."""
    wavfile.write(path, decode.TARGET_RATE, np.ascontiguousarray(_stereo(y)))


def read_layers(bundle: Path, info: dict) -> dict[str, np.ndarray]:
    layers = {}
    for name, file in info["files"].items():
        rate, y = wavfile.read(bundle / file)
        if rate != decode.TARGET_RATE or y.dtype != np.float32:
            raise ValueError(f"stem mix layer {file} is not 48 kHz float32")
        layers[name] = y
    return layers


def read_info(bundle: Path) -> dict:
    info = json.loads((Path(bundle) / BUNDLE_FILE).read_text())
    if info.get("version") != VERSION:
        raise ValueError("this stem mix was prepared by another version; "
                         "open Stem Mix again")
    return info


def prepare(job: dict, bundle: Path, separate=None) -> dict:
    """Split the track, run the chain up to the sub, and write the layers
    and mix.json into `bundle`. Returns mix.json's contents.

    `job` is a processing run's job for the track (cli.cmd_subbass builds
    it), so the preview starts from what a run with these settings would.
    `separate(audio) -> {stem: array}` is for tests; Demucs otherwise.
    """
    from . import render  # render imports this module
    bundle = Path(bundle)
    bundle.mkdir(parents=True, exist_ok=True)
    source = Path(job["path"])
    original = decode.decode(source)
    rate = decode.TARGET_RATE
    if separate is None:
        def separate(x):
            return stems.separate(x, rate, "demucs")
    parts = separate(original)
    # Kept as a processing run keeps them, so the kicks and the air guide
    # below come from where a run would read them, and a run over this
    # folder later separates nothing.
    cache = Path(job["stem_cache"])
    stems.store_kick_source(cache, original, rate, parts["drums"],
                            [parts["vocals"], parts["other"]], bass=parts["bass"])
    asked_sub = float(job.get("amount", 0.0))
    asked_air = float(job.get("air", 0.0))
    # The kicks are chosen only for a sub that is asked for; a sub slider
    # starting at 0 can still be moved, so it is planned as if asked.
    run = {**job, "stem_kicks": True, "skip": None, "compare": False,
           "dry_run": False}
    staged = render._front(run, original, asked_sub if asked_sub > 0 else 1.0)
    base = staged["audio"]

    layers = {"residual": (base - sum(parts[name] for name in STEMS)).astype(np.float32)}
    for name in STEMS:
        layers[name] = parts[name]
    del parts

    sub_info = {"available": False, "note": staged["skip"], "kick": False,
                "energy": 0.0, "tone_cross": 0.0, "tone_energy": 0.0,
                "kick_cross": 0.0, "kick_energy": 0.0}
    if staged["skip"] is None:
        sub = subbass.sub_layers(base, rate, staged["freq"], staged["decay"],
                                 drums=staged["drums"], kicks=staged["found"],
                                 bassline=staged["following"])
        sub_info.update(available=sub["available"], note=sub["note"],
                        kicks_per_minute=sub["report"].get("kicks_per_minute"),
                        bass_share=sub["report"].get("bass_share"),
                        polarity_flipped=sub["report"].get("polarity_flipped"))
        if sub["available"]:
            layers["sub_tone"] = sub["tone"]
            if sub["kick"] is not None:
                layers["sub_kick"] = sub["kick"]
            sub_info.update(kick=sub["kick"] is not None, energy=sub["energy"],
                            tone_cross=sub["tone_cross"],
                            tone_energy=sub["tone_energy"],
                            kick_cross=sub["kick_cross"],
                            kick_energy=sub["kick_energy"])

    tune = float(job.get("air_tune", air.DEFAULT_TUNE_HZ))
    guide, air_note = None, None
    if job.get("air_stems"):
        guide = stems.load_air_guide(cache, original, rate)
    plan = air._air_plan(base, rate, tune, air.DRIVE, air.BIAS, guide)
    air_info = {"available": "note" not in plan, "note": plan.get("note", air_note),
                "tune_hz": tune, "guided": guide is not None,
                "before": plan.get("before", 0.0), "cross": plan.get("cross", 0.0),
                "added": plan.get("added", 0.0),
                "guided_cross": plan.get("guided_cross", 0.0),
                "guided_added": plan.get("guided_added", 0.0)}
    if air_info["available"]:
        layers["air"] = plan.pop("harmonics").astype(np.float32)
    del plan

    files = {}
    for name in LAYERS:
        if name in layers:
            files[name] = f"{name}.wav"
            _write(bundle / files[name], layers[name])
    found = staged["found"]
    if found is not None:
        np.save(bundle / "kicks.npy", np.asarray(found[0]))
    info = _plain({
        "version": VERSION, "key": stems.audio_key(original),
        "path": str(source), "name": job.get("name"), "rate": rate,
        "frames": int(original.shape[0]),
        "seconds": round(original.shape[0] / rate, 3),
        "files": files, "stems": list(STEMS),
        "limits": {"floor_db": FLOOR_DB, "level_max_db": LEVEL_MAX_DB,
                   "sub_max_db": SUB_MAX_DB, "air_max_db": AIR_MAX_DB},
        "defaults": {"sub_db": min(max(asked_sub, 0.0), SUB_MAX_DB),
                     "air_db": min(max(asked_air, 0.0), AIR_MAX_DB)},
        "sub": {**sub_info, "freq": staged["freq"], "decay": staged["decay"]},
        "air": air_info,
        "front": {"clip": staged["clip"], "range": staged["ranged"],
                  "transient": staged["shaped"], "mud": staged["cleared"],
                  "body": staged["bodied"]},
    })
    (bundle / BUNDLE_FILE).write_text(json.dumps(info, indent=1))
    return info


def describe(choice: dict) -> str:
    """The choice in words, for the results row."""
    levels = choice.get("levels_db") or {}

    def one(name):
        db = float(levels.get(name, 0.0))
        return f"{name} {'off' if level_gain(db) == 0 else f'{db:+.1f}'}"
    return ("stem mix: " + ", ".join(one(n) for n in STEMS)
            + f"; sub {float(choice.get('sub_db', 0.0)):+.1f}, "
              f"air {float(choice.get('air_db', 0.0)):+.1f}")


def commit(job: dict, original: np.ndarray, measure=None) -> dict:
    """The chosen mix as a processing run's stages would have left the
    track: the same keys `render._front` returns, plus `after` (the mix),
    `info` (the sub's report) and `aired` (air's). Raises if the bundle
    does not belong to this audio."""
    choice = job["stem_mix"]
    bundle = Path(choice["bundle"])
    info = read_info(bundle)
    if info["key"] != stems.audio_key(original):
        raise ValueError("the track has changed since its stem mix was "
                         "prepared; open Stem Mix again")
    layers = read_layers(bundle, info)
    gains = layer_gains(info, choice)
    rate = decode.TARGET_RATE
    stem_part = ("residual",) + STEMS
    unity = {name: 1.0 for name in stem_part}
    base = mix(layers, unity, stem_part)
    levelled = mix(layers, gains, stem_part)
    with_sub = mix(layers, gains, stem_part + ("sub_tone", "sub_kick"))
    after = mix(layers, gains)

    sub_db = min(max(float(choice.get("sub_db", 0.0)), 0.0), SUB_MAX_DB)
    air_db = min(max(float(choice.get("air_db", 0.0)), 0.0), AIR_MAX_DB)
    report = subbass._blank_report(sub_db)
    report["note"] = describe(choice)
    report["kicks_per_minute"] = float(info["sub"].get("kicks_per_minute") or 0.0)
    report["bass_share"] = float(info["sub"].get("bass_share") or 0.0)
    if gains["sub_tone"] or gains["sub_kick"]:
        was = subbass._band_power(levelled, rate, subbass.SUB_LOW_HZ, subbass.SUB_HIGH_HZ)
        now = subbass._band_power(with_sub, rate, subbass.SUB_LOW_HZ, subbass.SUB_HIGH_HZ)
        if was > 0 and now > 0:
            report["applied_db"] = float(10 * np.log10(now / was))
    aired = air._blank("not asked for" if air_db <= 0
                       else info["air"].get("note") or "not asked for")
    lift = info["air"]
    if gains["air"] > 0:
        g = gains["air"]
        now = lift["before"] + 2 * g * lift["guided_cross"] + g * g * lift["guided_added"]
        aired.update(applied=True, amount_db=air_db, tune_hz=lift["tune_hz"],
                     guided=lift["guided"], note=None,
                     measured_db=float(10 * np.log10(now / lift["before"])))
    kicks = bundle / "kicks.npy"
    front = info["front"]
    return {"audio": base, "amount": sub_db, "skip": None, "note_skip": None,
            "clip": front["clip"], "drums": None,
            "found": (np.load(kicks), None) if kicks.exists() else None,
            "selection": None, "freq": info["sub"]["freq"],
            "decay": info["sub"]["decay"], "voice": None, "following": None,
            "bass_note": None, "ranged": front["range"],
            "shaped": front["transient"], "cleared": front["mud"],
            "bodied": front["body"], "after": after, "info": report,
            "aired": aired, "gains": gains}
