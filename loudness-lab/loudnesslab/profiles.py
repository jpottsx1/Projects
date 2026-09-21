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
