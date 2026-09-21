# Loudness Lab — macOS app

A native app being grown out of the Python in the folder above.

    open macapp/Package.swift      # then ⌘B to build, ⌘U to test, ⌘R to run

Needs macOS 14. Do not sandbox it: it reads folders you point it at, and
while the port is unfinished it also runs the Python as a subprocess.

## How the port is kept honest

This project's worth is that its measurements are validated — BS.1770 agrees
with ffmpeg's ebur128 to within 0.05 LU, the de-clipper is scored against
known-clean audio, the constants were fitted to measured corpora. A rewrite
in another language throws all of that away unless the rewrite is held to the
same numbers.

So it is. `tools/make_golden.py` runs the reference Python over a set of
fixtures and writes down what it got, stage by stage, into
`Tests/LoudnessKitTests/Golden/golden.json`. `GoldenTests` reads that back
and asserts the Swift agrees. **Where the two disagree, the Python is right.**

Three things make that more than a gesture:

- **The fixtures are defined, not shipped.** Both languages build them from
  the same formula and the same hand-written PRNG, so a few kilobytes of
  expected values travel instead of megabytes of audio — and the fixtures are
  checked *first*, so a disagreement about the input is caught before it can
  be mistaken for a disagreement about the DSP.
- **The filter coefficients are generated, not designed.** Every corner
  frequency in this project is a constant, so scipy designs the filters once
  and `FilterBank.swift` carries the result. A Butterworth prototype, a
  frequency transform, a bilinear transform and a pole-zero pairing all stop
  being things that could be ported wrongly.
- **Properties are restated, not just numbers.** The de-clipper's
  self-limiting behaviour is asserted directly in Swift, because a port could
  match every number on clipped fixtures and still have lost it.

After changing anything the Swift depends on:

    python3 tools/make_golden.py

## What is ported

| | |
|---|---|
| `SOS` — `sosfilt`, `sosfiltfilt`, steady state, odd padding | ✅ golden-tested |
| `FilterBank` — all eight filters | ✅ golden-tested |
| `BS1770` — K-weighting, gating, LUFS-I, LRA, percentiles | ✅ golden-tested |
| `Resampler` — Kaiser FIR, polyphase, true peak | ✅ golden-tested |
| `Declip` — runs, merging, Hermite arcs, caps | ✅ golden-tested |
| `Fixtures` — shared signal generator | ✅ golden-tested |
| `Spectrum` — 1/3-octave LTAS, `FFT`, `Peaks` | ✅ golden-tested |
| `SubBass` — kick detection, sub, attack shaping | ✅ golden-tested |
| `MP3Gain` — lossless `global_gain`, Serato GEOB safety | ✅ golden-tested |
| Audio decode via AVFoundation | ⬜ not yet |
| Library database, reports | ⬜ not yet |
| UI wiring to `LoudnessKit` instead of the CLI | ⬜ not yet |

Until the last row is done the app still shells out to `./loudness-lab`, so
the Python has to be present and working.

## The comparison player

`ABPlayer` is the reason the app exists and does not depend on the port.
Every version of a track is decoded up front, scheduled on its own player
node, and started at one shared **host** time, so they run in lockstep for as
long as you listen. Switching is a gain change on a mixer over a 12 ms ramp —
nothing seeks, nothing re-primes, and the bar you are in plays through it.

That rests on the versions lining up, which they do because the tool renders
them all from one decode. Pair an original MP3 with a processed FLAC yourself
and they will not: the player checks the lengths and says so.

**Match loudness** is on by default — without it the comparison measures which
is louder, and louder wins. **Blind** hides the labels and shuffles per track.
