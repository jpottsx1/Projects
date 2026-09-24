"""Stems: a separated drum part to detect kicks on.

A PROTOTYPE, and deliberately narrow. The first use of a separator here is
to FIND things, not to process them: `subbass.detect_kicks` looks for kick
onsets in 30-100 Hz of the full mix, which is exactly where the bassline
lives too. A disco octave bass plucks a sharp attack on every off-beat in
that band, and a detector keyed on attack sharpness cannot tell it from a
kick. On a drum stem the bassline has been taken out before the detector
ever sees it.

Nothing separated is ever mixed into the output. The stem decides WHERE
the sub goes; the sub is still added to the untouched original. So a
separation artifact can move a kick marker, and that is all it can do --
it cannot leak into the audio. That is what makes an imperfect separator
safe to use here, and every separator is imperfect.

Two backends:

- `demucs` (htdemucs) is the intended one: better separation, and it runs
  on the GPU on Apple Silicon. Its weights come from dl.fbaipublicfiles.com.
- `spleeter` (4stems) is older and worse, and is here because it is what
  could be measured where this was written: its weights are a GitHub
  release. If the drum stem helps with Spleeter's separation, it will not
  help less with a better one.

Neither is in requirements.txt: PyTorch (or TensorFlow) is a gigabyte or
two, and nothing uses a stem yet outside this prototype. `available()`
says which backends can run, rather than failing halfway through a batch.
"""

from __future__ import annotations

import importlib.util

import numpy as np
import soxr

STEMS = ("drums", "bass", "other", "vocals")
BACKENDS = ("demucs", "spleeter")
# Both models were trained at 44.1 kHz. Feeding them anything else is not
# an error they report -- it is just a worse separation.
MODEL_RATE = 44100

_loaded: dict[str, object] = {}


def available() -> list[str]:
    """The backends whose libraries are importable here."""
    found = []
    if importlib.util.find_spec("demucs") and importlib.util.find_spec("torch"):
        found.append("demucs")
    if importlib.util.find_spec("spleeter"):
        found.append("spleeter")
    return found


def _stereo(x: np.ndarray) -> np.ndarray:
    return np.column_stack([x, x]) if x.ndim == 1 else x


def _demucs(x: np.ndarray, model=None) -> dict[str, np.ndarray]:
    import torch
    from demucs.apply import apply_model

    if model is None:
        if "demucs" not in _loaded:
            from demucs.pretrained import get_model
            _loaded["demucs"] = get_model("htdemucs")
        model = _loaded["demucs"]
    device = ("mps" if torch.backends.mps.is_available()
              else "cuda" if torch.cuda.is_available() else "cpu")
    model.to(device).eval()
    wav = torch.from_numpy(np.ascontiguousarray(x.T, dtype=np.float32))
    # Demucs normalises its input itself in its own CLI; do the same, or a
    # quiet track is separated as though it were a different recording.
    ref = wav.mean(0)
    mean, std = float(ref.mean()), float(ref.std()) or 1.0
    with torch.no_grad():
        out = apply_model(model, ((wav - mean) / std)[None], device=device,
                          split=True, overlap=0.25, progress=False)[0]
    out = out * std + mean
    return {name: out[i].cpu().numpy().T.astype(np.float32)
            for i, name in enumerate(model.sources)}


def _spleeter(x: np.ndarray) -> dict[str, np.ndarray]:
    if "spleeter" not in _loaded:
        from spleeter.separator import Separator
        _loaded["spleeter"] = Separator("spleeter:4stems")
    out = _loaded["spleeter"].separate(x.astype(np.float32))
    return {name: np.asarray(out[name], dtype=np.float32) for name in STEMS}


def separate(x: np.ndarray, rate: int, backend: str = "demucs",
             model=None) -> dict[str, np.ndarray]:
    """Split a track into drums, bass, other and vocals.

    Every stem comes back at `rate` and exactly as long as `x`, so a sample
    offset found in a stem is the same offset in the original. That is the
    property the kick detector depends on; a stem a few samples short would
    put every burst a few samples early.

    `model` is for tests: a Demucs model to use instead of loading htdemucs.
    """
    if backend not in BACKENDS:
        raise ValueError(f"unknown separator {backend!r}; one of {BACKENDS}")
    if backend not in available():
        raise RuntimeError(
            f"{backend} is not installed in this environment "
            f"(available: {', '.join(available()) or 'none'})")
    source = _stereo(np.asarray(x, dtype=np.float64))
    n = source.shape[0]
    at_model = (soxr.resample(source, rate, MODEL_RATE, quality="VHQ")
                if rate != MODEL_RATE else source)
    stems = _demucs(at_model, model) if backend == "demucs" else _spleeter(at_model)

    out = {}
    for name in STEMS:
        stem = stems[name].astype(np.float64)
        if rate != MODEL_RATE:
            stem = soxr.resample(stem, MODEL_RATE, rate, quality="VHQ")
        if stem.shape[0] < n:
            stem = np.pad(stem, ((0, n - stem.shape[0]), (0, 0)))
        out[name] = stem[:n].astype(np.float32)
    return out
