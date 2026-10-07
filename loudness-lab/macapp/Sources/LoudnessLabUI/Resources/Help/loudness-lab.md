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

A song that opens straight into the groove, or that has a long opening of its
own before the drop, leaves you nowhere to mix in. The **Intro** tab, beside
Survey and Results, gives it an intro made from itself: 8, 16 or 32 bars of
the song's own instrumental, then the song arriving exactly where it always
did, on the beat. **The song's own opening is cut out and the intro takes its
place**, so the file goes from the intro straight into the first big
downbeat. It writes copies to Music › LoudnessLab › Intro Edits, never over
the original.

**Preview a track first.** Click a song in the list and press the space
bar to hear it from the start, and again to stop. Up and down arrows move
the highlight. It plays the song as it is, so you can hear whether it
starts cold before ticking it.

1. **Tick the track** in the list, choose it in the Intro tab, and press
   **Analyse**. It separates the song into drums, bass and the rest, which
   takes about half a minute, and finds the beat. After that, choosing and
   rendering takes seconds.
2. **Check where the song starts.** *Where the song starts* shows the track
   as a picture, bass in red, mids in green, treble in blue. The tool puts
   the marker where the drums come in: a song that opens at full level starts
   at its first bar, a song with a soft opening starts at the drop. Everything
   to the left of the marker, shaded, is replaced by the intro. The top strip
   is the whole track: click or drag in it to find the drop. The lower strip
   is zoomed in on the marker, with the bar lines numbered: click or drag in
   it to place the marker, which always snaps to a bar line, because the song
   has to arrive on a downbeat. The **Bar** slider and the **−4 −1 +1 +4**
   buttons move it a bar at a time, **Zoom** sets how many seconds the lower
   strip shows, and **Suggested** puts it back where the tool chose. An
   orange dashed line marks the suggestion once you have moved off it. Press
   **Hear it** to play the original from a few seconds before the marker.
   If a vocal leads into the drop, the lead-in is kept.
   **Beat one** moves which beat is called the first of the bar, a beat at a
   time. The tool picks it from the accents in the low end, which a
   four-on-the-floor record does not have; when the numbered bar lines in the
   lower strip do not sit on the heaviest kick and bass hit, move them. The
   small ticks in that strip are the beats, the fainter ones the half beats. **◀ ½** and **½ ▶** move the whole grid half a beat, for a song whose kicks sit between its beats: the tool can lock onto those and put every bar line on the offbeat, which moving a whole beat cannot fix.
   Moving it separates nothing again, so it takes a moment, and the loops are
   found again on the new bar lines.
3. **Choose the loop.** The tab ranks stretches of the song to repeat, and
   ranks them first by how much they sound like the bars the song arrives
   with: the same rhythm, the same bar length (tempo), the same key and the
   same level. An intro that is busier, louder or faster than the song it
   leads into is a different song glued on, however clean it is. Each loop
   shows how much vocal is in it (*no vocal* is what you want), how well its
   drums *repeat* one loop later, *feels like the song* (the rhythm match
   against the bars the song arrives with) and its *tempo* against the song at
   the join. A repeat score under 0.6 means a build or a fill: the seam will
   not land on the beat, and the tab says so. A loop up to 1.2% off the song's
   tempo is resampled to it when the intro is made, so the intro does not
   change speed at the join; further off than that it is left alone and the
   tab says so. Move the join and the loops are found again for it.
   *Grid-timed* means the loop's ends could not be tied to a real kick.
   *Has a fill* means a bar in it differs from the groove around it: a loop
   is heard several times over, so a fill is heard every time, the last one
   right before the song arrives. The ranking already counts it against a
   loop, and the tab says when the best one left still has one.
4. **Choose the lengths** (more than one is fine), the loop size and the
   style, and press **Make intro**. *Build up* brings the song's own stems in
   one at a time: the drums first, the bass a quarter of the way in, the rest
   of the band half way, and the last repeat whole, so the intro builds into
   the song. *Full loop* plays the whole instrumental from the start. *Underlay* keeps the song's own opening exactly as it is and lays the loop's drums and bass under it, rising to full by the bar the song's groove lands on and fading out just after, so an opening with no drums gets a beat without being replaced; it needs the join set after an opening, and the length picks how many bars of the opening get the beat. *Beat* runs only the song's own drums and bass under every repeat, a groove with none of the other instruments, for a record whose band is never free of vocal. In both of those, the loop's drums and bass do not stop where the song starts: they carry on under the song's first bar and fade out, so the song arrives on a groove already running instead of being cut to. *End on the song's own break or fill* makes the
   intro's last bar the song's own break, the bar before its drums come back,
   with the vocal taken out, so the intro leads into the song the way the song
   leads into a drop. It only applies when the song has one that sounds like
   the bar the song arrives at, and says so when it does not. It is off by
   default: listen to both with **Play the join**.
5. **Press Play the join.** It starts eight seconds before the song arrives,
   which is where a bad seam or a late downbeat shows. This is the check
   that matters: the numbers can tell you a seam is timed well, but not
   that it sounds right.

The intro is built from the instrumental only, so the vocal is not in it,
but a stretch where the separation leaked some vocal will carry a little of
it, and the tab warns when no clean stretch exists.

**Cue points and the beatgrid are not copied** to the new file. They
describe the song without its intro and would all be an intro's length too
early. Text tags and artwork do travel; set the cues again in Serato.

The suggestion is only a starting point. It reads the drums, so it can be
fooled by a song whose drums play under a long opening, or by a drop that is
quieter than what led into it; that is what the picture is for. It suits
tracks with a steady groove: a live record that drifts in tempo fits less
well, and the warnings under the track say when the beat was a guess. In
Disco Tags, right-click a track and choose **Make Intro Edit…** to open this
tab on it. **Make intros for all ticked** does the whole selection, joining
each where its groove lands and using the best loop, at about half a minute
a song.

**Memory.** Separating takes a lot of it while it runs. The tab hands it back
when it is done, and a tab left alone for ten minutes lets go of the track
altogether. The next thing you do loads it again, which takes the half minute
once, and nothing is lost: your chosen marker and loop stay where they were.

## Making an outro for a track that ends cold or fades out

The other end of the same job. A song that fades away, or stops dead,
leaves you nowhere to mix out. Switch the Intro tab to **Outro** and it gives
the song an outro made from itself: **the song is kept up to a bar line, and
8, 16 or 32 bars of its own instrumental run from there.** The part of the
song after that bar line, the fade or the last hit, is replaced. It writes
copies to Music › LoudnessLab › Outro Edits, never over the original.

It is the same tab and the same analysis, so a track you have already
analysed for an intro is ready: switching to Outro takes seconds, not another
half minute. The loop, length and bar-line controls work as they do for an
intro, with these differences.

- **Where the song leaves.** The marker is the bar line the song leaves at,
  and what is shaded to the right of it is replaced by the outro. The tool
  suggests the end of the last stretch that holds the record's level, so a
  fade-out is replaced from where it starts to fall. A record that holds full
  level to its last bar exits at its last bar line, and the note under the
  picture says so. If the song's final bars are a hit or a stop you want to
  keep, move the marker back.
- **The loop** is chosen to sound like the bars the song plays up to the
  exit, not the bars after a join.
- **A vocal still ringing** past the exit bar is kept, so a held last note is
  not cut mid-word; the loop takes over after it, on the beat.
- **Style.** *Strip* takes the band away a part at a time, the rest first,
  then the bass, and the drums play the last repeat alone. *Beat* is only the
  song's own drums and bass throughout, a groove to mix out on. *Full loop* is
  the whole instrumental throughout. In the first two, the loop's drums and
  bass also fade in under the song's last bar, so the loop arrives as a groove
  that is already running.
- **Ending.** *Stop* ends on a bar line; *Fade out* fades the outro away over
  its last four bars.

Press **Make outro**, then **Play the exit**, which starts eight seconds before
the song leaves, because that is where a bad seam or a late downbeat shows.

**The bar lines can drift.** They are followed bar by bar from the start of
the song, and on a record whose tempo wanders, or that has a long stretch
without kicks, they can lose the kicks and end up well off them by the last
bars, which is exactly where an outro leaves. The tool measures where the
kicks near the exit really fall and moves the exit onto them, and says so
under the edit ("had drifted 181 ms from the kicks"). Listen to the exit when
it does.

**The outro never clips.** The loop is the stems added together, which can be
louder than the song they came from, so the new part is brought under full
scale where it needs it. The original is never changed.

**Cue points and the beatgrid are not copied**, the same as for an intro. A cue
after the exit would point into the loop. In Disco Tags, right-click a track
and choose **Make Outro Edit…** to open the tab on Outro. **Make outros for
all** does the selection, exiting where each groove ends and using the best
loop.

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

**An intro that starts in the wrong place.** Move the marker: drag in the
top strip to find the drop, then place it in the lower strip against the
downbeat and press **Hear it**. Zero keeps the whole opening.

**An intro whose seam sounds wrong.** Pick a different loop in the list, or
a longer one. If every option scores low on *repeats*, the song has no
stretch that comes round cleanly, and an intro may not suit it.

**MP3 refused.** Some ffmpeg builds ship without `libmp3lame`. Choose FLAC
or AAC, or install a build that has it.

# Every setting

Generated from the app's own help, so this cannot drift from what the window shows.

## Choosing music

### Music

*Folders or files to work on. Nothing is ever written back to them.*

Originals are never opened for writing. Everything produced goes to ~/Music/LoudnessLab, and the measurements are cached in a database there, keyed on each file's size and modification time -- so running again re-measures only what actually changed.

A folder is walked for audio; anything that is not audio is counted and reported rather than silently skipped, so a library that comes back smaller than you expected can be explained.

### To process

*Everything found, in the order it will be worked through.*

The order is the information. Tracks are taken thinnest low end first -- not alphabetically, not in folder order -- because those are the ones the sub stage is for. So "10 tracks" from a folder of three hundred means a particular ten, and this is where you see which.

Rows within the limit are highlighted; the rest are dimmed rather than hidden, because "not chosen" and "not found" are very different problems and you should be able to tell them apart. Untick anything you want left out -- doing so promotes the next track into range rather than leaving a gap.

Until a folder has been measured there are no numbers to sort on, so the list is in name order and says so. Press Process and it fills in.

### Survey

*What a folder IS: how much arrived clipped, how thin its low end is.*

Measuring reads the files and writes nothing. It answers a different question from Process: not what a policy would do to a folder, but what the folder actually is.

Two numbers here decide things. How much of it arrived already clipped says whether de-clipping earns a lossy generation on this material. And how far a folder's low end sits under a reference is where a profile's cap is supposed to come from -- disco-70s allows 8 dB because three 1970s corpora measured 6 to 9 dB short, and any new profile should be built the same way rather than guessed.

Name a reference folder to get the comparison. Changing it re-reads what is already measured; it does not measure again.

## Policy

### Profile

*A named policy. Fixes what is allowed, not what each track gets.*

A profile fixes what the tool is ALLOWED to do. It does not fix what each track gets -- that still comes from measuring the track, and that distinction is the whole design.

level-only: lossless levelling and nothing else. No decode, no re-encode, reversible. restore: levelling, plus sub sized per track against a reference corpus. Needs a reference. Lossy. disco-70s: the same, with the cap raised to 8 dB and the gate lowered to 18. Three independent 1970s disco corpora -- 108 tracks over two compilations and a 2003 reissue -- agree within about 3 dB from 32 to 63 Hz, sitting 6 to 9 dB under a current reference. There is nothing usable below 32 Hz: the 20 Hz band reads as empty on all three.

There are deliberately no era profiles. Era-keyed curves were the obvious idea and the measurements ruled them out twice: every clean corpus here is a compilation carrying a reissue date, so a rule reading the year treats old masters as modern; and within a single era the spread between tracks at 32 Hz is 14-24 dB against roughly 5 dB between one era's median and the next, so a curve fitted to the era moves the median and leaves most tracks further from the target than they started.

"Save…" keeps whatever is on the sliders right now under a name of your own, listed below the built-in profiles. It carries no measured claim -- unlike the profiles above it, it is not backed by a corpus -- so it cannot be saved under one of their names. "Delete" removes a saved one; the built-in profiles cannot be deleted.

## Clipped peaks

### Restore clipped peaks

*Puts back peaks that were flattened before the file reached you.*

About a third of the 1970s disco measured for this project carries runs of consecutive samples pinned at full scale. That is not loudness, it is a flat top where a peak used to be, and the flat top IS the distortion -- a clipped waveform is the original plus a family of odd harmonics, which is why heavily clipped material sounds hard and small rather than loud.

Nothing can recover what was thrown away. What this does is draw the arc the signal was already on when it ran out of headroom, taking the value and slope of the audio on both shoulders. The method is chosen for being self-limiting rather than clever: on a genuinely clipped peak it arcs to within 0.1 dB of the true peak, and on a peak that merely touched full scale without clipping the shoulders are already turning over, so it changes the audio by thousandths of a decibel. A false detection therefore costs almost nothing, which is the only basis on which this is safe to run across a library.

Two honest limits. On clean audio deliberately clipped and restored, reconstruction improves by 3.3 to 3.9 dB -- but through MP3 the real figure is much smaller: about 2.0 dB at light clipping, falling to 0.4 dB at heavy. And a limiter is not a clipper: where a master was squashed rather than clipped the shoulders are squashed too, no flat run appears, and there is nothing here to find.

It runs first, before anything else, because it puts peaks BACK and everything after has to fit underneath them.

### Lift cap

*The most any single peak may be lifted. Default 6 dB.*

A hard ceiling on the reconstruction, so an unusual run cannot produce an implausible peak. Separately, any run longer than 10 ms is refused outright -- longer than a clipped peak can plausibly be, so a long flat span is more likely to be something else.

## Sub bass

### Sub

*dB added in the 31.5-63 Hz octave, under the kicks. Zero is off.*

Energy laid into the sub octave, synchronised to the kicks the detector found, rather than an equaliser lifting the whole band for the length of the track. Zero turns the stage off.

With per-track sizing on, this figure is ignored and each track gets its own measured shortfall instead.

### Size it per track against a reference

*Each track gets its own measured shortfall, not one figure for all.*

The difference between a policy and a preset. With this off, every track gets the same number of decibels whether it needs them or not. With it on, each track is measured against the reference folder's low end and given what it is actually short of.

Air is sized the same way, against the reference folder's top end, whenever both this and Air are on -- Air's own amount then reads as a cap rather than a flat number every track gets.

This needs a reference to measure against. Without one the setting cannot be honoured, and the run stops rather than quietly applying the fixed amount instead -- which would be the app doing something other than the policy on screen.

### Reference folder

*The folder whose low end is the target. Name one you have measured.*

Enough of the folder's name to identify it. If the text matches more than one folder it resolves to nothing and the run stops with a message, rather than picking one and leaving you to wonder which.

### Reference folders

*More folders the target is measured from, pooled into one. Save them with a profile per kind of music.*

The per-track amounts are "how far this track sits from the reference", so the reference decides what every track is pushed towards. One modern folder is the wrong target for 1977 disco: a disco profile wants disco that sounds right, a 2020s pop profile wants 2020s pop. Add several folders of the music the profile is for; every track in them counts once, pooled into one target, together with the folder chosen above if there is one.

Each folder is measured the first time a run uses it -- a slower start once, then nothing. Save the settings as a profile (Disco, Dance, 2020s, Pop) and the folders are saved with it. A folder that cannot be found stops the run and says which.

### Cap

*Ceiling on the per-track amount when sizing automatically.*

A track measured as 12 dB short is more likely to be unusual than to need 12 dB. The cap bounds what any single track can be given. disco-70s raises it to 8 because the deficit on that material was measured at 6 to 9 dB.

### More or less than the reference

*Added to each track's measured shortfall. Zero matches the reference.*

Sizing per track gives each track what it measures short of the reference folder. That is a match, not a taste -- and by ear a record can want a little more (Blue Monday: "more like +3 dB") or less.

This is added to every track's measured amount before the cap, so +3 gives each track 3 dB more than matching the reference would, and the cap still bounds it: a track already at the cap gets no more unless the cap is raised too. A track the reference says needs nothing gets this much, when it is positive.

### Gate

*Skip tracks whose sub octave barely moves. Rumble ~11 dB, a groove ~44.*

How much the sub octave has to swing over the track before the stage will touch it. The point is to tell a bassline from a static floor: tape rumble, air conditioning, or a room tone measures about 11 dB of movement, a real groove about 44. Values in between are a judgement call, which is why this is a control and not a constant.

Adding sub to a track whose low end never moves does not give it a bassline, it raises its noise floor. disco-70s lowers the gate to 18 because that material is the most groove-locked in the project and sits nearest the threshold, where a marginal track is better reviewed than silently dropped.

### Find kicks on the drum track

*Separate the drums with Demucs and find the kicks there, not in the full mix.*

The sub is laid under each kick, so where it goes depends on finding the kicks. In the full mix they share 30-100 Hz with the bassline, and a bass note with a sharp attack reads as a kick. Measured against Serato's BPM tags, the full mix found 1.26 to 1.85 "kicks" per beat on every one of fifteen disco tracks, so a burst was going under off-beat bass notes as well as under the kicks.

With this on, each track is separated with Demucs first and the kicks are found on the drums alone. Over 35 tagged tracks, the tempo the kicks imply matched the tag on 20 this way and on 3 from the mix. The separated drums only decide WHERE the sub goes; it is still added to the untouched original, so nothing the separation got wrong can be heard.

Not every hit on the drum track is a kick. A LinnDrum snare, an 808 clap, a floor tom or a scratch can have an attack down there too, so two filters decide which hits get sub. Weight: a kick is among the heaviest hits below 90 Hz, and a snare or scratch on its own is far lighter -- while a kick with a snare on top of it still counts. The beat: using the BPM tag, hits that land between beats (fill notes, scratches) are dropped. A syncopated kick off the beat is dropped with them: one fewer burst, never one in the wrong place.

No track is turned away for disagreeing with its tag: only the hits that disagree go. If the kicks do not line up with the tagged tempo but do with double it (Serato halves some tempos), that grid is used. If they fit neither, or there is no BPM tag, the weight filter works alone. The log says what was kept and dropped, and which grid was used. A track gets no sub only if too few kicks are left.

The sub is also tuned to each track's own kick, measured on the drum track: an octave below the kick's pitch (or at the kick's pitch, if an octave down would be below 31.5 Hz), and fading when the kick does. Measured on 1988 dance records, kicks sat at 58-84 Hz and faded in 74-252 ms, under a fixed burst of 45 Hz that rang for about 280 ms -- a second, lower note after every kick, which added no drum depth and sounded like part of the bass line. The log says what each track was tuned to.

Separating is the slowest thing a run does, the first time. What it finds is kept, so running the same folder again with different settings separates nothing. Needs Demucs installed; Measure Kick Detection.command installs it.

### Sub follows the bassline too

*Put part of the sub under the bass notes, where the bass carries the low end.*

On some records the low end is the bass line, not the kick -- She Blinded Me With Science, Blue Monday. A sub laid only under kicks cannot follow that. With this on, the notes of the separated bass part are tracked and a tone is added an octave under each one, as loud as the bass is there, so it follows the line note for note and stops where the bass stops.

An octave under the note, where it can only add: a tone on the bass's own pitch, started blind, would add to it on one note and cancel it on the next. A note above 150 Hz gets a tone two octaves down. A note under 56 Hz, where an octave below would be too low to hear, gets a tone on its own pitch -- in step with it, the timing read from the record itself, so it lands on top of the note and only makes it bigger.

How much of the sub goes under the bass and how much under the kicks follows where the track's low end already is: mostly the bass on a record whose bass carries it, mostly the kicks on disco. The total added is the same as without this setting; only where it goes changes. As with the kicks, the separated bass only decides the notes: the tone is made fresh and added to the untouched original.

Needs "Find kicks on the drum track". Tracks separated before this setting existed are separated once more, to keep their bass part.

## Attack

### Punch

*Attack emphasis on each kick, in 2-6 kHz. Adds no energy.*

Emphasis on the beater click -- the snap of the kick, not its body, which is why it works at 2-6 kHz and not in the bass.

This is a transient shaper, not an expander, and the difference is the point: the band is renormalised afterwards, so it comes out holding exactly the energy it went in with. Nothing is added; the distribution in time is changed. That means it cannot make a track brighter overall, only sharper at the front of each kick.

Off by default, and disco-70s leaves it off: live drummers, and on that material 2-6 kHz is full of hi-hat and tambourine rather than beater click.

### Decay

*How long the attack emphasis takes to fall away. Default 8 ms.*

Short values sharpen the very front of the kick; longer ones let the emphasis run into the body of it, which starts to sound like a lift rather than an attack.

## Dynamics

### Loudness range

*Widen the gap between the quiet parts and the loud ones. Off at zero.*

What the loudness war took out over BARS, as opposed to over milliseconds: the difference between a verse and a chorus, a breakdown and a drop. Measured as LRA, the spread of a track's 3-second loudness, and this widens it to the figure you set.

It only ever turns things DOWN. A master that has been squashed to the ceiling has no headroom left -- that is what made it one -- so raising the loud parts would clip, or be trimmed straight back out. The loudest 5% is left exactly where it is and everything below it is pulled away, which costs the track some average loudness. The levelling at the end of the chain gives that back, so the drop ends up LOUDER than it started. What changed is what sits around it.

Nothing is recovered here. A compressor that took 8 dB off a chorus did not write down what it removed, so what comes back is a plausible shape rather than the original one. That is worth doing and worth being honest about.

A caution for DJ use, which is what this is for: a track that drops 8 LU in the breakdown disappears under the next record. Club masters are flat partly because of the loudness war and partly because flat works in a mix. Start low.

### Pull down at most

*How far a quiet passage may be turned down to widen the range.*

A cap rather than an estimate. Past a few dB the intro of a record stops being quiet and starts being missing, and there is no measurement that says where that line is -- so it is a limit you set rather than one the tool works out.

When the cap is reached before the target, the run says so instead of quietly falling short. Raising the target past what the cap allows otherwise looks like a setting that does nothing.

### Attack

*Give back the punch a fast limiter flattened. Off at zero.*

The other half of "over-compressed", and the one that usually matters more here: what was taken out over MILLISECONDS. The front of a kick, the crack of a snare.

Two envelopes of the same signal, one fast enough to follow a beater click and one that cannot. Where the fast one stands above the slow one there is an onset, and only there is any gain applied. A sustained note gives both envelopes the same value and therefore no gain at all -- which is what separates this from an expander. It cannot turn a quiet passage down, so it cannot breathe.

The measurement is crest, the gap between a track's peak and its loudness. Measured here, about half a decibel of crest comes back per decibel asked for; the setting is a ceiling on the gain at an onset, not a promise about the statistic.

This is broadband, unlike the kick punch above, which is deliberately band-limited and deliberately does NOT move crest.

### Skip above

*A track already this peaky was never flattened, so leave it.*

Crest is peak minus loudness. Above this figure the attack stage declines, on the same principle as the sub's activity gate: most of what a good policy does is decline.

Eleven, measured on this library rather than taken from a book. Sixteen folders read 9.6 to 10.7 and then 11.8 to 12.9, with a gap of just over a decibel between them — wider than any other gap in the set. The hard-limited records sit on one side of it and everything else on the other.

It was 12 to begin with, from the published range, and eleven folders appeared to confirm it. Five more landed between 11.8 and 12.2 and showed 12 cutting that upper group in half.

Measure a folder first and read the survey. Setting this from taste rather than from the numbers is how a stage ends up working on material that never needed it.

## Mud

### Clear the mud

*Take the thickness out of 200–400 Hz, where it builds up. Off at zero.*

Early-seventies records sit thick in the lower midrange: measured against a disco reference, 16 of 20 tracks were more than 1 dB above it in 200–400 Hz, 3 dB the median. That thickness blurs the bass line and the kick into each other.

A threshold, as a dynamic EQ has: every moment where the band is built up above it is cut by how far above it is, and moments below it -- a sparse verse -- are left alone. The threshold is set so the band as a whole comes down by this many dB, measured and reported. A track thick all the way through is cut nearly evenly; one that thickens in places is cut there. It moves over 400 ms, too slowly to pump or click, and nothing outside 200–400 Hz is touched.

With "Size it per track against a reference" on, this is a ceiling: each track gets what its 200–400 Hz sits above the reference folders, and a track already at or under them gets none.

## Air

### Air

*Generate a top end where a shelf has nothing to lift. Off at zero.*

The one control here that INVENTS. Everything else restores something a measurement says was taken away; this makes harmonics that were never in the recording and mixes them in.

That is the point of it. A high shelf multiplies what is in the band, so where the band is empty — a lossy codec cut it, a tape rolled off — a shelf raises the noise under it and nothing else. A harmonic generator takes the octave below and folds its overtones upward, so 5 kHz of material becomes 10 and 15 and 20 kHz of new content. Musically related to the source, which is why it reads as detail rather than as hiss.

Measured on a track with everything above 16 kHz removed: to put 12 dB into that empty top octave, a high shelf has to lift the hi-hats (8–12 kHz) by 10 dB with it; air lifts them by 1.5.

The number is what the top octave, 16–20 kHz, actually rises by -- not a mix level: the harmonics are scaled to hit it and the run reports what it got. (It was 8–20 kHz until September 2026. That band is mostly hi-hats, so the number said little about what you hear change; the same setting now is gentler.) On a track whose top octave is missing -- a tape roll-off, a lossy encode -- even 12 dB costs next to nothing. On a track with a full, bright top it costs peak: 6 dB there raised the peak by about 5. The levelling that ends the chain takes that back out.

Check the survey's cliff column first. A folder with a gentle roll-off already has a top end and this is taste; one with a wall has had it thrown away by an encoder, and the honest fix there is a better rip.

With "Size it per track against a reference" on, this number becomes a ceiling rather than a flat amount: each track is measured against the reference folders' own top octave and given air up to this much, as far as it falls short -- the same idea as the sub's cap. That is what makes a high ceiling safe: the tracks missing their top octave get plenty, cheaply, and a bright track gets little or none, where it would cost.

### Same air on every track

*Give every track the Air amount, even when the sub is sized per track.*

With "Size it per track against a reference" on, Air is normally a ceiling: each track gets only what its top octave (16-20 kHz) falls short of the reference. A folder already brighter than the reference gets none at any setting -- the 1988 dance folder measured 4.56 dB brighter, and every track came back with no air.

On, every track gets the Air amount as set, while the sub is still sized per track. Air is a taste control rather than a repair, so a fixed amount is often what is wanted.

### Air follows the vocals and instruments

*Put air where voices and instruments carry the top end, not hi-hats.*

Plain air excites everything above the tune frequency, hi-hats and cymbals included. Those are bright already, and exciting them is where an exciter turns to grit.

With this on, each track is separated with Demucs (once, and kept), and the air follows the balance of the top end moment to moment: full where vocals, synths and strings carry it, backing away where the drums do. Where vocals and instruments carry the top end, the track gets exactly the air the same setting gives without this; where the drums do, less or none. So across a track it is subtler -- the Results column says what it actually added.

The separated tracks only steer the air; the harmonics are still made from the original, so nothing from the separation is heard. A track that could not be separated gets no air rather than air everywhere. Needs Demucs, like "Find kicks on the drum track".

### Air from

*Where the harmonics are generated from, upward.*

The exciter high-passes the track at this frequency and makes harmonics of what it finds, so the new content lands an octave above and up. 3.5 kHz feeds 7 kHz and above — presence and air.

Lower is fuller and cheaper. Higher is more sizzle and costs a great deal more headroom: asking for 3 dB of air on the same fixture cost 2.2 dB of peak tuned at 2 kHz, 4.3 dB at 3.5 kHz and 7.3 dB at 5 kHz.

It does not change how much air comes out — that is set by the amount, and normalised — only what it is made of and what it costs.

## Level

### Level to

*The level each written file is brought to, measured on the estimator.*

Levelling happens last, because everything before it moves loudness: restoring a peak, laying in sub and reshaping attacks all change what the track measures. Whatever happens last has to be the levelling, or the number on screen is not the number in the file.

### On

*Which loudness statistic to level on. s_p95 describes the loud part.*

lufs_i is integrated loudness: one number for the whole track, quiet intro and all. s_p95 is the 95th percentile of the rolling 3-second loudness -- it describes the loud part of the track rather than its average, which is what actually matters when tracks are mixed one into another. s_p50 is the median, s_max the loudest moment.

The choice only matters as much as the two disagree, and they disagree more as a track's loudness range grows. Measured on this library, the median gap between s_p95 and lufs_i by loudness-range band was 1.16, 1.70, 2.16, 2.47 and 2.76 dB. On a track with a quiet intro and a loud body, levelling on integrated loudness makes the body too loud.

### Peak ceiling

*True peak no gain may exceed. -1.0 dBTP, not -0.1, on purpose.*

Levelling stops here even if that means falling short of the target. The default is -1.0 rather than the -0.1 you often see because the measurement itself is not that precise: 4x oversampled true-peak detection is only good to about 0.5 dB, and an MP3 re-encode moves peaks around on top of that. A ceiling tighter than the error bar is a ceiling that gets crossed.

## The run

### Only the first

*Off by default: everything ticked gets processed.*

Off means all of it. A folder added is a folder meant to be worked on, and a silent cap of ten on three hundred tracks is a surprise rather than a convenience.

Turned on, the count applies to the order in the middle pane — measured low end, not folder order — so a small number gives you the tracks that stand to gain most rather than whatever sorted first. Useful for trying a profile before committing a folder to it.

Either way, the same record twice in one batch is processed once, matched on artist and title with case and punctuation ignored. A library of compilations is largely the same songs, and two files differing only in which disc they came off is not something anyone wants two of.

### Format

*FLAC keeps everything; MP3 and AAC are for the copies you play.*

FLAC is lossless and the honest default: this stage has already spent one decode, and a second lossy encode gives away more than the sub is worth. It is also about four times the size.

MP3 320 and AAC 256 are there because a set does not want lossless files. Both are encoded once, from the processed audio, by ffmpeg.

AAC says 256 rather than 320 because 320 is not something AAC actually does: asked for it, ffmpeg's encoder was measured handing back about 200 kbps and saying nothing. 256 is where AAC-LC is generally reckoned transparent, and what Apple ship music at. Where the ffmpeg build carries Apple's own encoder it is used in preference to the native one.

Both sides of an A/B pair always get the SAME format. A lossless original against a lossy processed version would have you listening to the codec and calling it the processing.

MP3 out of MP3 carries the original's whole tag — cue points, beatgrid, artwork, comments, everything — by copying it onto the new file. ffmpeg will not do that on its own: it carries the text and drops Serato's frames, measured as two in and none out.

The cues land on the right beat because the timing survives: decode, encode at 320, decode again, and the result is the same length with a maximum sample difference of 0.00003 — the codec, and no shift at all. LAME writes its delay and padding into the header and the decoder gives them back.

That was measured on a file this project made, whose marker frame carries a byte ramp rather than real cues. It shows that ffmpeg drops the frames and that a copied tag arrives intact, which is what the container cares about. What it does not show is Serato reading the result — no Serato has opened one. Copying the tag whole is what makes that a reasonable bet: the bytes are never interpreted, so there is nothing to misunderstand. It is still a bet until a real library confirms it.

FLAC and AAC carry artist, title, album and artwork — for now. Serato does store markers in both (base64 in FLAC's Vorbis comments, freeform atoms in M4A), so this is a gap rather than a limit. Going MP3 to MP3 the tag is copied unread, which is why it is safe; going MP3 to FLAC would mean translating between two formats, and that needs checking against a real Serato file rather than reasoning.

### To

*Where processed files go. Originals are never written to.*

Defaults to ~/Music/LoudnessLab. Change it to write straight into wherever your library lives.

The measurements do not follow it. They stay in one database, because pointing the output somewhere else for one run should not hide a folder you measured last week.

"Clear" deletes every FLAC, MP3 and M4A sitting directly in this folder -- both sides of every A/B pair -- so a new batch is not mixed in with an old one. Nothing else in the folder is touched: not the manifest, not anything put there by hand.

### Write A/B pairs

*Writes the original alongside the processed version, level matched.*

Both versions are written from the same decode, so they are the same length to the sample and can be switched between mid-bar.

They are also level matched, both brought DOWN to whichever is quieter so neither clips. This is not politeness: louder wins every blind comparison regardless of merit, so without matching you would be testing which is louder rather than which is better.

### Dry run

*Measure and report what would happen. Writes nothing.*

Every measurement, every decision and every per-track figure, with no files produced. The fastest way to see what a profile would actually do to a folder before committing a lossy generation to it.

### Replace originals when done

*Puts each finished track where its original was. The originals are kept, so this can be undone.*

After a track is processed and written, it is moved into its original's place, same name, same folder -- so Serato, and anything else that knows the track by where it is, now plays the processed one. Only in a run that writes finished tracks rather than A/B pairs (a pair's B is level-matched for listening, not levelled for a set), and only when the format matches: a FLAC written for an MP3 original is left in the output folder, since a different file type would break its library path. Set the format to MP3 for an MP3 library.

Nothing is deleted. Each original is moved into Music › LoudnessLab › Replaced originals › <date and time>, under its full folder path, with a log of every swap. Double-click Restore Originals and choose that folder to put the whole batch back.

MP3 to MP3 carries the whole tag across, Serato's cue points and beatgrid included, but a re-encoded MP3 may sit a few milliseconds off the original in Serato. Check the cue points on one song before replacing a library.

## Listening

### Switch version (Shift-Space)

*Swaps versions at the same instant, with no gap or restart.*

Every version is playing already, in step, with all but one silent. Switching changes which one you hear; it does not start anything, so there is no gap, no restart and no drift.

They stay in step because they are scheduled together on one clock at a shared start time. If you hear a tick or a flam on the switch, that is a bug worth reporting rather than something to work around.

### Match loudness

*Plays every version at the same loudness, so the louder one cannot win.*

Applies the per-version gain needed to bring them all to the same measured level during playback, on top of the matching already done when the files were written.

Turn it off only to hear what the processed file will actually sound like at its own level. For deciding whether the processing helped, leave it on: louder is reliably judged better, whatever else is true of it.

### Blind

*Hides which version is which until you turn it off.*

Knowing which is the processed one biases you toward hearing what you expected. Better still, have someone else shuffle them, or at least listen to each version first on half the tracks.

## Results

### Results columns

*Sub, Air and Punch are what was applied. Clips and Lift are the de-clipper.*

Sub, Air and Punch are what was actually applied to that track, which with per-track sizing on is not the same as what was asked for. Air reads "—" for a manifest written before this column existed, rather than a false "+0.00 dB".

Mud is how far the 200-400 Hz band came down (hover for why a track got none).

Up and down arrows step through the songs. While one is playing the next starts from the top, on the same version (A or B) you were hearing; stopped stays stopped.

Asked is what the sub was asked for: with per-track sizing, how far the track's low end sat under the reference (capped). Why says why it got what it got -- "already within 0.3 dB of the reference" for a track whose bottom end was already there, a reason it was declined, or what the kicks and bass line did. A small Sub with a small Asked is a track that needed little; a small Sub with a large Asked is one worth a look.

Clips is the number of clipped runs restored. Lift is the median amount one restored peak gained -- deliberately not the change in the file's peak, because on an MP3 of a clipped master the file peak is set by codec overshoot and barely moves however many runs are restored. One track here decoded at +2.27 dBFS and read +0.00 dB of change while 402 runs had been lifted by a median of 0.29 dB.
