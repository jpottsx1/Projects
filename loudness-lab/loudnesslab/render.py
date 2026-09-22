"""One track's processing chain, as a function a pool can run.

Everything the chain needs arrives as plain data and everything it reports
leaves as plain data, so a worker process can do the work without opening
the database, resolving a profile, or knowing what a progress bar is. The
selection and the sizing are decided in the parent, where the database
lives; this is only the part that costs minutes.

Like `analyze.analyse_file`, it never raises: a failure comes back as
status='error' so one bad file cannot end a run over a library.
"""

from __future__ import annotations

import multiprocessing
import os
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np

from . import (air, bs1770, declip, decode, expand, spectrum, subbass,
               write)


def default_jobs() -> int:
    """Half the cores, as the analysis pass uses.

    Each worker here holds several whole decoded tracks at once -- the
    original, the de-clipped intermediate, the processed result and, in a
    comparison run, a level-matched copy of each. A twelve-minute extended
    mix is about 280 MB a copy at 48 kHz stereo float32, so this is bounded
    by memory rather than by cores and saturating the CPU count would cost
    more in swapping than it buys in throughput.

    What it is worth, measured on four cores over four two-and-a-half
    minute tracks: 62.5 s at one worker against 36.1 s at four. A 1.7x
    speedup, not 4x, because the decode and the encode are already
    separate ffmpeg processes and numpy releases the lock in the parts
    that matter.

    The same measurement on six ten-second fixtures went the OTHER way --
    6.1 s at one worker, 7.7 s at four. Spawning a worker re-imports numpy
    and scipy, which costs about a second, and on a short enough track
    that is the whole job. It is left alone rather than tuned around: real
    tracks are minutes long, and a rule fitted to a test fixture is a rule
    fitted to nothing.
    """
    return max(1, (os.cpu_count() or 2) // 2)


def _variant(kind: str, path: Path, label: str, audio) -> dict:
    """One playable rendering of a track, with what the player needs to line
    it up against the others and monitor it fairly."""
    measured = bs1770.measure(audio)
    return {
        "kind": kind, "label": label, "path": str(path),
        "seconds": round(audio.shape[0] / decode.TARGET_RATE, 4),
        "lufs_i": measured["lufs_i"], "s_p95": measured["s_p95"],
        "true_peak_dbtp": measured["true_peak_dbtp"],
    }


def _level_to_target(audio, job: dict, measured: dict):
    """Bring the finished audio to the profile's level. Returns the audio,
    the gain applied, and the resulting true peak.

    Scaling a float buffer is exact, so nothing is lost doing this here
    rather than in a separate pass -- and a separate pass is not available
    anyway, since the lossless gain writer works only on MP3.
    """
    value = measured.get(job["estimator"])
    if value is None:
        return audio, 0.0, measured.get("true_peak_dbtp", float("nan"))
    wanted = job["target"] - value
    peak = measured.get("true_peak_dbtp")
    if peak is not None and peak + wanted > job["peak_ceiling"]:
        wanted = job["peak_ceiling"] - peak
    levelled = (audio * (10 ** (wanted / 20))).astype(audio.dtype)
    return levelled, wanted, bs1770.measure(levelled)["true_peak_dbtp"]


def _mean_low(table: dict) -> float:
    from . import report
    values = [table[b] for b in report.LOW_SHAPE_BANDS if table.get(b) is not None]
    return sum(values) / len(values) if values else float("nan")


def one(job: dict) -> dict:
    """Process one track. Runs in a worker process; never raises."""
    source = Path(job["path"])
    base = {"path": job["path"], "name": job["name"], "folder": job["folder"]}
    skip = job.get("skip")

    # Decide before decoding where the database already settles it. A policy
    # preview over a whole library should not spend minutes decoding tracks
    # it has already determined need nothing.
    if skip is not None:
        return {**base, "status": "skipped", "reason": skip, "amount": None,
                "range": expand._blank_range("not reached"),
                "transient": expand._blank_transient("not reached"),
                "air": air._blank("not reached")}

    amount = float(job["amount"])
    note_skip = None
    try:
        audio = original = decode.decode(source)
        # First, on the file as it arrived. De-clipping puts peaks BACK, so
        # it needs the audio before anything has attenuated it, and
        # everything after it has to fit under the peak it restores.
        clip = None
        if job["declip"]:
            audio, clip = declip.restore(audio, decode.TARGET_RATE,
                                         max_restore_db=job["declip_max"])
        # The content check needs the audio, not the per-frame band
        # statistics, so it happens here rather than in the query.
        if amount > 0:
            activity = subbass.low_band_activity(audio, decode.TARGET_RATE)
            if np.isfinite(activity) and activity < job["min_activity"]:
                skip = (f"sub octave barely moves ({activity:.0f} dB) -- "
                        f"a static floor rather than a bassline")
        # Dynamics before the sub, and in this order, because each stage
        # wants the signal the one before it produced. De-clipping goes
        # first and on the file as it arrived; the range stage only
        # attenuates, so doing it early gives everything after it headroom;
        # the transient stage then shapes attacks that are no longer being
        # held down by a loud chorus; and the sub is added last because it
        # is the only one putting in something that was never there.
        ranged = expand._blank_range("not asked for")
        if job.get("target_lra", 0.0) > 0:
            audio, ranged = expand.restore_range(
                audio, decode.TARGET_RATE,
                target_lra=job["target_lra"],
                max_attenuation_db=job.get("max_attenuation",
                                           expand.MAX_ATTENUATION_DB))
        shaped = expand._blank_transient("not asked for")
        if job.get("transient", 0.0) > 0:
            audio, shaped = expand.restore_transients(
                audio, decode.TARGET_RATE,
                amount_db=job["transient"],
                min_crest_db=job.get("min_crest", expand.MIN_CREST_DB))

        if skip is not None:
            # A track can want de-clipping, or dynamics, and not want a sub.
            # Where any of those did something there is a new file worth
            # writing, so only the sub is dropped; where nothing was done,
            # say so and move on.
            amount = 0.0
            if not (ranged["applied"] or shaped["applied"]
                    or (clip is not None and clip["restored"])):
                return {**base, "status": "skipped", "reason": skip,
                        "amount": None, "clip": clip, "range": ranged,
                        "transient": shaped, "air": air._blank("not reached")}
            note_skip = skip

        after, info = subbass.enhance(audio, decode.TARGET_RATE,
                                      amount_db=amount,
                                      freq=job["freq"], decay_s=job["decay"],
                                      punch_db=job["punch"],
                                      punch_decay_ms=job["punch_decay"])
        # Air last of the spectral stages, because it generates from what
        # is there and by this point what is there is finished. It is also
        # the only one that can push the file above full scale on its own,
        # so the levelling that follows is what takes that back out.
        aired = air._blank("not asked for")
        if job.get("air", 0.0) > 0:
            after, aired = air.excite(after, decode.TARGET_RATE,
                                      amount_db=job["air"],
                                      tune_hz=job.get("air_tune",
                                                      air.DEFAULT_TUNE_HZ))

        kicks, _ = subbass.detect_kicks(audio, decode.TARGET_RATE)
        # Against the ORIGINAL, not against the de-clipped intermediate: the
        # columns say "was", and what the track was is what arrived.
        # Restored transients belong in the snap figure, not hidden in a
        # baseline that already has them.
        snap_before = subbass.attack_contrast(original, decode.TARGET_RATE, kicks)
        snap_after = subbass.attack_contrast(after, decode.TARGET_RATE, kicks)
        before_bands = {b["band_hz"]: b["shape_db"]
                        for b in spectrum.analyse(original, decode.TARGET_RATE)}
        after_bands = {b["band_hz"]: b["shape_db"]
                       for b in spectrum.analyse(after, decode.TARGET_RATE)}
        processed = bs1770.measure(after)
        peak = processed["true_peak_dbtp"]
        out_dir = Path(job["out_dir"])
        fmt = job["fmt"]
        variants = []

        if job["dry_run"]:
            match_db = 0.0
        elif not job["compare"]:
            # Level here, as the final operation. The gain command cannot do
            # it: global_gain only exists in an MP3 bitstream, and what
            # comes out of here may be anything. Without this the pipeline
            # simply ends un-levelled, which is the one state worse than not
            # having started -- part of the library at the target and part
            # several dB hot.
            after, match_db, final = _level_to_target(after, job, processed)
            peak = final
            written = write.write(out_dir / job["stem"], after,
                                  decode.TARGET_RATE, source, fmt)
            variants = [_variant("processed", written, job["label"], after)]
        else:
            # Level-match the pair, or the comparison just measures which is
            # louder: adding sub raises loudness, and louder wins every
            # blind test regardless of whether it is better. Both are
            # brought DOWN to whichever is quieter, so neither can clip.
            original_lufs = bs1770.measure(original)["lufs_i"]
            target = min(original_lufs, processed["lufs_i"])
            a = original * (10 ** ((target - original_lufs) / 20))
            b = after * (10 ** ((target - processed["lufs_i"]) / 20))
            match_db = target - original_lufs
            # A restored peak stands above full scale by design, and the
            # writer clips what it is given -- which would put back exactly
            # the flat tops this pass just took out. Trim BOTH by the same
            # amount so the level match survives the headroom.
            room = max(float(np.abs(a).max()), float(np.abs(b).max()))
            if room > 0.99:
                a, b = a * (0.99 / room), b * (0.99 / room)
                match_db += 20 * np.log10(0.99 / room)
            # Both written in the SAME format from the same decode, so no
            # codec difference can creep into the comparison.
            a_path = write.write(out_dir / f"{job['stem']} -- A original", a,
                                 decode.TARGET_RATE, source, fmt)
            b_path = write.write(out_dir / f"{job['stem']} -- B {job['label']}", b,
                                 decode.TARGET_RATE, source, fmt)
            peak = bs1770.measure(b)["true_peak_dbtp"]
            variants = [_variant("original", a_path, "original", a),
                        _variant("processed", b_path, job["label"], b)]
    except Exception as exc:  # decode/DSP/encode failures are per-file
        return {**base, "status": "error",
                "reason": f"{type(exc).__name__}: {exc}"[:500], "amount": None,
                "range": expand._blank_range("failed"),
                "transient": expand._blank_transient("failed"),
                "air": air._blank("failed")}

    # "no spectral change asked for" contradicts the header on a de-clipping
    # run, where de-clipping IS the change that was asked for.
    reason = note_skip or info["note"]
    if reason == "no spectral change asked for" and (
            job["declip"] or ranged["applied"] or shaped["applied"]
            or aired["applied"]):
        # The note is about the SUB, and on a run whose point was
        # de-clipping, range or attack it reads as a complaint that nothing
        # happened -- on a row that shows what happened.
        reason = None

    manifest = None
    if variants:
        manifest = {
            "source": str(source), "name": job["name"], "folder": job["folder"],
            "sub_db": round(float(info["applied_db"]), 3),
            "punch_db": round(float(info["punch_db"]), 3),
            "clips_restored": (clip or {}).get("restored", 0),
            "clip_lift_db": round(float((clip or {}).get("lift_db", 0.0)), 3),
            "variants": variants,
        }
    return {
        **base, "status": "ok", "amount": amount, "reason": reason,
        "clip": clip, "manifest": manifest,
        "range": ranged, "transient": shaped, "air": aired,
        "kicks_per_minute": float(info["kicks_per_minute"]),
        "shape_before": float(_mean_low(before_bands)),
        "shape_after": float(_mean_low(after_bands)),
        "applied_db": float(info["applied_db"]),
        "safety_trim_db": float(info["safety_trim_db"]),
        "peak_dbtp": float(peak),
        "match_db": float(match_db),
        "snap_db": float(snap_after - snap_before),
    }


def run(jobs: list[dict], workers: int | None = None, progress=None) -> list[dict]:
    """Work through `jobs`, in order, `workers` at a time.

    Results come back in the order given whichever width is used, so the
    per-track table reads the same on one core as on eight and a caller
    driving a progress bar sees a count that only goes up.
    """
    workers = workers or default_jobs()
    results, pool = [], None
    if workers == 1 or len(jobs) <= 1:
        produced = map(one, jobs)
    else:
        # "spawn" explicitly rather than the platform default, for the same
        # reason the analysis pass pins it: forking a process that has
        # already loaded numpy/Accelerate is not safe on macOS, and the
        # behaviour under test on Linux should be the behaviour users get.
        pool = ProcessPoolExecutor(
            max_workers=workers,
            mp_context=multiprocessing.get_context("spawn"))
        produced = pool.map(one, jobs, chunksize=1)
    try:
        for done, result in enumerate(produced, 1):
            results.append(result)
            if progress:
                progress(done, len(jobs), result)
    finally:
        if pool is not None:
            pool.shutdown()
    return results
