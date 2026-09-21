# loudness-lab

Measurement pass over a DJ library: BS.1770-4 loudness, short-term
distribution, true peak, and 1/3-octave low-end analysis, into SQLite.

**This tool never writes to an audio file.** It decodes, measures, and stores
numbers. Everything it suggests is printed as a dry run.

This is stage 1 of a larger normalisation project. The point of doing
measurement on its own first is that it answers, against your own records,
two questions that decide whether the rest of the project is worth building:

1. **Does the choice of loudness estimator actually matter?** If normalising
   on the 95th percentile of short-term loudness lands within a few tenths of
   a dB of normalising on integrated loudness across your library, the whole
   short-term-versus-integrated argument is academic and you should just run
   `mp3gain` and move on.

2. **Is the weak low end on older records missing sub, or congested
   low-mid?** These need opposite fixes. Boosting 40 Hz on a record that has
   nothing there just raises the rumble; cutting 250 Hz on a record that is
   congested there is cheap, safe, and often does more for perceived weight.

## Install

```sh
brew install ffmpeg          # the only external dependency
./setup.sh
```

`setup.sh` creates a private `.venv` and installs numpy and scipy into it,
then runs the test suite. It does not touch your system Python -- recent
macOS and Homebrew Pythons refuse a plain `pip3 install` with
`externally-managed-environment` anyway. The `./loudness-lab` launcher finds
the virtual environment by itself, so there is nothing to activate. Re-running
`setup.sh` is safe.

## Use

```sh
# Everything in one command: analyse, then print and save every report.
./loudness-lab scan "~/Downloads/100 Hits - The New Romantics (2011)"
```

That writes `scans/<folder-name>.db` and `scans/<folder-name>.txt`. The
individual commands, if you want them separately:

```sh
# Check the environment and the library before committing to a long run.
./loudness-lab doctor "/Volumes/Card/DJ Music/Converted Wedding"

# Analyse. Resumable -- re-running skips files that have not changed.
./loudness-lab analyze ~/Music/Serato --db library.db

# Several folders into one database. A file reachable from more than one of
# them is analysed once.
./loudness-lab analyze "~/Music/Dance/1A" "~/Music/Dance/1B" --db library.db

# Try it on 200 tracks first.
./loudness-lab analyze ~/Music/Serato --db library.db --limit 200

# The two reports that matter.
./loudness-lab report loudness --db library.db
./loudness-lab report lowend   --db library.db

# Low end grouped by folder rather than by year-derived era. Use this when
# the library is compilations, whose year tags are reissue dates, and name
# the corpus the others should be measured against.
./loudness-lab report lowend --db library.db --by folder \
    --reference "New Music 2026-09-02"

# Grouped by the folder each track sits in. If the folders are Camelot keys,
# this is the test of whether low-end shape tracks the KEY rather than the
# mastering -- which is what would make spectral matching dangerous.
./loudness-lab report folders --db library.db

# What a given normalisation would do, per track. Writes nothing.
./loudness-lab report tracks --db library.db --estimator s_p95 --target -14

# Lossless gain. Dry run by default; --apply writes.
./loudness-lab gain "~/Music/Album" --db library.db --target -12
./loudness-lab gain "~/Music/Album" --db library.db --target -12 --apply

./loudness-lab report errors --db library.db
./loudness-lab export --db library.db --out tracks.csv --what tracks
./loudness-lab export --db library.db --out bands.csv  --what bands
```

Quote any path containing spaces.

`doctor` is a preflight check, not the analysis. It reports the Python,
numpy, scipy and ffmpeg it found, counts the audio files under a path
(recursively) and the folders they sit in, names the file types it passed
over, then decodes **one** file to prove the codec path works and extrapolate
the full run time. `analyze` is what processes everything. Run `doctor` first;
it is also the most useful thing to paste when something goes wrong.

If a library comes back smaller than expected, `doctor` says which of the
three causes it is: an extension not in the recognised list, a folder that
could not be read, or a path that pointed at a single file rather than a
folder.

Roughly 50-100x realtime per core, decode-bound. A 20,000-track library is a
few hours on 8 cores and only has to run once. `--jobs` defaults to half the
core count because each worker holds a whole decoded track in memory (a
12-minute extended mix is about 280 MB at 48 kHz stereo float32).

## What is measured

Per track, in `loudness`:

| Field | Meaning |
|---|---|
| `lufs_i` | Gated integrated loudness, BS.1770-4 |
| `s_p95`, `s_p90`, `s_p50`, `s_p10`, `s_max` | Percentiles of the short-term (3 s) loudness distribution |
| `lra` | Loudness range, EBU Tech 3342 |
| `true_peak_dbtp` | Peak of the 4x-oversampled signal |
| `sample_peak_dbfs` | Plain sample peak, for comparison |
| `crest_db` | `true_peak_dbtp - lufs_i` |
| `clipped_samples`, `clip_runs` | Runs of consecutive full-scale samples: the signature of a master that arrived already clipped |

Per track per 1/3-octave band (31 bands, 20 Hz to 20 kHz), in `bands`:

| Field | Meaning |
|---|---|
| `ltas_db` | Long-term average level in the band, dBFS |
| `shape_db` | The same relative to the track's own broadband level, so it describes the spectrum rather than the volume |
| `p10_db`, `p90_db` | Spread of the band level over time. Content modulates with the arrangement; a noise floor does not |
| `side_mid_db` | Stereo width in the band. Strongly negative low down means the bass is mono -- a record cut for vinyl |

## Decisions worth knowing about

**Everything is measured at 48 kHz.** The K-weighting coefficients in
BS.1770-4 are published at that rate; deriving them for other rates is an
error source the project does not need. `decode.py` resamples on the way in.

**The year is the original recording date where a tag provides one.**
`originaldate`, `originalyear`, TDOR and TORY are checked before `date`, TDRC
and TYER, because on a compilation or remaster the plain date tag is the
reissue year -- a 2011 compilation of 1982 records would otherwise land in the
modern reference curve. Where only a release date exists the track is still
dated, but flagged, and the low-end report warns when enough of the library is
flagged that the era rows stop meaning anything. Group by folder in that case.

**Mono sources are upmixed to dual mono.** A mono record played in a club
comes out of both stacks, so that is the signal worth measuring. The original
channel count is kept in `tracks.source_channels`.

**True peak is 4x-oversampled**, which BS.1770-4 puts within about 0.5 dB of
the real peak. That, plus the fact that an MP3 re-encode moves peaks around,
is why the dry run aims at -1.0 dBTP rather than -0.1.

**The loudness engine is validated against ffmpeg's `ebur128`** on synthetic
signals in `tests/test_bs1770.py`, agreeing within 0.05 LU (ffmpeg only prints
to 0.1 dB, so that is the floor of the comparison). A Swift port should be
validated against this module in turn.

## A library that has already been normalised

Both reports check whether integrated loudness is implausibly uniform across
the library, and say so:

```
  ALREADY NORMALISED: 150 tracks sit within 0.02 dB of -11.51 LUFS-I.
```

Real music spans several dB. Anything tighter than 0.3 dB has been through a
loudness normaliser. Such a library is still fine to level -- you level what
you have -- but it must not be used as a *reference* for how an era sounds:
its crest, loudness range and true peak describe the normaliser's limiter
rather than the records, and any spectral shaping the tool applied is baked
into the band figures too.

This matters because reference curves are the one thing in this project that
depends on measuring the music rather than the file in front of you.

## Reading the low-end report

Two halves, different meanings:

* A **positive** number at 25-50 Hz in the difference table means that era has
  *less* sub than the modern reference. Whether EQ can fix it depends on
  whether there is content there at all -- check the modulation table.
* A **negative** number at 200-315 Hz means that era has *more* low-mid than
  modern masters. That is congestion, and cutting it is the cheap fix.

Caveats the report prints but which are worth repeating:

* The low bands contain few FFT bins, so they show 8-9 dB of `p90 - p10`
  spread on pure noise. Compare the modulation figures across eras, never
  against an absolute threshold.
* Bands more than 40 dB below broadband are marked `.` and their width figure
  is withheld. There is nothing there but anti-alias filter residue, which is
  uncorrelated and would read as *wide* -- inverting the vinyl-mono signal
  exactly where it matters most. This was a real bug, caught by the fixtures.

## One finding from building it

The claim this project started from was that the disagreement between
integrated loudness and short-term percentiles grows with loudness range.
The `loudness` report tests that, and on the synthetic fixtures it is too
simple: a track with a section 20 dB down has a large LRA but the estimators
still agree to 0.13 dB, because BS.1770's -10 LU relative gate discards that
section from the integrated figure too. The estimators diverge on tracks
whose sections stay *inside* the gate -- the fixture with a 6 dB swing shows
2.3 dB of disagreement at LRA 6.

So LRA is a poor proxy for "will the estimator choice matter here". Run the
report on real records before trusting either number.

## Profiles

A profile is a named bundle of settings, so a policy can be stated once and
audited rather than retyped:

```sh
./loudness-lab profiles                       # what exists, and every settable key
./loudness-lab gain    <path> --profile level-only
./loudness-lab subbass <path> --profile restore --reference "New Music 2026-09-02"
```

Three are built in. `level-only` is lossless levelling and nothing else.
`restore` adds a sub sized per track against a reference corpus. `disco-70s`
is the same with numbers taken from measurement: three independent 1970s
disco corpora, 108 tracks, agreeing within about 3 dB from 32 to 63 Hz and
sitting 6-9 dB under a current reference, with nothing usable below 32 Hz.

A profile derived from measurement is a finding rather than a preference, so
it lives in the repository with the evidence that produced it. What cannot
ship with it is `reference`, which names a folder on your machine -- supply
that with `--reference`, or pin it in a local profile.

Your own go in `profiles.json` as an object of name to settings; anything
there adds to the built-ins or overrides one by name, and an unknown key is
an error rather than silently ignored -- a typo that changes nothing is a
policy that differs from the one written down.

An explicit flag always beats the profile, which beats the default. Flags
default to nothing rather than to a value, so "not given" can be told from
"given the same as the default"; otherwise a profile could never change
anything a flag also controls.

**A profile fixes the policy, not the treatment.** How much each track gets
still comes from measuring that track, which is why there are no era
profiles here. Every clean corpus in this project is a compilation carrying a
reissue date, so a rule reading the year treats a 1981 master as modern. And
within one era the spread between tracks at 32 Hz is 14-24 dB against roughly
5 dB between one era's median and the next, so a curve fitted to the era
moves the median and leaves most tracks further from the target than they
started. Measuring against a reference delivers era-appropriate treatment
without needing to know the era: a modern master measures at the reference
and gets only levelling; an eighties master measures short and gets a sub.

### Seeing the policy before running it

```sh
./loudness-lab subbass <path> --profile restore --reference "..." \
    --dry-run --summary-only
```

```
POLICY PREVIEW  (what this profile does, folder by folder)
  folder        n  level only   sub  gated  median    max
  Modern        3           3     0      0       -      -
  Old           3           0     3      0    +2.1   +3.3
```

Per-track rows say what happens to a track; this says what happens to a
library, which is what makes a policy something to agree to in advance
rather than audit afterwards. `--summary-only` drops the per-track rows,
which matters at library scale. A dry run decides from the database before
decoding wherever it can, so previewing a policy does not cost a full decode
of everything it is going to decline to touch.

## Lossless gain

`gain` is the one command that writes to audio files. It rewrites the 8-bit
`global_gain` field in each MPEG Layer III granule rather than re-encoding:
the decoder scales that granule by `2^((global_gain-210)/4)`, so subtracting 1
attenuates by exactly 1.505 dB with no decode, no re-encode and no generation
loss. Adding the step back restores the file byte-for-byte.

The cost is that level only moves in 1.505 dB steps. On a library needing a
couple of dB of attenuation that is a much better trade than a second lossy
generation; the dry run prints the quantisation error per track so you can
judge it.

`gain` measures anything it has not already measured, so pointing it at a
folder is the whole workflow -- no separate scan step, and no database path
to keep in step with it.

```sh
./loudness-lab gain "~/Music/Album" --target -12            # dry run, writes nothing
./loudness-lab gain "~/Music/Album" --target -12 --apply    # writes copies to gained/
./loudness-lab gain "~/Music/Album" --in-place --apply --yes
./loudness-lab gain --db scans/album.db --undo              # reverse in-place
```

It cannot touch the bottom end. `global_gain` is one broadband scalar per
granule, so this command moves level and nothing else. Spectral work means
decoding, filtering and re-encoding, which forfeits every guarantee above;
that is a separate stage with a separate risk profile, and it should write
FLAC or AIFF rather than a second lossy generation.

Guarantees, because the alternative is quietly damaging someone's records:

* **The ID3 region is never read or written.** Serato keeps cue points,
  beatgrids and waveform overviews in `GEOB` frames there. Only bytes inside
  audio frames change, so those survive byte-for-byte. Tested.
* **Silent granules are left alone, not counted.** Encoders emit granules in
  fade-ins and run-outs whose `global_gain` sits at or near zero, and one of
  them would otherwise pin an entire track. Granules with no data, or below a
  global_gain of 24 (at most -120 dBFS even in an impossible worst case), are
  skipped.

  A granule the shift pushes *across* that floor would read as inaudible
  afterwards and be skipped on the way back, so the gain log records those
  offsets and undo moves exactly the set that was moved. Holding the step
  back instead -- the first attempt -- meant a single granule sitting on the
  floor pinned the file just as effectively as one at zero.
* **Every write is verified by reversing it in memory** and checking the
  result matches the source byte for byte. If it does not, the file is not
  kept. That is stronger than comparing gain values, and it exercises the
  exact path undo will take.
* **A step applies to every granule or not at all.** Clamping granules
  individually would change one part of a track against another, which is the
  dynamics change this project exists to avoid. Where a file lacks the
  headroom, the step is reduced for the whole file and reported as clamped.
* **Frame CRCs are recomputed** where present, verified against LAME's own.
* **Copies by default.** Originals are only touched with `--in-place --apply
  --yes`, and that is reversible with `--undo`.
* **True peak never passes the ceiling** (`--peak-ceiling`, default
  -1.0 dBTP). Raising a quiet track toward a hot target would drive it into
  inter-sample clipping, which is the exact defect this project found in an
  already-normalised library. Where the ceiling binds, the step is floored
  rather than rounded, since rounding to the nearest 1.5 dB could land back
  above it.

After running it, Serato's stored auto-gain and waveform overview for those
tracks are stale. Let it re-analyse, and turn its own auto-gain off if you
want this tool to own loudness.

Only `.mp3` is supported: the trick is specific to the MPEG Layer III
bitstream. Lossless formats need no such trick, and re-encoding anything else
would defeat the purpose.

## Kick prototype: sub-bass and attack

`subbass` is the one stage that is lossy and irreversible. It exists to be
listened to, not to be run over a library.

```sh
./loudness-lab subbass "~/Music/Eighties" --amount 5 --punch 4 --limit 10
```

`--amount` adds sub under the kick; `--punch` emphasises its attack. Both use
the same kick detection, so a track is decoded and analysed once.

`--match TEXT` narrows to named tracks rather than the thinnest ten, which is
how you iterate on a setting. `--dry-run` reports and writes nothing.

### Letting each track set its own amount

One figure suits one corpus at a time: the same +5 dB that closes half the
gap on early-eighties material closes all of it on late-nineties material,
and does nothing useful to a modern master. `--auto` takes the amount from
each track's own measured shortfall against a reference folder instead:

```sh
./loudness-lab subbass "~/Music" --auto --reference "New Music 2026-09-02" \
    --max-amount 6 --dry-run
```

Two things stop it from acting where it should not. A track already within
half a dB of the reference is left alone. So is one whose sub octave holds a
static floor rather than a bassline -- lifting rumble is the one way this
does active harm.

That second test measures the **band's own envelope**, not its per-frame
level. The distinction matters and getting it wrong is not subtle: per-frame
levels are computed over 0.68 s windows, which average across several bars,
so a relentless groove -- the most musical low end there is -- scores LOW.
Measured that way a wall-to-wall funk record read 10.9 dB against 6.2 for
static rumble, and the record was skipped as having nothing musical to lift.
On the envelope the same two read 43.7 and 11.3.

The "how much does each band vary across the track" table in `report lowend`
has the same 0.68 s basis, so read it as arrangement dynamics -- intros,
breakdowns, drops -- and not as evidence of whether a band holds music.

It analyses, picks the ten tracks whose 31.5-63 Hz octave measures thinnest,
adds a kick-synchronised sub to each, and writes FLAC into
`subbass-preview/`. Originals are never touched.

Each track comes out as a **level-matched pair** -- `-- A original` and
`-- B sub+3dB` -- so they sort next to each other. Matching is the point: the
added sub raises loudness, and in any comparison the louder file wins whether
or not it is better, so an unmatched A/B would mostly measure level. Both are
brought down to whichever is quieter, so neither is boosted and neither
clips, and both are written as FLAC from the same decode so no codec
difference can creep in. `--no-compare` writes only the processed file.

**Why kicks rather than a subharmonic divider.** The measurements say 1980s
material sits 10-15 dB below modern in the 31.5-63 Hz octave while matching
it from 80 Hz up -- the shape a dbx 120 was built for. But a divider
flip-flops on zero crossings and needs a near-monophonic source; in a dense
mix the 70-140 Hz band holds the kick, the bassline and the bottom of
everything else at once, and an octave below the wrong partial is a wrong
bass note. In dance and pop most of the missing energy is kick, so this
detects the kick and lays a short decaying sine under it. Nothing is
pitch-tracked, so nothing can mistrack.

Two things that had to be got right, both caught by measurement rather than
by listening:

* **Detection keys on attack sharpness, not level.** A fast envelope rising
  above a slow one. Against synthetic tracks with known kick times, a
  bassline changing note on every beat and a kickless breakdown, this holds
  recall and precision near 0.9-1.0 from 96 to 174 BPM. A plain rising-edge
  detector managed 0.52 and 0.30 on the same material.
* **Filtering is zero-phase and onsets are backtracked to the attack.**
  Causal envelope filters put every onset 22-26 ms late, and at 45 Hz one
  cycle is 22 ms -- a burst that late flams against the kick and partly
  cancels the thing it was meant to reinforce.

The gain is the root of a quadratic rather than a ratio of powers, because a
burst deliberately aligned with the kick is correlated with what is already
there. It hits the requested figure to 0.01 dB.

### Attack shaping (`--punch`)

A transient shaper, not an expander, and the distinction is the whole point.
An expander keys on absolute level over tens of milliseconds and so changes
how loud passages sit against quiet ones -- it raises loudness range, which
is precisely what makes tracks disagree with each other. This keys on where
the kicks already are, acts over a few milliseconds, and adds no energy at
all: the band is renormalised to the level it started at, so the emphasis is
paid for out of the sustain.

Three properties are tested, because failing any one means it is mislabelled:

| Property | Why |
|---|---|
| Attack contrast rises | The effect |
| Loudness range unchanged | An expander would move it |
| Long-term spectrum unchanged | Without renormalising, this is a treble boost |

Note that **global crest factor barely moves, and that is correct**. A
band-limited change lasting eight milliseconds cannot shift a track's overall
peak-to-loudness ratio; crest read +0.02 dB while the attacks were plainly
being emphasised. Crest staying put says the track's dynamic character is
intact and only the micro-detail moved. The metric that does respond is
`attack_contrast` -- how far the band leaps above its usual level at each
kick -- reported as `snap` in the output.

Run the level pass again afterwards: adding energy moves loudness, so
whatever happens last has to be the levelling.

## What this does not do

No EQ, no limiting, no tag writing, no expansion and no transient shaping.
The measurements argued against the last two: crest sits around 10-12 dB
across the clean corpora, so there is nothing flattened to restore, and
expansion would raise loudness range -- which is precisely what makes tracks
disagree with each other.

## Development

`lame` is needed only to run the gain tests, which check our frame CRCs
against a real encoder's: `brew install lame`.

```sh
./setup.sh                                     # also runs the suite
.venv/bin/python3 -m unittest discover -s tests -t .
.venv/bin/python3 tools/make_fixtures.py /tmp/fixtures   # synthetic library
```

The fixtures encode known properties -- missing sub, mono bass, congested
low-mid, moderate and wide dynamics -- so the tests check that the reports
detect them rather than trusting that they do. Their absolute numbers are not
representative of real music; they exist to exercise the pipeline.

## Layout

```
setup.sh                  One-command local setup (venv + deps + self-test)
loudness-lab              CLI entry point, re-execs into .venv
loudnesslab/bs1770.py     BS.1770-4 loudness, LRA, true peak, clipping
loudnesslab/spectrum.py   1/3-octave LTAS, modulation, stereo width
loudnesslab/decode.py     ffmpeg/ffprobe wrappers (read-only)
loudnesslab/db.py         SQLite schema and writes
loudnesslab/analyze.py    Per-track analysis, parallel walk, resume
loudnesslab/report.py     The reports
loudnesslab/mp3gain.py    MPEG Layer III frame parsing and global_gain rewriting
loudnesslab/apply_gain.py Planning, writing and undo for lossless gain
loudnesslab/subbass.py    Kick detection and sub-bass synthesis (prototype)
loudnesslab/profiles.py   Named settings bundles and their precedence
tools/make_fixtures.py    Synthetic library with known properties
```
