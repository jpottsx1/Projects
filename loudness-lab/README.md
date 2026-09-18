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
# Check the environment and the library before committing to a long run.
./loudness-lab doctor "/Volumes/Card/DJ Music/Converted Wedding"

# Analyse. Resumable -- re-running skips files that have not changed.
./loudness-lab analyze ~/Music/Serato --db library.db

# Try it on 200 tracks first.
./loudness-lab analyze ~/Music/Serato --db library.db --limit 200

# The two reports that matter.
./loudness-lab report loudness --db library.db
./loudness-lab report lowend   --db library.db

# What a given normalisation would do, per track. Writes nothing.
./loudness-lab report tracks --db library.db --estimator s_p95 --target -14

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

## What this does not do

No EQ, no bass synthesis, no limiting, no gain, no tag writing, no file
writing of any kind. Those belong to later stages, and should not be built
until this pass has been run over real records and the numbers looked at.

It also does not read Serato's `GEOB` frames. Any later stage that writes
files must preserve them byte-for-byte or cue points and beatgrids are lost.

## Development

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
tools/make_fixtures.py    Synthetic library with known properties
```
