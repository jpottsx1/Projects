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

## Running things

```sh
python3 -m unittest discover -s tests -t .   # ~205 tests, ~2 min
swift test --package-path macapp             # 40 golden tests, ~2 min
sh macapp/make-app.sh --open                 # build + launch LoudnessLab.app
swift run --package-path macapp LoudnessLabUI  # faster, for seeing a change
```

Needs `ffmpeg` and `ffprobe` on PATH, plus numpy/scipy for the Python.

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

## Open

- **The A/B switch has never been heard.** Versions are scheduled together
  on one host clock so a switch lands on the same sample. Reasoned, not
  proven. A tick or a flam on ⇧Space is the bug.
- **The disco survey.** The `CLIPPING` block from the real 1970s folders
  decides whether de-clipping earns its lossy generation on that material.
- **The app's `Engine` and views have been type-checked, not exercised.**
