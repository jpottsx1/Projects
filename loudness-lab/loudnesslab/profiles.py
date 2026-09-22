"""Named bundles of settings, so a policy can be stated once and audited.

A profile fixes what the tool is ALLOWED to do. It does not fix what each
track gets: that still comes from measuring the track. This distinction is
the whole design, and it is why there are no era profiles here.

Era-keyed curves were the obvious idea and the measurements rule them out
twice over. Every clean corpus in this project is a compilation carrying a
reissue date -- a 1981 record tagged 2011, a 1999 record tagged 2026 -- so a
rule reading the year treats old masters as modern. And within a single era
the spread between tracks at 32 Hz is 14-24 dB, against roughly 5 dB between
one era's median and the next, so a curve fitted to the era moves the median
and leaves most tracks further from the target than they started.

Measuring each track against a reference corpus delivers era-appropriate
treatment without needing to know the era: a modern master measures at the
reference and gets only levelling, an eighties master measures short and
gets a sub. The era falls out; it is never declared.
"""

from __future__ import annotations

import json
from pathlib import Path

# Keys a profile may set, with the value used when nothing says otherwise.
FIELDS = {
    "description": "",
    "target": -16.0,        # level to aim at, on `estimator`
    "estimator": "s_p95",
    "peak_ceiling": -1.0,   # dBTP no gain may exceed
    "auto": False,          # size the sub from each track's own shortfall
    "reference": None,      # the corpus --auto measures against
    "amount": 5.0,          # fixed sub, when auto is off. level-only zeroes it
    "max_amount": 6.0,      # cap on the per-track sub
    "min_activity": 20.0,   # below this the sub octave is a floor, not a bassline
    "punch": 0.0,
    "punch_decay": 8.0,
    "declip": False,        # restore peaks that were clipped before we got them
    "declip_max": 6.0,      # dB, hard cap on how far one peak may be lifted
    # Putting dynamics back. Both off by default: they reshape what a
    # compressor left rather than recovering anything, so they are a choice
    # about a record and not a repair every record wants.
    "target_lra": 0.0,      # loudness range to widen to; 0 is off
    "max_attenuation": 6.0, # dB the quiet passages may be pulled down by
    "transient": 0.0,       # dB of attack emphasis at an onset; 0 is off
    "min_crest": 12.0,      # above this a track was never flattened
}

BUILT_IN = {
    "level-only": {
        "description": "Lossless levelling and nothing else. No decode, no "
                       "re-encode, reversible.",
        "target": -16.0, "estimator": "s_p95", "peak_ceiling": -1.0,
        "auto": False, "amount": 0.0, "punch": 0.0,
    },
    "restore": {
        "description": "Levelling, plus sub sized per track against a "
                       "reference corpus. Needs `reference`. Lossy.",
        "target": -16.0, "estimator": "s_p95", "peak_ceiling": -1.0,
        "auto": True, "max_amount": 6.0, "min_activity": 20.0, "punch": 0.0,
    },
    # Measured, not guessed. Three independent 1970s disco corpora -- 108
    # tracks over two compilations and a 2003 reissue -- agree within about
    # 3 dB from 32 to 63 Hz, sitting 6 to 9 dB under a current reference.
    # Nothing usable below 32 Hz: the 20 Hz band reads as empty on all three
    # and 25 Hz on two of them, so a wider window would only lift noise.
    # The 2003 reissue measures THINNER down low than the two older
    # compilations, which is how we know it is era mastering being described
    # rather than a remastering engineer.
    "disco-70s": {
        "description": "1970s disco. Deficit of 6-9 dB across 32-63 Hz, "
                       "agreed by three independent corpora; nothing below "
                       "32 Hz to lift. Needs `reference`. Lossy.",
        "target": -16.0, "estimator": "s_p95", "peak_ceiling": -1.0,
        "auto": True, "max_amount": 8.0,
        # Lower than the default 20. Disco is the most groove-locked material
        # in the project and sits nearest the threshold, and on a corpus this
        # consistent a marginal track is better reviewed than silently
        # dropped.
        "min_activity": 18.0,
        # Off to start: live drummers, and 2-6 kHz is full of hi-hat and
        # tambourine rather than beater click.
        "punch": 0.0,
        # On, and measured rather than assumed. Two discs of a 2003 disco
        # reissue: 9 of 17 clipped on one, 13 of 17 on the other -- 53% and
        # 76%, against 0% on four of five discs of an eighties compilation
        # in the same library. Worst offenders at 324 and 398 runs. The
        # library average would have said 13.6% and decided nothing.
        #
        # The gain through a lossy codec is small -- about 2 dB at light
        # clipping falling to 0.4 at heavy, and this is heavy -- so it is on
        # because the damage is real and the method is self-limiting, not
        # because it is free. Listen before committing a folder to it.
        "declip": True,
    },
    # Measured, like the disco one, and on a library this project did not
    # come from: five discs of "100 Hits - The New Romantics (2011)", 100
    # tracks, against 43 tracks of current music in the same database.
    #
    #   New Romantics discs   -25.81  -23.54  -23.32  -21.88  -21.07
    #   current reference     -14.89
    #
    # That is 6.2 to 10.9 dB short across 31.5-63 Hz, a median near 8.2 --
    # THINNER than the disco corpora, which sat 6 to 9 under the same kind
    # of reference. Worth saying plainly because it was not the expected
    # result: the compilation is a 2011 master, so the mastering is modern
    # and the low end still was not put there.
    #
    # The 4.7 dB spread across five discs of one boxed set is the reason
    # `auto` is on rather than a fixed amount. Within-era spread is the
    # whole argument for measuring each track.
    "eighties": {
        "description": "1980s pop and new wave. Short by 6-11 dB across "
                       "31.5-63 Hz, measured over five discs. Needs "
                       "`reference`. Lossy.",
        "target": -16.0, "estimator": "s_p95", "peak_ceiling": -1.0,
        "auto": True,
        # Eleven, just above the thinnest disc measured. It was ten until
        # the full table came back with a reference set: Disc 4 sits 10.92
        # under, so a cap of ten held about half that disc below what it
        # actually needed -- the exact failure this comment warned about
        # when the cap was first chosen from a partial reading.
        #
        # Disco's eight sits the same distance above ITS measured worst
        # (7.35), so the two profiles bound their material the same way
        # rather than by taste.
        "max_amount": 11.0,
        # The default. Disco lowered this to 18 because that material sits
        # near the threshold and was measured doing so; nothing has measured
        # eighties activity, and moving a gate on a guess is how a static
        # floor gets mistaken for a bassline.
        "min_activity": 20.0,
        # Off, and now measured rather than pending: four of the five
        # discs carry no clipped runs at all and the fifth carries two, so
        # 10% at worst against the disco reissue's 53 and 76. There is
        # nothing here to restore.
        "declip": False,
        # Drum machines already have beater click, and 2-6 kHz on this
        # material is full of gated reverb rather than attack.
        "punch": 0.0,
    },
    # Measured on "Now Yearbook 99 (2026)", 82 tracks over four CDs, against
    # the same 43-track modern reference the others use. The first corpus
    # here whose problem is NOT a missing low end.
    #
    #   low end 31.5-63 Hz   CD4 -18.53  CD1 -18.43  CD3 -18.21  CD2 -17.38
    #   reference            -14.89
    #
    # A deficit of 2.5 to 3.6 dB, against 6.2-10.9 for the eighties and
    # 4.9-7.4 for the disco. By 1999 the bottom end was being put there. So
    # the sub caps at 4, just above the measured worst, on the same rule
    # that gave disco 8 and the eighties 11.
    #
    # What IS wrong with it is everything the loudness war did:
    #
    #   median LUFS-I   -9.48        median true peak  +0.86 dBTP
    #   median s_p95    -7.71        median LRA         5.40
    #   crest (peak - LUFS-I)        10.34 dB
    #   arrived clipped              36 of 82 (43.9%), CD4 at 60%
    #   worst offender               9652 clipped runs
    #
    # Crest at 10.3 is squarely in the hard-limited band (8-11 dB), and LRA
    # at 5.4 in the loudness-war band (4-6). Both stages have something to
    # do here, which is not true of any other corpus in this library.
    #
    # The top end needs nothing: these discs run 3.6 to 6.4 dB ABOVE the
    # reference at 8-16 kHz, and CD2 is the brightest folder measured
    # anywhere in the library.
    "nineties": {
        "description": "Late 1990s pop. Low end nearly there (2.5-3.6 dB "
                       "short), but hard-limited: crest 10.3, LRA 5.4, 44% "
                       "arrived clipped. Needs `reference`. Lossy.",
        "target": -16.0, "estimator": "s_p95", "peak_ceiling": -1.0,
        "auto": True,
        "max_amount": 4.0,
        # The default. Nothing has measured sub-octave activity on this
        # material, and moving a gate on a guess is how a static floor gets
        # mistaken for a bassline.
        "min_activity": 20.0,
        # 44% of the corpus, and 60% of CD4 -- between the eighties (0-10%,
        # off) and the disco reissue (53-76%, on). The worst track carries
        # 9652 clipped runs against the disco worst of 398, so expect the
        # SMALLEST gain here: de-clipping returns about 2 dB at light
        # clipping and 0.4 at heavy, and this is heavy.
        "declip": True,
        # Off. 2-6 kHz on this material is programmed hats and samples, and
        # the top end already sits above the reference.
        "punch": 0.0,
        # From 5.40. Deliberately modest: +1.6 LU, which drops the quietest
        # passages 1.6 dB and never approaches the 6 dB cap. A bigger target
        # would make these duck under the next record, which for a DJ is the
        # failure and not the feature.
        "target_lra": 7.0,
        # Crest 10.34 -> about 11.8 at roughly half a dB per dB. That lands
        # just under the gate rather than past it, which is the intent: the
        # stage should stop being needed, not overshoot into a different
        # kind of wrong. Note the exchange rate was measured on a synthetic
        # fixture, so the figure is an extrapolation until this corpus is
        # processed and re-measured.
        "transient": 3.0,
        "min_crest": 12.0,
    },
}

DEFAULT_FILE = Path("profiles.json")


class ProfileError(RuntimeError):
    pass


def load(path: Path | None = None) -> dict:
    """Built-in profiles, with any from `path` added or overriding by name."""
    profiles = {name: dict(values) for name, values in BUILT_IN.items()}
    source = path or DEFAULT_FILE
    if not source.exists():
        if path is not None:
            raise ProfileError(f"no such profiles file: {path}")
        return profiles
    try:
        loaded = json.loads(source.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ProfileError(f"could not read {source}: {exc}") from exc
    if not isinstance(loaded, dict):
        raise ProfileError(f"{source} must hold an object of name -> settings")

    for name, values in loaded.items():
        if not isinstance(values, dict):
            raise ProfileError(f"profile {name!r} in {source} must be an object")
        unknown = sorted(set(values) - set(FIELDS))
        if unknown:
            raise ProfileError(
                f"profile {name!r} in {source} sets unknown key(s): "
                f"{', '.join(unknown)}. Known keys: {', '.join(sorted(FIELDS))}")
        profiles[name] = {**profiles.get(name, {}), **values}
    return profiles


def resolve(profiles: dict, name: str | None) -> dict:
    """Full settings for `name`, filled in from the defaults."""
    if name is None:
        return dict(FIELDS)
    if name not in profiles:
        raise ProfileError(
            f"no profile {name!r}. Available: {', '.join(sorted(profiles))}")
    return {**FIELDS, **profiles[name]}


def setting(explicit, settings: dict, key: str):
    """An explicit flag wins over the profile, which wins over the default.

    Flags default to None rather than to a value, so that "not given" can be
    told apart from "given the same as the default" -- otherwise a profile
    could never change anything a flag also controls.
    """
    return settings.get(key, FIELDS[key]) if explicit is None else explicit


def describe(profiles: dict) -> str:
    lines = ["PROFILES", "=" * 78, ""]
    for name in sorted(profiles):
        settings = resolve(profiles, name)
        lines.append(f"  {name}")
        if settings.get("description"):
            lines.append(f"    {settings['description']}")
        shown = {k: v for k, v in settings.items()
                 if k != "description" and v != FIELDS[k]}
        if shown:
            lines.append("    " + "  ".join(f"{k}={v}" for k, v in sorted(shown.items())))
        lines.append("")
    lines += [
        "  Profiles fix the policy, not the treatment: how much each track",
        "  gets still comes from measuring that track. Add your own in",
        f"  {DEFAULT_FILE} as an object of name -> settings; anything you set",
        "  overrides a built-in of the same name.",
        "",
        f"  Settable: {', '.join(sorted(FIELDS))}",
    ]
    return "\n".join(lines)
