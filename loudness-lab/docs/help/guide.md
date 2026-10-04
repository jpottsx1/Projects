# Loudness Lab

A tool for normalising and repairing a DJ library. It measures what a
folder of records **is**, and then does only what the measurement says is
needed — per track, not per era.

## Two rules it will not break

**Originals are never written to.** Every stage writes a copy. The folders
you point it at are opened for reading and nothing else.

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

**Sub** adds what a 1979 cutting lathe could not hold, sized from each
track's own shortfall against a reference folder and gated where there is
no bassline to reinforce.

**Air** makes a top end out of harmonics where a shelf would have nothing
to lift. This is the one stage that invents rather than restores. With
per-track sizing on it is measured against the reference folder's top end
the way the sub is measured against its bottom, and the amount becomes a
ceiling rather than a flat figure.

**Level** is always last, because every stage before it moves loudness.

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
| `disco-70s` | 1970s disco | 6–9 dB short at 32–63 Hz. De-clipping on. |
| `eighties` | 1980s pop, new wave | 6–11 dB short. De-clipping off — it measured clean. |
| `nineties` | late 1990s pop | Low end nearly there; hard-limited instead. |

**Save…** keeps whatever is on the sliders under a name of your own,
listed below the built-in ones. It carries no measured claim — that is the
difference, and it is why a personal preset cannot take a built-in's name.

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

**MP3 refused.** Some ffmpeg builds ship without `libmp3lame`. Choose FLAC
or AAC, or install a build that has it.
