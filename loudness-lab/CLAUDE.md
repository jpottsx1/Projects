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
python3 -m unittest discover -s tests -t .   # ~250 tests, ~3 min
swift test --package-path macapp             # 42 golden tests, ~2 min
python3 tools/check_golden.py                # vectors vs the Swift structs
python3 tools/check_manifest.py              # manifest vs the Swift structs
python3 tools/check_help.py                  # every setting has help text
find macapp -name '*.swift' | xargs python3 tools/check_braces.py
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

Both buttons run the command line tool and drive the bar from the JSON it
writes. Nothing heavy happens on the main actor, which is what keeps the
window alive and Stop clickable.

## The golden vectors

`tools/make_golden.py` runs the Python and writes
`macapp/Tests/LoudnessKitTests/Golden/golden.json`, `FilterBank.swift` and
`library.db`. The Swift tests assert against those numbers, which is what
makes the port a port and not a rewrite. Regenerate after changing any
Python measurement, and commit the result.

It is deterministic: regenerating without a behaviour change should produce
no diff. A diff you did not expect is a finding.

Four checks run without a Swift toolchain, so they work anywhere. Each one
exists because the mistake it catches cost a round trip to a Mac:

```sh
python3 tools/check_golden.py    # will golden.json decode into the Swift structs?
python3 tools/check_manifest.py  # will the manifest the Python writes?
python3 tools/check_help.py      # does every setting have help text?
python3 tools/check_braces.py macapp/Sources/**/*.swift   # do the braces balance?
```

`check_manifest.py` runs the real command over a real file and walks the
result against the struct declarations in `Manifest.swift` and
`Profile.swift`. It was written, run, and found to pass everything --
`Manifest` had been handed its nested `Track`'s CodingKeys and so had no
fields to check. A checker that cannot fail is worse than none, so it is
now kept honest against five real breakages: a missing required key, a
wrong type, a null in a non-optional, and `Profile` with and without its
hand-written decoder.

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
  could not be clicked. It is a separate process now, which settles it.
- **A property's default does NOT make its Codable key optional.** The
  synthesised `init(from:)` requires every key. `Profile` has a
  hand-written one, because the manifest the command writes leaves
  `description` out -- and one missing key fails the whole document, so
  the symptom would have been a run that processed a folder correctly and
  then showed no results at all.
- **Two tracks can have the same file name.** Everything lands in one
  output folder and a library of compilations is full of "01 Track.mp3".
  Writing both to one path lost one and reported both as written;
  `_unique_stem` adds the folder, then a counter.
- **A test that passes is not a test that works.** Seven deliberate
  breakages were fed to `test_expand.py`; four passed. The lag test
  measured the slew rate instead of the lag, the silence test read a gain
  off digital zeros where no gain can be read, the timing test had a
  second and a half of slack inside an eight-second window, and the stereo
  test probed a property the mutation did not change. Each is now written
  against the failure it is for, and each has been seen to fail.
- **`max_lift_db` is the wrong statistic for a transient stage.** The
  start of any file is an onset, so the maximum is reached whatever the
  detector can hear -- a steady tone reads the full amount.
  `lifted_fraction` is the one that distinguishes shaping from gaining:
  0.006 for that tone, and it is what the tests assert on.
- **Folder grouping uses `Library.folderLabels`,** not the parent's name:
  two compilations each with a CD1 otherwise merge into one corpus, and a
  corpus silently averaged with another is a wrong number that looks
  exactly like a right one.

## Layout

```
loudnesslab/     the Python: bs1770, spectrum, subbass, declip, expand,
                 mp3gain, decode, db, report, render, write, cli
tests/           its tests
tools/           make_golden.py and the four checkers
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
- **Both halves are wired.** `Engine.measurePass` runs `analyze`;
  `Engine.run` runs `subbass` and reads back the `manifest.json` it wrote.
  `CLI.swift` finds the tool by walking up from the app, reassembles lines
  from the pipe, and terminates the process on Stop.
- `subbass --porcelain` emits a `phase` on every progress line, because a
  processing run measures first and then processes: two halves, one bar.
  It finishes with a `done` naming the manifest it wrote, so the app opens
  the file this run produced rather than guessing at a path and showing the
  previous run's results.
- Every setting is passed to the command explicitly rather than by naming
  a profile. A `--profile` would be read from the repository's
  `profiles.json`, which the app does not edit -- so a slider moved in the
  window would have changed nothing, silently.
- The ticked list goes in a file (`--select`), not on the command line: a
  batch is hundreds of paths and argv has a limit.
- Finding the CLI: it lives at the repository root next to `macapp/`, and
  re-executes itself into `.venv`, so there is nothing to activate. The
  app needs a path to it and a clear message when it is missing, pointing
  at `setup.sh`.

Speed to expect: five short fixtures measured in 1.7 seconds through the
Python. Processing runs several tracks at a time through a spawn pool --
measured on four cores over four two-and-a-half minute tracks, 62.5 s at
one worker against 36.1 s at four. On six ten-second fixtures it goes the
other way (6.1 s against 7.7 s): spawning a worker re-imports numpy and
scipy, and on a short enough track that is the whole job.

## Putting dynamics back

"Over-compressed" is three injuries, not one, and the word "expander"
conflates them. `expand.py` has the argument in full; the short version:

| injury | over | measured by | repaired by |
|---|---|---|---|
| peak truncation | samples | `clip_runs` | `declip` |
| micro-dynamics | milliseconds | crest (peak minus loudness) | `restore_transients` |
| macro-dynamics | bars | LRA | `restore_range` |

**Only de-clipping recovers anything.** The other two reshape what
survived: a compressor that took 8 dB off a chorus did not record what it
removed. Worth doing, worth saying.

**Separating the timescales is what stops it pumping.** One gain trying to
serve both has to be fast enough for a snare and slow enough for a chorus,
and the compromise is audible as breathing. That is what a plain broadband
expander is, and why it is not what this does.

`restore_range` only ever attenuates. A loudness-war master has no
headroom -- that is what made it one -- so the loudest 5% is anchored and
everything below is pulled away. The levelling at the end of the chain
gives the average back, so the drop ends up louder than it started. Hits
its target to within about 0.06 LU.

`restore_transients` acts only where the signal is rising, so it cannot
turn a quiet passage down and therefore cannot breathe. About **0.5 dB of
crest per dB asked for**, measured; the setting is a ceiling on the gain
at an onset, not a promise about the statistic. Note the contrast with
`subbass.shape_attacks`, which is band-limited and deliberately does NOT
move crest.

**The DJ caution, which is the part worth arguing about.** Restoring macro
range makes a track duck in a mix: eight LU down in a breakdown and the
record disappears under the next one. Club masters are flat partly because
of the loudness war and partly because flat works. What "the drops hit
harder" actually wants is mostly the transient stage plus a modest range
target -- so both are off by default, and the survey's "wants" column is
there to be read before either is turned on.

Chain order: declip, range, transient, sub, level. Each stage wants the
signal the one before it produced, and the sub goes last because it is the
only one adding something that was never there.

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

**The A/B switch is confirmed too.** Shift-Space mid-track lands on the
same sample, with no tick and no flam -- which is what makes the
comparison above worth anything. A switch that clicked, or that jumped a
few milliseconds, would have been audible as a difference between the two
versions and indistinguishable from the processing. Scheduling both
versions together on one host clock, rather than starting one and seeking
the other, is what does it.

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

1. **The dynamics stages have never been set from THIS library.** Both
   are built, tested and off by default, and their thresholds come from
   the published ranges rather than from anything measured here. The
   survey now reports LRA and crest per folder with a "wants" column;
   measure the 1990s material and set `target_lra` and `min_crest` from
   what comes back, the way `eighties` got its cap of 11.
2. **Serato markers only travel MP3 to MP3.** FLAC and M4A carry them
   too, in Vorbis comments and com.serato.dj atoms, but going between
   containers is translation rather than copying and needs a real Serato
   file of each to check against.
3. **Nobody but Jeff has run this.** No licence file, no signing
   identity, and ffmpeg's licensing needs a real answer before anything
   is sold. `libmp3lame` is GPL.
