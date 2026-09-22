# loudness-lab

Normalising and repairing a DJ library. Two implementations of the same
measurements: Python (`loudnesslab/`, the command line) and Swift
(`macapp/`, the Mac app). **The Python is the reference.** Where they
disagree, the Python is right until proven otherwise -- but proving
otherwise has happened, so take a disagreement seriously rather than
tuning it away.

## Standing rules

- **Originals are never written to.** Processing writes copies. The only
  exception is an explicit `--in-place`, which logs what it did so it can
  be undone.
- **Serato metadata must survive byte for byte.** Cue points and beatgrids
  live in GEOB frames. The MP3 gain path changes `global_gain` inside audio
  frames and nothing else; `testTheID3RegionIsNeverTouched` and
  `testOnlyAudioFrameBytesChange` are what keep that true.
- **A measurement without a test is an opinion.** Most constants here were
  chosen by measuring a corpus. If you change one, say what you measured.
- **Do not loosen a tolerance to make a test pass** until you know why it
  fails. Twice now a failing golden test was the port being right.

## Who this is for

Jeff is a DJ, not a developer. He does not want to run terminal commands,
and should not have to: the Mac app is the product. If something can only
be done from a shell, that is a gap in the app, not a thing to instruct
him through. Build it, run it, read the errors and fix them yourself --
that is what running locally is for.

The app opens in Xcode from `macapp/Package.swift` (Cmd-R runs, Cmd-U
tests), or by double-clicking `macapp/Build and Run LoudnessLab.command`,
which pulls, builds and launches.

## Running things

```sh
python3 -m unittest discover -s tests -t .   # ~205 tests, ~2 min
swift test --package-path macapp             # 42 golden tests, ~2 min
python3 tools/check_golden.py                # vectors vs the Swift structs
python3 tools/check_help.py                  # every setting has help text
```

Needs `ffmpeg` and `ffprobe` on PATH, plus numpy/scipy for the Python.

## The app

Three panes. Left: folders, settings, Process. Middle: the tracks found,
in the order they will be worked through -- thinnest low end first, with
ticks deciding what runs. Right: two tabs, **Survey** and **Results**,
then the A/B player and the log.

Survey answers what a folder IS: how much of it arrived clipped, what
levelling to each target would cost, and how far each folder's low end
sits under a named reference. That last number is where a profile's cap
comes from. Measure reads the files and writes nothing.

`Processor` runs the chain off the main actor, two or three tracks at a
time. It is bounded on purpose -- a six-minute stereo track is about
250 MB as doubles and the chain holds several copies at once.

## The golden vectors

`tools/make_golden.py` runs the Python and writes
`macapp/Tests/LoudnessKitTests/Golden/golden.json`, `FilterBank.swift` and
`library.db`. The Swift tests assert against those numbers, which is what
makes the port a port and not a rewrite. Regenerate after changing any
Python measurement, and commit the result.

It is deterministic: regenerating without a behaviour change should produce
no diff. A diff you did not expect is a finding.

Two checks run without a Swift toolchain, so they work anywhere:

```sh
python3 tools/check_golden.py   # will golden.json decode into the Swift structs?
python3 tools/check_help.py     # does every setting have help text?
```

`make_golden.py` runs `check_golden.py` itself and warns if it wrote a
fixture that `.gitignore` would swallow -- `library.db` was invisible to
every machine but the one that made it for a while.

## Things that have bitten

- **`sosfilt` vs `sosfiltfilt`.** Zero-phase and causal are different code
  paths with different answers. Check which one a stage wants.
- **The Python works in float32** where it writes audio (`subbass.enhance`
  returns float32; numpy's `rfft` on float32 gives complex64). The Swift is
  double. Below about -140 dB the Python's numbers are its own rounding
  noise, so comparisons there are meaningless in both directions.
- **`-inf` has no SQLite representation.** A silent track's loudness is
  stored NULL, not as a number reports would average in.
- **ffmpeg `-ac 2` attenuates mono by 1/sqrt(2).** A mixdown convention,
  wrong here; `decode()` upmixes at unity instead. Schema v5 marks mono
  rows stale so they re-measure.
- **Python `round()` is banker's rounding** -- Swift needs
  `.rounded(.toNearestOrEven)` to match.
- **Anything heavy on `@MainActor` freezes the window.** The whole chain
  ran on the main thread once, so the progress bar could not move and Stop
  could not be clicked. DSP belongs in the kit, not in an ObservableObject.
- **Folder grouping uses `Library.folderLabels`,** not the parent's name:
  two compilations each with a CD1 otherwise merge into one corpus, and a
  corpus silently averaged with another is a wrong number that looks
  exactly like a right one.

## Layout

```
loudnesslab/     the Python: bs1770, spectrum, subbass, declip, mp3gain,
                 decode, db, report, cli
tests/           its tests
tools/           make_golden.py and the two checkers
macapp/
  Sources/LoudnessKit/    the port: DSP, Loudness, Process, IO, Library
  Sources/LoudnessLabUI/  the app: Engine, ABPlayer, Views
  Tests/                  the golden tests and their fixtures
```

## The decision: the app drives the CLI

The Swift port of the DSP was the wrong call and is being set aside.

It existed so the app would need no Python and no ffmpeg. That bought
nothing -- this machine has both, and `setup.sh` installs them. What it
cost was a day of chasing performance the Python had already solved:
float32 against Double, numpy's rfft in C against a hand-written radix-2
loop, and a multiprocessing width someone had already tuned and written
the reasoning for.

So: **the Python measures and processes, the Swift presents.** Not a
rewrite -- the pieces already fit. Both sides read the same SQLite
database and there is a passing test proving the Swift opens one the
Python wrote.

What stays: every view, `Queue`, `Survey`, `Library`, `ABPlayer`,
`Manifest`, and all of the Python.

What is set aside: `Analyzer`, `Processor`, and in time the DSP under
`LoudnessKit` -- `BS1770`, `Spectrum`, `Declip`, `SubBass`, `Resampler`,
`FFT`, `MP3Gain`. Leave the files and their golden tests in the
repository. They are validated work, they cost nothing sitting there, and
they are the fallback if bundling Python ever becomes the better answer.

### How

- `./loudness-lab analyze <folders> --db <db> --porcelain` writes one JSON
  object per line on stdout: `{"event":"progress","done":N,"total":M,
  "name":...,"status":...}`, then `{"event":"done",...counts}`. Drive the
  progress bar from that. Tested in `TestPorcelainProgress`.
- Then read the database as now -- `Survey.of` and `Library` are unchanged
  and already work.
- **Measuring is wired.** `Engine.measurePass` runs the CLI and drives the
  bar from its JSON; `CLI.swift` finds the tool by walking up from the app,
  reassembles lines from the pipe, and terminates the process on Stop.
  Both Measure and Process go through it.
- **Processing is not.** `Engine.run` still uses the Swift `Processor`.
  `./loudness-lab subbass ...` writes the FLACs and a `manifest.json` that
  `Manifest.swift` already decodes; it needs a `--porcelain` like
  `analyze`, with a test, and then `Engine.run` can drive that instead.
- Finding the CLI: it lives at the repository root next to `macapp/`, and
  re-executes itself into `.venv`, so there is nothing to activate. The
  app needs a path to it and a clear message when it is missing, pointing
  at `setup.sh`.

Speed to expect: five short fixtures measured in 1.7 seconds through the
Python.

## Where this got to

**The premise is confirmed by ear.** Processed with `eighties`, sized per
track against a modern reference, the result matches the reference's
bottom end and impact. Subtle, which is the right answer: a deficit of 6
to 11 dB in one octave, sized per track and gated where there is no
bassline, should not announce itself. A dramatic result would have meant
the stage was doing more than the measurement justified.

That closes the chain the project was built on: measure a corpus, size
each track against it, and the thing you hear is what the numbers said
would happen.

What was measured on this library, all of it against
`Gathered/New Music 2026-08-14`:

| | low end vs modern | clipped | LRA |
|---|---|---|---|
| 100 Hits New Romantics (2011), 5 discs | -6.18 to -10.92 | 0% on four, 10% on one | ~4.5 |
| DISCOinferno GOLD (2003), 2 discs | -4.91, -7.35 | 53%, 76% | ~4.1 |
| Disco Delight | -4.80 | 18% | 3.71 |

Top end runs +1.47 to +4.84 ABOVE the reference everywhere, so there is
nothing to add up there. Levelling to -16 needs no track turned up.

## Open

1. **Processing still goes through the Swift `Processor`,** not the CLI.
   Measuring was moved and is fast; this is the other half. `subbass`
   needs a `--porcelain` like `analyze`, with a test, and then
   `Engine.run` can drive it.
2. **The A/B switch has still never been confirmed.** Versions are
   scheduled together on one host clock so a switch lands on the same
   sample. A tick or a flam on Shift-Space is the bug.
3. **A rolling expander**, to pull apart over-compressed records and give
   the drops back their impact. LRA is the measurement and it is now
   reported per folder. Note the catch: modern masters are the MOST
   compressed, so unlike the sub stage there is no reference folder to
   aim at -- it needs an absolute target.
4. **Serato markers only travel MP3 to MP3.** FLAC and M4A carry them
   too, in Vorbis comments and com.serato.dj atoms, but going between
   containers is translation rather than copying and needs a real Serato
   file of each to check against.
5. **Nobody but Jeff has run this.** No licence file, no signing
   identity, and ffmpeg's licensing needs a real answer before anything
   is sold. `libmp3lame` is GPL.
