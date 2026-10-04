# Loudness Lab

A tool for normalising and repairing a DJ library. It measures what a
folder of records **is**, and then does only what the measurement says is
needed — per track, not per era.

## Two rules it will not break

**Originals are never written to.** Every stage writes a copy. The folders
you point it at are opened for reading and nothing else.

There is one exception, and you have to ask for it every time:
**Replace originals when done**. It does not write to an original and it
does not delete one. It moves each original aside, intact, and puts the
finished track where it was. See *Putting the result in your library*
below.

**Serato's cue points and beatgrids survive.** Going MP3 to MP3 the
original's whole ID3 tag is copied onto the new file, bytes unread, so the
markers arrive intact and land on the right beat. Going to FLAC or M4A the
text tags travel but the markers do not yet — that needs translating
between two formats rather than copying, and it has not been checked
against a real Serato file.

## How a session goes

1. **Add folders.** Anything not audio is counted and reported rather than
   quietly skipped.
2. **Measure.** This reads the files and writes nothing. It fills in the
   Survey tab and puts the track list in order — thinnest low end first,
   because those are the ones the sub stage is for.
3. **Read the Survey.** This is the step people skip and should not. It
   says what the folder is, and every setting worth changing is set from
   something in it.
4. **Choose a profile**, adjust if the Survey tells you to, and untick
   anything in the middle pane you do not want.
5. **Process.** Copies are written to the output folder with a
   `manifest.json` beside them. **Clear** empties that folder of audio
   first, so a new batch is not mixed in with an old one.
6. **Listen.** The Results tab plays the before and after, level-matched,
   and Shift-Space switches between them on the same sample.
7. **Only then, if you want it, put the result in your library.** That is a
   separate run with Replace originals ticked, covered below.

## Reading the Survey

**Masters that were already clipped.** Runs of samples pinned at full
scale. Above roughly a quarter of a folder, turn de-clipping on; below it,
the damage is not worth a lossy generation.

**How many tracks would need a boost.** A negative gain is free. A
positive one eventually needs a limiter, which is the thing this tool
exists to avoid. Pick the loudest target where nothing needs a boost and
nothing breaches the ceiling.

**Low end by folder.** How far each folder sits under the reference across
31.5–63 Hz. This is where a sub cap comes from: set it just above the
worst folder you intend to process.

**Dynamics by folder.** Two different injuries, and the stage that repairs
one does nothing for the other:

- **LRA** is range over bars — verse against chorus, breakdown against
  drop. Loudness-war pop runs 4 to 6, a well-mastered record 8 to 10.
- **Crest** is punch over milliseconds — peak minus loudness. Hard-limited
  records read about 10, untouched ones about 12 and up.

The `wants` column needs both to be low before it suggests range work. A
groove that holds one level for seven minutes is the arrangement, not a
compressor, and expanding it would invent dynamics the record never had.

**Top end by folder.** `cliff` is the drop from 16k to 20k. Music rolls
off a few decibels across that step; a lossy codec falls off a wall. A `!`
means 20 dB or more — those files are low-bitrate, and no setting here can
put back what the encoder discarded. Re-rip them.

## What the stages do, in the order they run

**De-clip** goes first, on the file exactly as it arrived, because it puts
peaks back and everything after it has to fit under the peak it restores.
It is the only stage that recovers anything: the shape of the surviving
waveform says where the flattened peak was heading.

**Loudness range** widens the gap between the quiet passages and the loud
ones, by pulling the quiet ones down — never by pushing the loud ones up,
because a squashed master has no headroom left. The levelling at the end
gives the average back, so the drop comes out louder than it went in.

**Attack** gives back the transients a fast limiter flattened. It acts
only where the signal is rising, so it cannot turn a quiet passage down
and cannot breathe.

**Mud** takes the thickness out of 200–400 Hz. Early-seventies records sit
thick in the lower midrange, enough to blur the bass line and the kick into
each other. It is a dynamic cut: as deep as the band is built up at each
moment relative to the rest of the track, and nothing where it is not, so a
verse of voice and guitar is not thinned for something it never had. The
amount you ask for is the amount the band as a whole drops by, and the log
reports what it actually did. Off at zero.

**Sub** adds what a 1979 cutting lathe could not hold, sized from each
track's own shortfall against a reference folder and gated where there is
no bassline to reinforce.

**Air** makes a top end out of harmonics where a shelf would have nothing
to lift. This is the one stage that invents rather than restores. With
per-track sizing on it is measured against the reference folder's top end
the way the sub is measured against its bottom, and the amount becomes a
ceiling rather than a flat figure.

**Level** is always last, because every stage before it moves loudness.

**Stages that separate the track first.** Two settings, **Find kicks on the drum track** and **Air follows the vocals
and instruments**, separate each song into drums, bass, vocals and the rest
with Demucs before they work. Both use the separated parts only to decide
*where* to act: the sub is still added to the untouched original, and the
air's harmonics are still made from it, so nothing the separation got wrong
can be heard.

Separating is the slowest thing a run does, roughly half a minute a song,
and only the first time: what it finds is kept, so the same folder run again
with different settings separates nothing. Both need Demucs installed, which
`Measure Kick Detection.command` does for you.

## Choosing a profile

A profile fixes what the tool is **allowed** to do. It does not fix what
each track gets — that still comes from measuring the track, and the
distinction is the whole design.

There are no era profiles keyed on the year, and that was a measurement
rather than a preference: every clean corpus here is a compilation
carrying a reissue date, so a rule reading the year treats old masters as
modern.

| profile | for | notes |
|---|---|---|
| `level-only` | anything | Lossless. No decode, no re-encode, reversible. |
| `restore` | unknown material | Levelling plus a sub sized per track. Needs a reference. |
| `disco-70s` | 1970s disco | 6–9 dB short at 32–63 Hz. De-clipping on, and a 5 dB mud cut. |
| `eighties` | 1980s pop, new wave | 6–11 dB short. De-clipping off — it measured clean. |
| `nineties` | late 1990s pop | Low end nearly there; hard-limited instead, so range and attack do the work. |

**Reference folders.** The reference is what every track is measured
against, so it decides what each one is pushed towards. One modern folder is
the wrong target for 1977 disco. A profile can carry several folders of the
music it is for, and every track in them counts once, pooled into a single
target. Save the settings as a profile and the folders go with it.

**Save…** keeps whatever is on the sliders under a name of your own,
listed below the built-in ones. It carries no measured claim — that is the
difference, and it is why a personal preset cannot take a built-in's name.

## Putting the result in your library

Processing writes copies to the output folder, and that is all it does until
you tick **Replace originals when done**. With it on, each finished track is
moved into its original's place, same name and same folder, so Serato and
anything else that knows the track by where it is now plays the processed
one.

**Nothing is deleted.** Each original is moved into Music › LoudnessLab ›
Replaced originals › the date and time of the run, under its full folder
path, with a log of every swap. Double-click **Restore Originals** and
choose that run to put the whole batch back.

Two conditions, both deliberate:

- It only applies to a run that writes **finished tracks**, not A/B pairs.
  A pair's second file is level-matched for listening, not levelled for a
  set.
- The format must match the original's. A FLAC written for an MP3 original
  is left in the output folder, because a different file type would break
  its path in your library. Set the format to MP3 for an MP3 library.

You are asked to confirm every time, and the setting is never remembered.
Going MP3 to MP3 carries the whole tag, cue points and beatgrid included,
but a re-encoded MP3 may sit a few milliseconds off the original in Serato.
**Check the cue points on one song before replacing a library.**

## Making an intro for a track that starts cold

A song that opens straight into the groove or the vocal leaves you nowhere
to mix in. The **Intro** tab, beside Survey and Results, gives it an intro
made from itself: 8, 16 or 32 bars of the song's own instrumental, then the
song arriving exactly where it always did, on the beat. It writes copies to
Music › LoudnessLab › Intro Edits, never over the original.

1. **Tick the track** in the list, choose it in the Intro tab, and press
   **Analyse**. It separates the song into drums, bass and the rest, which
   takes about half a minute, and finds the beat. After that, choosing and
   rendering takes seconds.
2. **Choose the loop.** The tab ranks stretches of the song to repeat. Each
   shows how much vocal is in it (*no vocal* is what you want) and how well
   its drums *repeat* one loop later. A repeat score under 0.6 means a build
   or a fill: the seam will not land on the beat, and the tab says so.
   *Grid-timed* means the loop's ends could not be tied to a real kick.
3. **Choose the lengths** (more than one is fine) and the loop size, and
   press **Make intro**.
4. **Press Play the join.** It starts eight seconds before the song arrives,
   which is where a bad seam or a late downbeat shows. This is the check
   that matters: the numbers can tell you a seam is timed well, but not
   that it sounds right.

The intro is built from the instrumental only, so the vocal is not in it,
but a stretch where the separation leaked some vocal will carry a little of
it, and the tab warns when no clean stretch exists. If the song starts with
a vocal pickup just ahead of the first bar line, the pickup is kept.

**Cue points and the beatgrid are not copied** to the new file. They
describe the song without its intro and would all be an intro's length too
early. Text tags and artwork do travel; set the cues again in Serato.

It suits tracks that start cold on a steady groove. A song with a long
opening and no kick drum, or a live record that drifts in tempo, fits less
well, and the warnings under the track say when the beat was a guess. In
Disco Tags, right-click a track and choose **Make Intro Edit…** to open this
tab on it. **Make intros for all ticked** does the whole selection with the
best loop for each, at about half a minute a song.

## Listening to the result

Knowing which version is which biases you, so the pair is written
level-matched: both brought **down** to whichever is quieter, so neither
clips and neither wins on loudness alone. Louder reliably wins a blind
test whatever else is true of it.

Shift-Space switches mid-track. Both versions are scheduled together on
one clock, so the switch lands on the same sample with no tick.

The waveform shows the original pale and whatever this run added vivid on
top of it, in the bass, mid and treble colours a mixer's overview uses, so
*where* something changed reads at a glance. **Overlay** puts both in one
row; **Compare** stacks the two full silhouettes on a shared scale, which
is slower to read and more literal — a track that got louder is visibly
taller.

Listen against the original before committing a folder to a lossy
generation.

## When something goes wrong

**"Could not find the loudness-lab command."** The app drives a command
line tool that lives beside it in the project folder. Run `setup.sh` there
once, or point the app at the tool with the button in the message.

**"missing required tool(s): ffmpeg, ffprobe."** Install them with
`brew install ffmpeg`. If the message says the app *can* see them, that is
a PATH problem rather than a missing install — please report it.

**A run that writes nothing.** Not a failure. Every stage declines when
the measurement says there is nothing to do, and the log says which
declined and why. Most of what a good policy does is decline.

**Replaced the wrong thing, or the cue points are off.** Double-click
**Restore Originals** and choose the run. Nothing was deleted; every
original is where the log says.

**An intro whose seam sounds wrong.** Pick a different loop in the list, or
a longer one. If every option scores low on *repeats*, the song has no
stretch that comes round cleanly, and an intro may not suit it.

**MP3 refused.** Some ffmpeg builds ship without `libmp3lame`. Choose FLAC
or AAC, or install a build that has it.
