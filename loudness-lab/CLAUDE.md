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
python3 tools/check_profiles.py              # the two profile lists agree
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

Five checks run without a Swift toolchain, so they work anywhere. Each one
exists because the mistake it catches cost a round trip to a Mac:

```sh
python3 tools/check_golden.py    # will golden.json decode into the Swift structs?
python3 tools/check_manifest.py  # will the manifest the Python writes?
python3 tools/check_help.py      # does every setting have help text?
python3 tools/check_profiles.py  # do the two profile lists agree?
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
- **`$VAR…` in a shell script breaks on macOS.** The shell there reads the
  first byte of a non-ASCII character like `…` as part of the variable
  name, so `"Building $CONFIG…"` looked up `CONFIG?` and `set -u` stopped
  the build with `CONFIG?: unbound variable`. Linux does not, so nothing
  here catches it: write `${CONFIG}…`.
- **A report from a stale checkout reads as current.** The 2026-09-26
  kick reports came from code two merges old -- no machine check, Maniac's
  sub still at 63 Hz -- and nothing in them said so. `Measure Kick
  Detection.command` now pulls first, stops if it cannot, and writes the
  version at the top of the report.
- **Folder grouping uses `Library.folderLabels`,** not the parent's name:
  two compilations each with a CD1 otherwise merge into one corpus, and a
  corpus silently averaged with another is a wrong number that looks
  exactly like a right one.

## Layout

```
loudnesslab/     the Python: bs1770, spectrum, subbass, declip, expand,
                 air, mp3gain, decode, db, report, render, write, cli,
                 stems (Demucs: a drum stem for kicks, a guide for air),
                 machine (drum machine? the kick's own sound; measured only)
tests/           its tests
tools/           make_golden.py, the five checkers, measure_stem_kicks.py
macapp/
  Sources/LoudnessKit/    the port: DSP, Loudness, Process, IO, Library
  Sources/LoudnessLabUI/   the interface, as a LIBRARY: Engine, ABPlayer, Views.
                          DiscoTags embeds it as its Loudness tab, so this
                          is shared code, not this app's alone.
  Sources/LoudnessLabApp/  just the window and the menu bar
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

`restore_range` declines when a track is already within 0.5 LU of the
target, matching the sub's rule. CD2 above needed it: at 6.49 against a
target of 7.0 the stretch is 0.079, half a decibel at the quietest point
of the record, which is arithmetic rather than a restoration.

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

Chain order: declip, range, transient, sub, air, level. Each stage wants
the signal the one before it produced. The sub is late because it adds
something that was never there; air is later still because it generates
from what is there, and by then what is there is finished.

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
| Now Yearbook 99 (2026), 4 CDs | -2.49 to -3.64 | 29% to 60% | 5.40 |

### Air, and why the top-end table now goes to 20 kHz

`topShapeBands` stopped at 16 kHz while its own comment said the range was
"where an MP3's low-pass usually shows itself". That is wrong for the
bitrates this library actually holds: 128 kbps cuts near 16k, but 320
cuts near 20k and never touches the 16k band at all. The measurement
could not see the thing it was named for.

The 20 kHz band was being measured and stored the whole time -- the
spectrum runs to 20k -- and simply was not shown. It is now, with the
16k-to-20k drop beside it as `cliff`.

That is the number that answers whether air is an option, because a shelf
can only lift what is there. Recorded music rolls off a few dB across that
step; a codec falls off a wall.

### The exciter

Built, because a shelf is the wrong tool and asking for one on this
material would have done nothing. `air.py` high-passes the track, runs
the result through an asymmetric soft-clip, and mixes the harmonics back:
5 kHz of material becomes 10 and 15 and 20 kHz of new content. On a
fixture with everything above 16 kHz removed, a 3 dB shelf moved the
16-22 kHz band by 3 dB -- which is 3 dB more of nothing -- and 3 dB of
air moved it by 16.

**It invents, and that is stated rather than implied.** Every other stage
restores something a measurement says was taken away. These harmonics
were never in the recording. So it is off by default, and the report says
what the band actually did rather than what was asked for.

Four things it has to get right, each measured:

- **Aliasing.** A non-linearity makes harmonics without end and every one
  above Nyquist folds back down as an inharmonic product -- grit, landing
  in the region being polished. On a 7 kHz tone the 4th and 5th fold to
  20 kHz and 13 kHz at -29.6 and -38.8 dB. Run the curve at 4x and filter
  on the way back: -91.1 and -97.7. Sixty decibels, for one resampling
  either side.
- **The linear term.** `tanh` is very nearly linear near the origin, so
  the harmonic path carries a scaled copy of the source, adds coherently
  and overshoots -- +1 dB asked for came back as +3.13. Subtracting the
  curve's small-signal gain leaves only what is non-linear. Without it
  the stage is a high shelf with grit on it and the whole argument for it
  is false.
- **The cross term.** The second harmonic of 4-8 kHz lands at 8-16 kHz,
  where the source already is, so dry and wet are correlated. Assuming
  they were not undershot by 18% at drive 3. The gain is solved as a
  quadratic instead and the amount is then exact to 0.02 dB.
- **What it costs.** Loudness barely moves (+0.04 dB at 2 dB of air),
  which is the famous property. Peak moves a great deal, because the
  harmonics land on the source's own peaks -- and it is real sample peak,
  not intersample overshoot. The levelling takes it back out, which is
  why this is a small control.

`drive` is 0.5 and was measured, not chosen. Because the band energy is
normalised, drive does not change how much air comes out; it changes what
it costs in peak, and that cost is a U:

    drive   0.25   0.50   0.75   1.00   1.50   2.00   3.00
    peak +  2.50   2.11   2.47   2.79   3.34   3.77   4.33

with the 16-22 kHz content flat throughout. Half is the floor.

Top end runs above the reference in fifteen of sixteen folders, +1.47 to
+7.48, so there is nothing to add up there. The exception is `Disco
Music` at -1.13, and that is the cliff rather than the mastering.
Levelling to -16 needs no track turned up.

**The 1999 corpus is the one the dynamics stages were built for**, and it
is the first here whose problem is not a missing low end. By 1999 the
bottom end was being put there: 2.5 to 3.6 dB short, against 6.2-10.9 for
the eighties. What is wrong with it is the loudness war itself --

    median LUFS-I  -9.48      median true peak  +0.86 dBTP
    median s_p95   -7.71      median LRA         5.40
    median crest              10.01 dB
    arrived clipped           36 of 82 (43.9%), CD4 at 60%
    worst offender            9652 clipped runs

-- crest at 10.0 sitting in the hard-limited band (8-11) and LRA at 5.4 in
the loudness-war band (4-6). Hence the `nineties` profile: a sub capped at
4, de-clipping on, `target_lra` 7.0 and `transient` 3.0.

Per disc:

| disc | LRA | crest | clipped |
|---|---|---|---|
| CD2 | 6.49 | 9.88 | 29% |
| CD3 | 5.45 | 9.95 | 38% |
| CD4 | 5.66 | 10.47 | 60% |
| CD1 | 4.44 | 10.73 | 50% |

**LRA and crest run in opposite directions here** -- r = -0.80, on four
folder medians, so suggestive rather than settled. CD2 has the most range
left and the least punch; CD1 the reverse. A single "how squashed is it"
number would call CD2 the healthiest disc and CD1 the worst, when they are
damaged in different ways and want different stages. That is the two-stage
design being right about real music rather than about a fixture, which is
the only evidence for it that counts.

One prediction was checked and was slightly wrong: crest estimated from
the medians (median peak minus median loudness) read 10.34 against a
measured 10.01. Close, as it was said to be, and not the same number.

**A second one was wrong and is withdrawn.** On those four discs crest and
clipped correlated at +0.82, and the reasoning offered for it -- that a
clipped master has its peak pinned at full scale -- sounded good enough to
write down. Across eleven folders it is **-0.05**. There is no relationship;
the +0.82 was four points of noise. The standing rule about not deciding
anything from a library average applies just as well to a library of four.

## What the whole library says about dynamics

Sixteen folders, measured together. `cliff` is the 16k-to-20k drop:

| folder | LRA | crest | clipped | cliff |
|---|---|---|---|---|
| DISCOinferno GOLD, Disc 01 | 4.10 | 12.92 | 53% | 10.7 |
| DISCOinferno GOLD, Disc 02 | 3.91 | 12.23 | 76% | 10.6 |
| 1988 - Dance Music | 3.35 | 12.15 | 0% | 11.8 |
| 1977 - Dance Music | 4.23 | 12.11 | 7% | 7.7 |
| 1980 - Dance Music | 4.26 | 12.10 | 0% | 8.9 |
| Acid House & Rave Peak-Time | 5.93 | 11.95 | 0% | 10.3 |
| 1983 - Dance Music | 4.18 | 11.91 | 0% | 9.3 |
| 1974 - Dance Music | 5.06 | 11.87 | 0% | 9.6 |
| 1986 - Dance Music | 4.15 | 11.82 | 0% | 10.4 |
| 1990 - Dance Music | 4.38 | 11.78 | 0% | 12.9 |
| Now Yearbook 99, CD1 | 4.44 | 10.73 | 50% | 6.9 |
| Now Yearbook 99, CD4 | 5.66 | 10.47 | 60% | 6.7 |
| **Gathered/New Music 2026-08-14** | **5.45** | **10.21** | 0% | 12.2 |
| Now Yearbook 99, CD3 | 5.45 | 9.95 | 38% | 10.0 |
| Now Yearbook 99, CD2 | 6.49 | 9.88 | 29% | 8.8 |
| **Disco Music** | 2.97 | 9.63 | 0% | **27.0** |

Four things follow.

**The reference corpus is itself compressed.** It sits at crest 10.21 and
LRA 5.45, in the same band as the 1999 pop and below every pre-1990 folder
in the library. For low end it is the thing to aim at; for dynamics there
is nothing here to aim at, which the sub stage's design note predicted and
this measures. `target_lra` and `min_crest` are absolute figures for that
reason, and have to stay absolute.

**The `min_crest` gate is 11, and the 12 it started at was wrong.** On
eleven folders 12 looked vindicated: unlimited-era material read 11.87 to
12.11, 1999 pop 9.88 to 10.73, nothing in between, and that was written
down here as "the threshold was lucky, and is now evidence". Five more
folders filled the gap in. Sixteen read

    9.63 9.88 9.95 10.21 10.47 10.73 | 11.78 11.82 11.87 11.91 11.95
    12.10 12.11 12.15 12.23 12.92

and the largest gap is 10.73 to 11.78, midpoint 11.25 -- wider than any
other gap in the set, and nowhere near 12, which cuts the upper cluster
five and five. The gate is now 11. It changes nothing for the 1999
material, which passes either; it changes what happens to everything
else.

That is twice now that a clean-looking result on this library has
dissolved when more of the library arrived. Both times the tell was the
same: a claim resting on there being nothing in a gap.

**Sixteen folders, and one of them is not a mastering problem at all.**
`Disco Music`, 51 tracks, measures a 16k-to-20k cliff of **27.0 dB**
against 6.7 to 12.9 for every other folder in the library -- a wall, not a
roll-off, and the signature of a low-bitrate encode. It is also the only
folder whose top end sits BELOW the reference (-1.13), and entirely
because of that cliff: its 8k, 10k and 12.5k bands are ordinary.

So the one folder that looks like it needs air is the one where air
cannot help, because the content is not missing from the mastering, it
was thrown away by an encoder. No stage here can put that back. It wants
re-ripping, and the table now marks it with a `!`.

**LRA and crest run opposite, r = -0.85 over eleven folders.** The
anti-correlation first seen on four discs held on a larger sample. The
old material has the punch and none of the range; the new material has
what range there is and no punch. No single "how squashed is it" number
orders this library correctly, which is the whole case for two stages.

### Levelling and dynamics cannot interact

Asked directly, and worth writing down because the intuition goes the
other way: a lower target does not "leave room for" dynamics and a higher
one does not cost them.

Levelling multiplies the whole file by one number. LRA and crest are both
DIFFERENCES of loudnesses -- P95 minus P10, peak minus integrated -- and a
constant offset cancels out of a difference. Measured: LRA holds to about
1e-9 under gains from -16 to +4 dB, and crest to about 1e-6, the residue
being in the true peak's 4x oversampling rather than in any loudness.
`TestLevellingAndDynamicsAreIndependent` keeps it that way.

So the target is chosen for headroom and consistency, not for range. On
this library, -16 is where every track can be hit exactly: 0% need a
boost, against 20.8% at -10 and 55.1% of that same set breaching the peak
ceiling. A target that cannot be reached is not a target -- those tracks
land wherever the ceiling stops them, which is the opposite of levelling.
Moving to -11 would buy nothing for range and cost the headroom the
transient stage spends.

### Low LRA is not always damage

The survey used to mark every disco compilation as wanting the range
stage, on LRA alone -- on records whose crest was the highest measured
anywhere in the library. A groove that holds one level for seven minutes
is the arrangement, not a compressor, and expanding it invents dynamics
the record never had.

So `wants` now needs BOTH to be low: **low LRA with crest intact is the
arrangement; low LRA with crest gone is the mastering.** The disco discs
now read `declip`, which is what is actually wrong with them.

## Stems: finding kicks on the drums

The sub stage finds kicks in 30-100 Hz of the full mix, which is where the
bassline is too. `stems.py` separates a drum part and `detect_kicks(...,
drums=)` reads that instead. **Only the detection moves**: the sub is
still added to the untouched original, so a separation artifact can shift
a kick marker and nothing else. `TestTheStemNeverReachesTheAudio` hands
`enhance` a stem full of hiss and checks none of it arrives.

`tools/measure_stem_kicks.py` scores it on synthetic tracks with known kick
times. With the TRUE drum part (a perfect separator) against the mix:

| scenario | mix recall / precision | true drums |
|---|---|---|
| groove (the existing fixture) | 0.94 / 0.91 | 1.00 / 1.00 |
| disco octave bass on the eighths | 1.00 / **0.44** | 1.00 / 1.00 |
| quiet kick under a loud sustained bass | **0.14** / 1.00 | 1.00 / 1.00 |
| plucked bass on the sixteenths | 1.00 / **0.30** | 1.00 / 1.00 |

The octave line is the one that matters for this library: on the mix,
every off-beat bass pluck reads as a kick, 117 onsets for 51 kicks, and
the sub stage lays a burst under each of them.

**A real separator has not been measured properly yet.** Demucs is the
intended one, and its weights could not be downloaded where this was
written. Spleeter could, and on these synthetic tracks it failed: it put
80% of the plucked bassline in its DRUM stem and the buried kick in its
bass stem. But changing only how fast the bass's upper harmonics die away
moved its octave precision from 0.44 to 0.85 -- so the synthetic tracks
say what a stem can do and not what a separator will do on a record.

Hence `--files`: on four-on-the-floor, the tempo implied by the median gap
between detected kicks should equal the BPM tag, and a detector firing on
an octave bass reads double. The next step is that, with Demucs, over a
disco folder and the 1999 discs. `Measure Kick Detection.command` does it
from Finder: it installs Demucs into `.venv` on first use (PyTorch too;
the model is about 80 MB), asks for a folder, and saves the report in `scans/`. By
hand:

```sh
.venv/bin/pip install demucs
.venv/bin/python tools/measure_stem_kicks.py --files <folder> --backend demucs
```

**Measured on a real disc: 100 Hits - The New Romantics, Disc 1.** Twenty
tracks, every one with a Serato BPM tag, Demucs on an Apple Silicon Mac.
Implied tempo against the tag, within 5%:

| | full mix | Demucs drum stem |
|---|---|---|
| matches the tag | 1 of 20 | 11 of 20 |
| exactly double the tag | 9 of 20 | 1 of 20 |
| anything else | 10 | 8 |

The mix detector fires on the off-beat as well as the beat -- nine tracks
at 1.91-2.06x, the eighth-note synth basslines this era is built on -- so
the sub stage has been laying half its bursts under bass notes on this
material. On the eleven the stem gets right it finds 0.85-1.02 kicks per
tagged beat: nearly every kick, almost nothing else.

Where the stem misses, the record is mostly why: Ghosts, 19, Vienna and
Love Missile F1-11 have no steady kick at all. Fascist Groove Thang reads
2x on both (a busy kick pattern, probably). Is It A Dream (1.45x), Karma
Chameleon (1.87x), Imagination (1.65x) and Turn Back The Clock (0.72x) are
unexplained and want listening to, not a theory.

**And on disco, fifteen tagged tracks** (ABBA, Bee Gees, Cerrone, Donna
Summer, Chic-era soul and funk): the stem matches the tag on 9, the mix
on 2. Kicks per tagged beat is the plainer number -- the mix finds 1.26 to
1.85 on EVERY track, including the two whose median tempo came out right,
so it has been adding bursts to the whole disco library, not some of it.
I Feel Love, the octave-bass record, is 1.33 on the mix and 1.00 on the
stem. The stem reads 0.97-1.10 on the nine it gets right.

Its misses: The Name of the Game reads 77.9 against a tag of 154 -- a
slow song, so the tag is probably the doubled one, unverified. How Deep Is
Your Love has no kick on every beat. Boogie Nights, Brick House, Best of
My Love and Hot Line read 1.7-2x on both detectors: funk, with kick
patterns busier than one per beat. Over both discs: stem 20 of 35, mix 3.

That suggests the shape of the real stage: detect on the stem, and use the
BPM tag as a gate -- where the kicks found do not agree with the tag, skip
the sub for that track and say so. The misses above then become tracks
left alone rather than tracks processed wrongly.

### Built: `subbass --stem-kicks`, "Find kicks on the drum track" in the app

Off by default, in every profile, because it needs Demucs and is slow the
first time. What it does:

- **Separates in the parent, once, before the pool.** `cli._separate_for_kicks`
  runs Demucs one track at a time -- a model per pool worker would multiply
  a gigabyte of memory by the worker count -- and emits `phase: "separate"`
  progress, which the app shows as "Separated n of m".
- **Keeps only what detection reads**: the drum stem's mono sum at 2 kHz,
  at most 2.2 MB for five minutes, in `stem-cache/` beside the database.
  Read back, it finds the same kicks as the stem, within 0.42 ms. Filed under a
  hash of the DECODED audio, not the file, because Serato rewrites a file
  every time a cue point moves and a file hash would throw the separation
  away with it. A second run separates nothing.
- **Filters the hits, never the track** (`subbass.select_kicks`, below).
  It began as a whole-track gate -- kicks implying 1x or 0.5x the tag, or
  no sub at all -- and that turned whole records away for a few wrong
  hits. The gate is gone; a track goes without only when too few kicks
  survive, which `enhance` already says.
- **A track that fails to separate** is not a failed run: the reason rides
  on the job and the worker skips only the sub, saying so.

**The first real run skipped four tracks** -- Tell It to My Heart, Push It,
Domino Dancing, Straight Up, at 1.8-2.5x their tags. Not the bassline this
time: on the drum STEM, a LinnDrum snare, an 808 clap, floor toms and
scratching all have an attack the detector's band hears. So
`subbass.select_kicks` now filters each hit:

- **Weight**, not shape. A kick is among the heaviest hits in 30-90 Hz;
  on synthetic drums every kick sat within 1.3 dB of the loudest, a snare
  or scratch alone about 25 dB under. The first version asked instead
  whether the hit was ONLY a kick (30-90 Hz against 140-600 Hz) and threw
  away every kick with a snare on top of it -- 20 of 51 on one fixture,
  the whole of 2 and 4 on disco. `MIN_KICK_LEVEL_DB` is -10, halfway.
- **The beat.** With a tag, hits more than 12% of a beat off the grid go:
  fill notes, scratches, and syncopated kicks with them (one fewer burst,
  never a wrong one). The grid is found locally, from the kicks eight
  beats either side, so a live drummer's drift is followed -- tested at
  up to 3% tempo wander.
- **A grid that does not fit is not used.** Four-on-the-floor tagged at
  HALF its tempo would be thinned to every other kick. How firmly the kicks
  agree on where the beat is tells: 0.01 in that case, 0.42 or more in
  every correctly tagged one. Under `MIN_GRID_COHERENCE` (0.25) the grid at
  DOUBLE the tag is tried, which fits that case exactly; if neither fits,
  the weight filter works alone, as with no tag. Nothing is refused.

On the backbeat fixture built from those four tracks' ingredients:
precision 0.40 -> 0.88. Recall 0.79, the syncopated
kicks. The one wrong hit let through is the lowest floor tom where a fill
ends on the beat -- a kick's weight, on the grid. All the earlier
scenarios keep every kick. Every constant here is from synthetic drums;
`measure_stem_kicks.py --files` now prints a `+filter` column, what each
filter dropped and the grid agreement, which is how they get checked
against a real kit.

Demucs is still not in `requirements.txt`; `Measure Kick Detection.command`
installs it, and the command refuses `--stem-kicks` with that instruction
when it is missing. Not yet confirmed on the Mac: the Swift has not been
compiled with these changes, and no processing run has used the stem yet.
The first one wants an A/B by ear against the same tracks from the mix.

### 808s: a question the report now asks

After the filters, Pet Shop Boys (an 808 record) processed but by ear got
little drum depth, and "caught a little of the bass line". Two suspects,
not yet told apart:

1. Demucs puts an 808's boom in the BASS stem -- it is a tuned, slowly
   decaying sine, which to a separator looks like a bass note -- leaving
   the drum stem only the click.
2. The kicks are found, but the burst is wrong for them: 45 Hz and 0.12 s
   under a kick tuned to 50-60 Hz that rings for half a second, and an
   `auto` amount sized small because the 808 already fills the band.

**Measured, and it was suspect 2.** Twelve 1988 dance records (Pet Shop
Boys, Salt-N-Pepa, Rick Astley, Yazz, M/A/R/R/S...), through Demucs:

- Bass-stem share of the kick's low end: 1-18% on eleven, 49% on one
  (Straight Up). Demucs keeps these kicks in the drum stem. Suspect 1 out.
- Kick pitch 58-84 Hz, most 61-74. Tail to -20 dB 74-252 ms, most
  100-130. The burst was 45 Hz ringing to -20 dB at about 280 ms: a
  second, lower note under every kick, outlasting it. Suspect 2.
- After the filters the tempo matched the tag on 10 of 12 (mix: 0).

So with `--stem-kicks` the burst is now TUNED per track
(`subbass.kick_voice`, `tuned_burst`): the kick's pitch and tail measured
on the drum stem at the kept kicks (a sample of 64), then the burst an
octave under the kick -- or at the kick's own pitch when an octave down
falls under 31.5 Hz, which keeps 45 Hz disco kicks at 45 -- decaying to
fall 20 dB when the kick does (decay 30-200 ms). Measured on synthetic
kicks at 55-84 Hz: pitch within 0.5 Hz, tail within 15 ms. Without the
stem the fixed 45 Hz, 0.12 s burst is unchanged.

The grid is the other finding: Domino Dancing, Buffalo Stance and Push It
lost 224-420 hits each as off-beat, most likely real syncopated kicks.
`--files` printed how firmly the kicks sit on quarters, eighths and
sixteenths, and each record has a grid it plainly follows: straight ones
quarters (0.95-1.00), Bananarama and Kylie eighths (1.00, against 0.87
and 0.79 on quarters), Buffalo Stance sixteenths (0.96, against 0.37).

So the grid is now picked per track: the tag's quarters, eighths or
sixteenths, whichever the kicks sit on most firmly, the coarser of two
within 0.05. A tag at half the tempo is simply the eighth grid, so the
"try double the tag" step is gone. And a grid is used only at a fit of
0.5 or better -- good fits read 0.79 and up, poor ones 0.11-0.37, and
Domino Dancing's 0.32 had been dropping most of its kicks -- otherwise the
weight filter works alone. On the synthetic backbeat that takes recall
from 0.79 to 1.00 (the syncopated kicks) and precision from 0.88 to
0.76-0.91: low floor toms in fills sit on a sixteenth grid too.

`--files` now prints, per track, the share of the kick-band energy at the
kept kicks that sits in the bass stem, and the pitch and tail of the
kick's low end measured on drums and bass together (the tail up to the
next kick at most, marked ">" when still ringing). Checked on a synthetic
808: 100% vs 0% by which stem holds the boom, 55 Hz exactly, tail 784 ms
against a true 806.

### 1983: the tuned sub was too short, and quiet passages lost their kicks

Jeff on the 1983 folder: Maniac "rough on the bottom, missing all sorts,
awkward pumping"; Flashdance "three weird bottom outs mid-song where it
goes flabby"; Blue Monday "could be deeper"; She Blinded Me With Science
"the bass line is the kick drum and we are missing it". The report on ten
of those records:

- **Detection was not the problem on Maniac**: 146 kicks a minute at 159
  BPM, 0.93 on quarters, 4 dropped as light.
- **The sub was a thump.** Drum-machine kicks here fade in 38-82 ms, so
  "fade when the kick does" put EIGHT of ten tracks on the 30 ms decay
  floor -- about one cycle of a 32-43 Hz tone. And the amount asked for
  (up to +11 dB) had to come from bursts that short, so each was very
  loud: rough, and pumping. `TUNED_MIN_CYCLES` = 4 now keeps every burst
  ringing at least four cycles of its own pitch to -20 dB (127 ms for
  Maniac's 31.5 Hz). Four is a judgement, not a measurement.
- **A quiet passage lost every kick.** Weight was judged against the
  loudest hits in the whole track, so a verse or a build 15 dB under the
  chorus dropped all its kicks as "too light" -- no sub there, beside
  passages given the full amount. It is now judged against the loudest
  hits within 2 s before and 2 s after, separately, taking the quieter
  side (an 8 s window, and then a 2 s one spanning the edge, still lost
  half of a 6 s quiet passage), and never lower than 12 dB under the
  track's loudest, so a breakdown of snare and hats does not promote its
  snares. Quiet passages down to 15 dB keep every kick. The cost: in a
  breakdown with no kick, a tom fill's higher toms now pass too.
  Below about 16 dB `detect_kicks` itself does not see an onset (its gate
  is 15% of the 95th-percentile envelope), which is a separate limit.
- **The report now lists every stretch over two bars with no kick
  kept**, with times and why the hits in it were dropped, to hold against
  where a bottom-out was heard.

Not yet done: the bassline. On She Blinded Me With Science and Blue
Monday the low end is carried by the bass, and a sub laid only under
kicks cannot follow it.

### Every kick the same burst, and more or less than the reference

After the fixes above, by ear: Maniac's sub "drops out and comes roaring
back in, and fades out and back in over the song, although the rhythm
section never changes"; Flashdance got "four overdrive bass beats" mid-
song; Blue Monday "still a little light, more like +3 dB".

The first two were one flaw. Each burst was scaled by how hard its hit
was on the drum stem, against the hardest hit in the track. That followed
the separation, not the drummer: a drum machine that never changes read
as drifting, and a few hard hits (a fill, most likely, and one the local
weighting now lets through when no kick is near) set the scale, got full
bursts, and left the rest a fraction. Every kept kick now gets the same
burst. The cost is that a softer passage no longer gets a softer sub; the
report prints how much the kept kicks vary on the stem, 10th to 90th
percentile, since that is what this decision rests on.

A rerun of the report after the 1983 fixes showed Flashdance's only
stretch without kicks is its drumless intro (0:00-0:47), so its mid-song
"overdrive" was the burst scaling above and not a gap. It also showed the
octave rule's edge: Maniac's kick read 63 Hz one run and 62 the next, and
"an octave down only if that reaches 31.5 Hz" turned that into a sub of
31.5 one time and 62 the other. The octave down is now taken whenever it
is at least 28 Hz (`SUB_FLOOR_HZ`), raised to 31.5 if under -- so the edge
sits at 56 Hz, below where these kicks cluster (61-66), and disco's 45 Hz
kicks still keep the sub on their own pitch.

Blue Monday is `sub_offset` ("More or less than the reference", -6 to +6
dB): added to each track's measured shortfall before the cap, so +3 is 3
dB more than matching the reference, and a track at the cap needs the cap
raised too.

### Drum machines: two numbers to tell them from drummers

Synth-pop -- New Order, Pet Shop Boys, Yazoo, Erasure, Depeche Mode -- is
played by machines, and a machine plays ONE kick recording, exactly on its
grid. If that shows plainly on real records, those tracks can be handled
better than by guessing hit by hit: find the kick by matching its sound
(a snare or tom is a different sound however loud; a quiet kick is the
same sound), trust the sequencer's repeating pattern, and build the sub
from the kick itself. Before building any of that, `machine.py` measures,
and the report prints per track:

- **How closely the kicks match their own average**, after lining them
  up to the sample (`kick_template`): the median and the 10th percentile.
- **How far they land from the grid** (`grid_jitter_ms`), using those
  aligned onsets, the grid placed locally so a tag a fraction off the real
  tempo is followed and does not read as timing.

On synthetic drums: a machine 0.993 / 0.992 and 0.03 ms; a drummer with
5-20 ms timing 0.963-0.965 median, 0.875-0.885 at the 10th percentile,
and 2.4-8.8 ms (about 0.67 of the timing's standard deviation, as a
normal distribution's median absolute value should be). Grid distance
separates them by about eighty times; the median similarity barely does
-- my synthetic drummer varies only a little -- and real records add
bleed over the kicks that will pull a machine's similarity down. Which
number holds up is for the 1983, 1988 and a disco folder to say.

**Measured on 48 records (1977, 1983, 1988, 1990): timing tells a machine
from a drummer only up to the mid-80s, and similarity never does.**

- 1983 and 1977 split cleanly: every drum machine 0.48-1.32 ms from the
  grid (Holiday, Sweet Dreams, Blue Monday, Flashdance, Safety Dance),
  every drummer 3.0 ms or more. Stayin' Alive, a tape loop of one bar,
  1.88. I Feel Love 3.55 -- its sequencer is a machine, its kick was
  overdubbed by hand, and the measure heard that.
- 1988-90 fill the gap in: Rick Astley 1.75, INXS 2.08, Technotronic
  2.40, Opposites Attract 2.70, Vogue 3.18 -- all machines -- beside
  Black Box and Deee-Lite at 4.3-4.6 on sampled loops. Samplers under
  sequencers slop by milliseconds and a sampled break keeps its drummer's
  timing. The third time here that a clean gap dissolved when more of the
  library arrived; no machine/drummer switch was built on it.
- Kicks matching their average: machines 0.95-0.99, and so were the Bee
  Gees (0.985) and I Feel Love (0.991). No use for machine vs drummer.

**What the match DID pick out is the tracks that go wrong.** Clean tracks:
0.97-0.99, kept kicks varying 1-3 dB. Troubled ones: Domino Dancing 0.69
and 12.2 dB, Tell It to My Heart 0.75 and 14.2, Push It 0.70, Pump Up the
Volume 0.74 and 13.2, What Time Is Love 0.47 and 18.1, Unbelievable 0.67
and 11.0, Maniac 0.89 with a 10th percentile of 0.23 and 12.3 dB. What
passes the weight filter there is kicks plus other heavy drums --
percussion, toms, stabs -- and the grid is fitted to that mixture, which
is why none fits Domino Dancing or Tell It to My Heart.

### The kick's own sound: `select_kicks(by_sound=True)`

`machine.sounds_like_the_kick` keeps a hit only if it sounds like the
track's kick, and runs between the weight filter and the grid, so the grid
is fitted to kicks. Machine or drummer does not matter.

- **Compared in 30-120 Hz only**, at 2 kHz, over 60 ms, lined up within
  3 ms. On the synthetic kit: a kick again 1.00, a kick with a LinnDrum
  snare on top 0.91-1.00 even with the snare half as loud again as the
  kick, toms 0.12-0.41, a scratch 0.26, a clap 0.05, a snare 0.19. Across
  30-2000 Hz that loud snare takes the kick to 0.53 -- the mistake the
  first weight filter made, and a test holds it.
- **The kick is the most common sound, not the heaviest.** The hit that
  sounds like the most others (0.7 or better, `MIN_SOUND_MATCH`) is the
  kick; the ones like it make the template. A first version learned from
  the heaviest half, and a low tom that rang longer than the kick, half
  as often, became the template.
- Synthetic results: the backbeat's precision 0.77 -> 1.00 with recall
  1.00 -> 0.98, and its grid from sixteenths to eighths, which is what its
  kicks are on; every other scenario keeps its kicks. The one kick lost
  in each is the first in the file, at 0.000 s, whose onset the detector
  places 10 ms late -- with a second of lead-in it matches at 0.9997.

**Measured only.** The report prints a `+sound` column and a `by sound:`
line (dropped, grid and fit after, kicks a minute, match, ms from the
grid); processing does not use it. It goes in if Domino Dancing and Tell
It to My Heart get a grid that fits, and the clean tracks lose nothing.

### Air: why none arrived, and air that follows the stems

The 1988 folder got no air on any track, and not by accident: with `auto`
on (the eighties profile), `--air` is a ceiling and each track gets its
8-20 kHz shortfall against the reference -- and that folder measures 4.56
dB BRIGHTER than the reference, so every track's shortfall was nothing.
`--air-fixed` ("Same air on every track") gives every track the figure
as set while the sub is still sized per track (`cli._air_for`).

`--air-stems` ("Air follows the vocals and instruments"): at separation
time the balance of 2-10 kHz energy between vocals+other and drums is
kept, as an envelope at 100 frames a second, beside the kick source
(`stems.load_air_guide`). The exciter's gain is set exactly as without it,
then its harmonics are scaled by that balance -- so where vocals and
instruments carry the top end the track gets precisely the air the same
setting gives unguided, and where hi-hats and cymbals do (bright already,
and where an exciter turns to grit) less or none. Subtler overall by
design. The harmonics are still made from the original: the stems steer,
nothing separated is heard. No guide for a track means no air on it, not
air everywhere. Separations from before the guide existed are redone
once when guided air is asked for.

An earlier draft described the setting as "the rise where the guide is
open". A test on a fixture whose voice had almost nothing above 8 kHz
showed that was false (+37 dB there, relatively) -- the statement above
is the one the code keeps, and the one the test holds it to.

### Punch put high-frequency artifacts on late-80s pop

Confirmed by ear on a Paula Abdul track processed with Punch at +3.5 dB:
audible high-frequency artifacts, gone with Punch at 0 and everything else
the same. `shape_attacks` lifts 2-6 kHz at each kick with a 1 ms rise and
an 8 ms fall. On disco that band at a kick is mostly beater click; on
late-80s pop it is hi-hats, snare rattle, claps and vocal sibilance, and
a gain moving that fast over them is heard as tick and grit. No built-in
profile turns Punch on, and on this material it should stay off until
the shaping is made slower or band-aware.

## Open

1. **`Disco Music` is 51 files that want re-ripping, not processing.** A
   27 dB cliff at 16k means a low-bitrate encode, and nothing here can
   put back what the encoder discarded. Worth doing before any of it goes
   through a lossy stage and gets a second generation on top.
2. **The `nineties` profile has never been listened to.** Its settings
   come from one measured corpus, which is how every other profile here
   was set, but nothing has been processed with it and no ear has been on
   the result. The two figures to check afterwards are crest (predicted
   10.0 -> about 11.5) and LRA (5.4 -> 7.0); if either misses, the
   exchange rate measured on a synthetic fixture does not hold on real
   music, which is a finding worth having.
3. **Serato markers only travel MP3 to MP3.** FLAC and M4A carry them
   too, in Vorbis comments and com.serato.dj atoms, but going between
   containers is translation rather than copying and needs a real Serato
   file of each to check against.
4. **Nobody but Jeff has run this.** No licence file, no signing
   identity, and ffmpeg's licensing needs a real answer before anything
   is sold. `libmp3lame` is GPL.
