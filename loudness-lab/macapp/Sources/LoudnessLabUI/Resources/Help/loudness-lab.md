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

### Cap

*Ceiling on the per-track amount when sizing automatically.*

A track measured as 12 dB short is more likely to be unusual than to need 12 dB. The cap bounds what any single track can be given. disco-70s raises it to 8 because the deficit on that material was measured at 6 to 9 dB.

### Gate

*Skip tracks whose sub octave barely moves. Rumble ~11 dB, a groove ~44.*

How much the sub octave has to swing over the track before the stage will touch it. The point is to tell a bassline from a static floor: tape rumble, air conditioning, or a room tone measures about 11 dB of movement, a real groove about 44. Values in between are a judgement call, which is why this is a control and not a constant.

Adding sub to a track whose low end never moves does not give it a bassline, it raises its noise floor. disco-70s lowers the gate to 18 because that material is the most groove-locked in the project and sits nearest the threshold, where a marginal track is better reviewed than silently dropped.

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

## Air

### Air

*Generate a top end where a shelf has nothing to lift. Off at zero.*

The one control here that INVENTS. Everything else restores something a measurement says was taken away; this makes harmonics that were never in the recording and mixes them in.

That is the point of it. A high shelf multiplies what is in the band, so where the band is empty — a lossy codec cut it, a tape rolled off — a shelf raises the noise under it and nothing else. A harmonic generator takes the octave below and folds its overtones upward, so 5 kHz of material becomes 10 and 15 and 20 kHz of new content. Musically related to the source, which is why it reads as detail rather than as hiss.

Measured on a track with everything above 16 kHz removed: a 3 dB shelf moved the 16–22 kHz band by 3 dB, which is 3 dB more of nothing. 3 dB of air moved it by 16.

The number is what the 8–20 kHz band actually rises by, not a mix level — the harmonics are scaled to hit it and the run reports what it got. Loudness barely moves, which is the famous thing about an exciter; peak moves a great deal, because the harmonics land on the source's own peaks. The levelling that ends the chain takes that back out, but it is why this is a small control.

Check the survey's cliff column first. A folder with a gentle roll-off already has a top end and this is taste; one with a wall has had it thrown away by an encoder, and the honest fix there is a better rip.

With "Size it per track against a reference" on, this number becomes a ceiling rather than a flat amount: each track is measured against the reference folder's own 8–20 kHz band and given air up to this much, in proportion to how much brighter the reference already is -- the same idea as the sub's cap, applied to the top end instead of the bottom.

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

Clips is the number of clipped runs restored. Lift is the median amount one restored peak gained -- deliberately not the change in the file's peak, because on an MP3 of a clipped master the file peak is set by codec overshoot and barely moves however many runs are restored. One track here decoded at +2.27 dBFS and read +0.00 dB of change while 402 runs had been lifted by a median of 0.29 dB.
