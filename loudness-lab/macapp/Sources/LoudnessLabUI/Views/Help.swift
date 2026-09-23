import SwiftUI

/// What every control does, in one place.
///
/// Written here rather than beside each control for two reasons. The
/// summaries are hover tooltips and the details fill the Help window, so
/// the same sentence would otherwise be written twice and drift. And the
/// answers are not obvious: most of these numbers were chosen by measuring
/// something, and a setting whose reasoning is lost is a setting nobody can
/// judge. Where a figure was measured, it is quoted.
struct HelpEntry: Identifiable {
    let title: String
    /// One line. Appears on hover, so it has to be useful at a glance.
    let summary: String
    /// The fuller answer, including what it costs to get it wrong.
    let detail: String

    var id: String { title }
}

enum Help {

    // MARK: - Choosing music

    static let folders = HelpEntry(
        title: "Music",
        summary: "Folders or files to work on. Nothing is ever written back to them.",
        detail: """
        Originals are never opened for writing. Everything produced goes to \
        ~/Music/LoudnessLab, and the measurements are cached in a database \
        there, keyed on each file's size and modification time -- so running \
        again re-measures only what actually changed.

        A folder is walked for audio; anything that is not audio is counted \
        and reported rather than silently skipped, so a library that comes \
        back smaller than you expected can be explained.
        """)

    static let queue = HelpEntry(
        title: "To process",
        summary: "Everything found, in the order it will be worked through.",
        detail: """
        The order is the information. Tracks are taken thinnest low end \
        first -- not alphabetically, not in folder order -- because those \
        are the ones the sub stage is for. So "10 tracks" from a folder of \
        three hundred means a particular ten, and this is where you see \
        which.

        Rows within the limit are highlighted; the rest are dimmed rather \
        than hidden, because "not chosen" and "not found" are very different \
        problems and you should be able to tell them apart. Untick anything \
        you want left out -- doing so promotes the next track into range \
        rather than leaving a gap.

        Until a folder has been measured there are no numbers to sort on, so \
        the list is in name order and says so. Press Process and it fills in.
        """)

    static let survey = HelpEntry(
        title: "Survey",
        summary: "What a folder IS: how much arrived clipped, how thin its low end is.",
        detail: """
        Measuring reads the files and writes nothing. It answers a different \
        question from Process: not what a policy would do to a folder, but \
        what the folder actually is.

        Two numbers here decide things. How much of it arrived already \
        clipped says whether de-clipping earns a lossy generation on this \
        material. And how far a folder's low end sits under a reference is \
        where a profile's cap is supposed to come from -- disco-70s allows \
        8 dB because three 1970s corpora measured 6 to 9 dB short, and any \
        new profile should be built the same way rather than guessed.

        Name a reference folder to get the comparison. Changing it re-reads \
        what is already measured; it does not measure again.
        """)

    static let format = HelpEntry(
        title: "Format",
        summary: "FLAC keeps everything; MP3 and AAC are for the copies you play.",
        detail: """
        FLAC is lossless and the honest default: this stage has already \
        spent one decode, and a second lossy encode gives away more than \
        the sub is worth. It is also about four times the size.

        MP3 320 and AAC 256 are there because a set does not want lossless \
        files. Both are encoded once, from the processed audio, by ffmpeg.

        AAC says 256 rather than 320 because 320 is not something AAC \
        actually does: asked for it, ffmpeg's encoder was measured handing \
        back about 200 kbps and saying nothing. 256 is where AAC-LC is \
        generally reckoned transparent, and what Apple ship music at. Where \
        the ffmpeg build carries Apple's own encoder it is used in \
        preference to the native one.

        Both sides of an A/B pair always get the SAME format. A lossless \
        original against a lossy processed version would have you listening \
        to the codec and calling it the processing.

        MP3 out of MP3 carries the original's whole tag — cue points, \
        beatgrid, artwork, comments, everything — by copying it onto the \
        new file. ffmpeg will not do that on its own: it carries the text \
        and drops Serato's frames, measured as two in and none out.

        The cues land on the right beat because the timing survives: \
        decode, encode at 320, decode again, and the result is the same \
        length with a maximum sample difference of 0.00003 — the codec, \
        and no shift at all. LAME writes its delay and padding into the \
        header and the decoder gives them back.

        That was measured on a file this project made, whose marker frame \
        carries a byte ramp rather than real cues. It shows that ffmpeg \
        drops the frames and that a copied tag arrives intact, which is \
        what the container cares about. What it does not show is Serato \
        reading the result — no Serato has opened one. Copying the tag \
        whole is what makes that a reasonable bet: the bytes are never \
        interpreted, so there is nothing to misunderstand. It is still a \
        bet until a real library confirms it.

        FLAC and AAC carry artist, title, album and artwork — for now. Serato \
        does store markers in both (base64 in FLAC's Vorbis comments, \
        freeform atoms in M4A), so this is a gap rather than a limit. \
        Going MP3 to MP3 the tag is copied unread, which is why it is \
        safe; going MP3 to FLAC would mean translating between two \
        formats, and that needs checking against a real Serato file \
        rather than reasoning.
        """)

    // MARK: - Dynamics

    static let targetLRA = HelpEntry(
        title: "Loudness range",
        summary: "Widen the gap between the quiet parts and the loud ones. Off at zero.",
        detail: """
        What the loudness war took out over BARS, as opposed to over \
        milliseconds: the difference between a verse and a chorus, a breakdown \
        and a drop. Measured as LRA, the spread of a track's 3-second \
        loudness, and this widens it to the figure you set.

        It only ever turns things DOWN. A master that has been squashed to the \
        ceiling has no headroom left -- that is what made it one -- so raising \
        the loud parts would clip, or be trimmed straight back out. The \
        loudest 5% is left exactly where it is and everything below it is \
        pulled away, which costs the track some average loudness. The \
        levelling at the end of the chain gives that back, so the drop ends up \
        LOUDER than it started. What changed is what sits around it.

        Nothing is recovered here. A compressor that took 8 dB off a chorus \
        did not write down what it removed, so what comes back is a plausible \
        shape rather than the original one. That is worth doing and worth \
        being honest about.

        A caution for DJ use, which is what this is for: a track that drops 8 \
        LU in the breakdown disappears under the next record. Club masters are \
        flat partly because of the loudness war and partly because flat works \
        in a mix. Start low.
        """)

    static let maxAttenuation = HelpEntry(
        title: "Pull down at most",
        summary: "How far a quiet passage may be turned down to widen the range.",
        detail: """
        A cap rather than an estimate. Past a few dB the intro of a record \
        stops being quiet and starts being missing, and there is no \
        measurement that says where that line is -- so it is a limit you set \
        rather than one the tool works out.

        When the cap is reached before the target, the run says so instead of \
        quietly falling short. Raising the target past what the cap allows \
        otherwise looks like a setting that does nothing.
        """)

    static let transient = HelpEntry(
        title: "Attack",
        summary: "Give back the punch a fast limiter flattened. Off at zero.",
        detail: """
        The other half of "over-compressed", and the one that usually matters \
        more here: what was taken out over MILLISECONDS. The front of a kick, \
        the crack of a snare.

        Two envelopes of the same signal, one fast enough to follow a beater \
        click and one that cannot. Where the fast one stands above the slow \
        one there is an onset, and only there is any gain applied. A sustained \
        note gives both envelopes the same value and therefore no gain at all \
        -- which is what separates this from an expander. It cannot turn a \
        quiet passage down, so it cannot breathe.

        The measurement is crest, the gap between a track's peak and its \
        loudness. Measured here, about half a decibel of crest comes back per \
        decibel asked for; the setting is a ceiling on the gain at an onset, \
        not a promise about the statistic.

        This is broadband, unlike the kick punch above, which is deliberately \
        band-limited and deliberately does NOT move crest.
        """)

    static let minCrest = HelpEntry(
        title: "Skip above",
        summary: "A track already this peaky was never flattened, so leave it.",
        detail: """
        Crest is peak minus loudness. Above this figure the attack stage \
        declines, on the same principle as the sub's activity gate: most of \
        what a good policy does is decline.

        Eleven, measured on this library rather than taken from a book. \
        Sixteen folders read 9.6 to 10.7 and then 11.8 to 12.9, with a gap of \
        just over a decibel between them — wider than any other gap in the \
        set. The hard-limited records sit on one side of it and everything \
        else on the other.

        It was 12 to begin with, from the published range, and eleven folders \
        appeared to confirm it. Five more landed between 11.8 and 12.2 and \
        showed 12 cutting that upper group in half.

        Measure a folder first and read the survey. Setting this from taste \
        rather than from the numbers is how a stage ends up working on \
        material that never needed it.
        """)

    static let air = HelpEntry(
        title: "Air",
        summary: "Generate a top end where a shelf has nothing to lift. Off at zero.",
        detail: """
        The one control here that INVENTS. Everything else restores something \
        a measurement says was taken away; this makes harmonics that were \
        never in the recording and mixes them in.

        That is the point of it. A high shelf multiplies what is in the band, \
        so where the band is empty — a lossy codec cut it, a tape rolled off — \
        a shelf raises the noise under it and nothing else. A harmonic \
        generator takes the octave below and folds its overtones upward, so 5 \
        kHz of material becomes 10 and 15 and 20 kHz of new content. Musically \
        related to the source, which is why it reads as detail rather than as \
        hiss.

        Measured on a track with everything above 16 kHz removed: a 3 dB shelf \
        moved the 16–22 kHz band by 3 dB, which is 3 dB more of nothing. 3 dB \
        of air moved it by 16.

        The number is what the 8–20 kHz band actually rises by, not a mix \
        level — the harmonics are scaled to hit it and the run reports what it \
        got. Loudness barely moves, which is the famous thing about an \
        exciter; peak moves a great deal, because the harmonics land on the \
        source's own peaks. The levelling that ends the chain takes that back \
        out, but it is why this is a small control.

        Check the survey's cliff column first. A folder with a gentle roll-off \
        already has a top end and this is taste; one with a wall has had it \
        thrown away by an encoder, and the honest fix there is a better rip.

        With "Size it per track against a reference" on, this number becomes \
        a ceiling rather than a flat amount: each track is measured against \
        the reference folder's own 8–20 kHz band and given air up to this \
        much, in proportion to how much brighter the reference already is -- \
        the same idea as the sub's cap, applied to the top end instead of \
        the bottom.
        """)

    static let airTune = HelpEntry(
        title: "Air from",
        summary: "Where the harmonics are generated from, upward.",
        detail: """
        The exciter high-passes the track at this frequency and makes \
        harmonics of what it finds, so the new content lands an octave above \
        and up. 3.5 kHz feeds 7 kHz and above — presence and air.

        Lower is fuller and cheaper. Higher is more sizzle and costs a great \
        deal more headroom: asking for 3 dB of air on the same fixture cost \
        2.2 dB of peak tuned at 2 kHz, 4.3 dB at 3.5 kHz and 7.3 dB at 5 kHz.

        It does not change how much air comes out — that is set by the amount, \
        and normalised — only what it is made of and what it costs.
        """)

    static let output = HelpEntry(
        title: "To",
        summary: "Where processed files go. Originals are never written to.",
        detail: """
        Defaults to ~/Music/LoudnessLab. Change it to write straight into \
        wherever your library lives.

        The measurements do not follow it. They stay in one database, \
        because pointing the output somewhere else for one run should not \
        hide a folder you measured last week.

        "Clear" deletes every FLAC, MP3 and M4A sitting directly in this \
        folder -- both sides of every A/B pair -- so a new batch is not \
        mixed in with an old one. Nothing else in the folder is touched: \
        not the manifest, not anything put there by hand.
        """)

    // MARK: - Profile

    static let profile = HelpEntry(
        title: "Profile",
        summary: "A named policy. Fixes what is allowed, not what each track gets.",
        detail: """
        A profile fixes what the tool is ALLOWED to do. It does not fix what \
        each track gets -- that still comes from measuring the track, and \
        that distinction is the whole design.

        level-only: lossless levelling and nothing else. No decode, no \
        re-encode, reversible.
        restore: levelling, plus sub sized per track against a reference \
        corpus. Needs a reference. Lossy.
        disco-70s: the same, with the cap raised to 8 dB and the gate lowered \
        to 18. Three independent 1970s disco corpora -- 108 tracks over two \
        compilations and a 2003 reissue -- agree within about 3 dB from 32 to \
        63 Hz, sitting 6 to 9 dB under a current reference. There is nothing \
        usable below 32 Hz: the 20 Hz band reads as empty on all three.

        There are deliberately no era profiles. Era-keyed curves were the \
        obvious idea and the measurements ruled them out twice: every clean \
        corpus here is a compilation carrying a reissue date, so a rule \
        reading the year treats old masters as modern; and within a single \
        era the spread between tracks at 32 Hz is 14-24 dB against roughly \
        5 dB between one era's median and the next, so a curve fitted to the \
        era moves the median and leaves most tracks further from the target \
        than they started.

        "Save…" keeps whatever is on the sliders right now under a name of \
        your own, listed below the built-in profiles. It carries no measured \
        claim -- unlike the profiles above it, it is not backed by a \
        corpus -- so it cannot be saved under one of their names. "Delete" \
        removes a saved one; the built-in profiles cannot be deleted.
        """)

    // MARK: - De-clipping

    static let declip = HelpEntry(
        title: "Restore clipped peaks",
        summary: "Puts back peaks that were flattened before the file reached you.",
        detail: """
        About a third of the 1970s disco measured for this project carries \
        runs of consecutive samples pinned at full scale. That is not \
        loudness, it is a flat top where a peak used to be, and the flat top \
        IS the distortion -- a clipped waveform is the original plus a family \
        of odd harmonics, which is why heavily clipped material sounds hard \
        and small rather than loud.

        Nothing can recover what was thrown away. What this does is draw the \
        arc the signal was already on when it ran out of headroom, taking the \
        value and slope of the audio on both shoulders. The method is chosen \
        for being self-limiting rather than clever: on a genuinely clipped \
        peak it arcs to within 0.1 dB of the true peak, and on a peak that \
        merely touched full scale without clipping the shoulders are already \
        turning over, so it changes the audio by thousandths of a decibel. A \
        false detection therefore costs almost nothing, which is the only \
        basis on which this is safe to run across a library.

        Two honest limits. On clean audio deliberately clipped and restored, \
        reconstruction improves by 3.3 to 3.9 dB -- but through MP3 the real \
        figure is much smaller: about 2.0 dB at light clipping, falling to \
        0.4 dB at heavy. And a limiter is not a clipper: where a master was \
        squashed rather than clipped the shoulders are squashed too, no flat \
        run appears, and there is nothing here to find.

        It runs first, before anything else, because it puts peaks BACK and \
        everything after has to fit underneath them.
        """)

    static let declipMax = HelpEntry(
        title: "Lift cap",
        summary: "The most any single peak may be lifted. Default 6 dB.",
        detail: """
        A hard ceiling on the reconstruction, so an unusual run cannot \
        produce an implausible peak. Separately, any run longer than 10 ms is \
        refused outright -- longer than a clipped peak can plausibly be, so a \
        long flat span is more likely to be something else.
        """)

    // MARK: - Sub

    static let amount = HelpEntry(
        title: "Sub",
        summary: "dB added in the 31.5-63 Hz octave, under the kicks. Zero is off.",
        detail: """
        Energy laid into the sub octave, synchronised to the kicks the \
        detector found, rather than an equaliser lifting the whole band for \
        the length of the track. Zero turns the stage off.

        With per-track sizing on, this figure is ignored and each track gets \
        its own measured shortfall instead.
        """)

    static let auto = HelpEntry(
        title: "Size it per track against a reference",
        summary: "Each track gets its own measured shortfall, not one figure for all.",
        detail: """
        The difference between a policy and a preset. With this off, every \
        track gets the same number of decibels whether it needs them or not. \
        With it on, each track is measured against the reference folder's low \
        end and given what it is actually short of.

        Air is sized the same way, against the reference folder's top end, \
        whenever both this and Air are on -- Air's own amount then reads as \
        a cap rather than a flat number every track gets.

        This needs a reference to measure against. Without one the setting \
        cannot be honoured, and the run stops rather than quietly applying \
        the fixed amount instead -- which would be the app doing something \
        other than the policy on screen.
        """)

    static let reference = HelpEntry(
        title: "Reference folder",
        summary: "The folder whose low end is the target. Name one you have measured.",
        detail: """
        Enough of the folder's name to identify it. If the text matches more \
        than one folder it resolves to nothing and the run stops with a \
        message, rather than picking one and leaving you to wonder which.
        """)

    static let maxAmount = HelpEntry(
        title: "Cap",
        summary: "Ceiling on the per-track amount when sizing automatically.",
        detail: """
        A track measured as 12 dB short is more likely to be unusual than to \
        need 12 dB. The cap bounds what any single track can be given. \
        disco-70s raises it to 8 because the deficit on that material was \
        measured at 6 to 9 dB.
        """)

    static let minActivity = HelpEntry(
        title: "Gate",
        summary: "Skip tracks whose sub octave barely moves. Rumble ~11 dB, a groove ~44.",
        detail: """
        How much the sub octave has to swing over the track before the stage \
        will touch it. The point is to tell a bassline from a static floor: \
        tape rumble, air conditioning, or a room tone measures about 11 dB of \
        movement, a real groove about 44. Values in between are a judgement \
        call, which is why this is a control and not a constant.

        Adding sub to a track whose low end never moves does not give it a \
        bassline, it raises its noise floor. disco-70s lowers the gate to 18 \
        because that material is the most groove-locked in the project and \
        sits nearest the threshold, where a marginal track is better reviewed \
        than silently dropped.
        """)

    // MARK: - Punch

    static let punch = HelpEntry(
        title: "Punch",
        summary: "Attack emphasis on each kick, in 2-6 kHz. Adds no energy.",
        detail: """
        Emphasis on the beater click -- the snap of the kick, not its body, \
        which is why it works at 2-6 kHz and not in the bass.

        This is a transient shaper, not an expander, and the difference is \
        the point: the band is renormalised afterwards, so it comes out \
        holding exactly the energy it went in with. Nothing is added; the \
        distribution in time is changed. That means it cannot make a track \
        brighter overall, only sharper at the front of each kick.

        Off by default, and disco-70s leaves it off: live drummers, and on \
        that material 2-6 kHz is full of hi-hat and tambourine rather than \
        beater click.
        """)

    static let punchDecay = HelpEntry(
        title: "Decay",
        summary: "How long the attack emphasis takes to fall away. Default 8 ms.",
        detail: """
        Short values sharpen the very front of the kick; longer ones let the \
        emphasis run into the body of it, which starts to sound like a lift \
        rather than an attack.
        """)

    // MARK: - Levelling

    static let target = HelpEntry(
        title: "Level to",
        summary: "The level each written file is brought to, measured on the estimator.",
        detail: """
        Levelling happens last, because everything before it moves loudness: \
        restoring a peak, laying in sub and reshaping attacks all change what \
        the track measures. Whatever happens last has to be the levelling, or \
        the number on screen is not the number in the file.
        """)

    static let estimator = HelpEntry(
        title: "On",
        summary: "Which loudness statistic to level on. s_p95 describes the loud part.",
        detail: """
        lufs_i is integrated loudness: one number for the whole track, \
        quiet intro and all. s_p95 is the 95th percentile of the rolling \
        3-second loudness -- it describes the loud part of the track rather \
        than its average, which is what actually matters when tracks are \
        mixed one into another. s_p50 is the median, s_max the loudest \
        moment.

        The choice only matters as much as the two disagree, and they \
        disagree more as a track's loudness range grows. Measured on this \
        library, the median gap between s_p95 and lufs_i by loudness-range \
        band was 1.16, 1.70, 2.16, 2.47 and 2.76 dB. On a track with a quiet \
        intro and a loud body, levelling on integrated loudness makes the \
        body too loud.
        """)

    static let peakCeiling = HelpEntry(
        title: "Peak ceiling",
        summary: "True peak no gain may exceed. -1.0 dBTP, not -0.1, on purpose.",
        detail: """
        Levelling stops here even if that means falling short of the target. \
        The default is -1.0 rather than the -0.1 you often see because the \
        measurement itself is not that precise: 4x oversampled true-peak \
        detection is only good to about 0.5 dB, and an MP3 re-encode moves \
        peaks around on top of that. A ceiling tighter than the error bar is \
        a ceiling that gets crossed.
        """)

    // MARK: - The run

    static let limit = HelpEntry(
        title: "Only the first",
        summary: "Off by default: everything ticked gets processed.",
        detail: """
        Off means all of it. A folder added is a folder meant to be worked \
        on, and a silent cap of ten on three hundred tracks is a surprise \
        rather than a convenience.

        Turned on, the count applies to the order in the middle pane — \
        measured low end, not folder order — so a small number gives you \
        the tracks that stand to gain most rather than whatever sorted \
        first. Useful for trying a profile before committing a folder to it.

        Either way, the same record twice in one batch is processed once, \
        matched on artist and title with case and punctuation ignored. A \
        library of compilations is largely the same songs, and two files \
        differing only in which disc they came off is not something anyone \
        wants two of.
        """)

    static let compare = HelpEntry(
        title: "Write A/B pairs",
        summary: "Writes the original alongside the processed version, level matched.",
        detail: """
        Both versions are written from the same decode, so they are the same \
        length to the sample and can be switched between mid-bar.

        They are also level matched, both brought DOWN to whichever is \
        quieter so neither clips. This is not politeness: louder wins every \
        blind comparison regardless of merit, so without matching you would \
        be testing which is louder rather than which is better.
        """)

    static let dryRun = HelpEntry(
        title: "Dry run",
        summary: "Measure and report what would happen. Writes nothing.",
        detail: """
        Every measurement, every decision and every per-track figure, with no \
        files produced. The fastest way to see what a profile would actually \
        do to a folder before committing a lossy generation to it.
        """)

    // MARK: - Comparing

    static let switching = HelpEntry(
        title: "Switch version (Shift-Space)",
        summary: "Swaps versions at the same instant, with no gap or restart.",
        detail: """
        Every version is playing already, in step, with all but one silent. \
        Switching changes which one you hear; it does not start anything, so \
        there is no gap, no restart and no drift.

        They stay in step because they are scheduled together on one clock at \
        a shared start time. If you hear a tick or a flam on the switch, that \
        is a bug worth reporting rather than something to work around.
        """)

    static let matchLoudness = HelpEntry(
        title: "Match loudness",
        summary: "Plays every version at the same loudness, so the louder one cannot win.",
        detail: """
        Applies the per-version gain needed to bring them all to the same \
        measured level during playback, on top of the matching already done \
        when the files were written.

        Turn it off only to hear what the processed file will actually sound \
        like at its own level. For deciding whether the processing helped, \
        leave it on: louder is reliably judged better, whatever else is true \
        of it.
        """)

    static let blind = HelpEntry(
        title: "Blind",
        summary: "Hides which version is which until you turn it off.",
        detail: """
        Knowing which is the processed one biases you toward hearing what you \
        expected. Better still, have someone else shuffle them, or at least \
        listen to each version first on half the tracks.
        """)

    // MARK: - Results

    static let results = HelpEntry(
        title: "Results columns",
        summary: "Sub, Air and Punch are what was applied. Clips and Lift are the de-clipper.",
        detail: """
        Sub, Air and Punch are what was actually applied to that track, which \
        with per-track sizing on is not the same as what was asked for. Air \
        reads "—" for a manifest written before this column existed, rather \
        than a false "+0.00 dB".

        Clips is the number of clipped runs restored. Lift is the median \
        amount one restored peak gained -- deliberately not the change in the \
        file's peak, because on an MP3 of a clipped master the file peak is \
        set by codec overshoot and barely moves however many runs are \
        restored. One track here decoded at +2.27 dBFS and read +0.00 dB of \
        change while 402 runs had been lifted by a median of 0.29 dB.
        """)

    /// A named struct rather than a tuple, because `ForEach` over an array
    /// of tuples needs the element destructured in the closure, which is
    /// the sort of thing that compiles in one position and not the next.
    static let sections: [HelpSection] = [
        HelpSection("Choosing music", [folders, queue, survey]),
        HelpSection("Policy", [profile]),
        HelpSection("Clipped peaks", [declip, declipMax]),
        HelpSection("Sub bass", [amount, auto, reference, maxAmount, minActivity]),
        HelpSection("Attack", [punch, punchDecay]),
        HelpSection("Dynamics", [targetLRA, maxAttenuation, transient, minCrest]),
        HelpSection("Air", [air, airTune]),
        HelpSection("Level", [target, estimator, peakCeiling]),
        HelpSection("The run", [limit, format, output, compare, dryRun]),
        HelpSection("Listening", [switching, matchLoudness, blind]),
        HelpSection("Results", [results]),
    ]
}

struct HelpSection: Identifiable {
    let name: String
    let entries: [HelpEntry]

    init(_ name: String, _ entries: [HelpEntry]) {
        self.name = name
        self.entries = entries
    }

    var id: String { name }
}

// MARK: - The window

struct HelpView: View {
    /// Two halves, because they answer different questions. The guide is
    /// for someone who has not used this before: what it is for, what
    /// order to do things in, how to read the survey. The reference is for
    /// someone standing at a control wanting to know what it does.
    private enum Half: String, CaseIterable, Identifiable {
        case guide = "Guide", settings = "Every setting"
        var id: String { rawValue }
    }

    @State private var half: Half = .guide
    @State private var query = ""
    /// Read once. It is a file on disk and the window is reopened often.
    private static let document = HelpDocument.bundled("loudness-lab",
                                                       subdirectory: "Help")

    private var matches: [HelpSection] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return Help.sections }
        return Help.sections.compactMap { section in
            let kept = section.entries.filter {
                $0.title.lowercased().contains(needle)
                    || $0.summary.lowercased().contains(needle)
                    || $0.detail.lowercased().contains(needle)
            }
            return kept.isEmpty ? nil : HelpSection(section.name, kept)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $half) {
                ForEach(Half.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 10)

            if half == .settings {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button(action: { query = "" }) { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
            } else {
                Spacer().frame(height: 10)
            }
            Divider()

            if half == .guide {
                guidePane
            } else {
                settingsPane
            }
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 680)
    }

    /// The document that ships with the app. If it failed to copy, say so
    /// plainly and point at the half that still works, rather than showing
    /// an empty pane that looks like a bug in the app.
    @ViewBuilder private var guidePane: some View {
        if let document = Self.document {
            ScrollView {
                HelpDocumentView(document: document)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 8) {
                Text("The guide did not ship with this build.")
                    .foregroundStyle(.secondary)
                Text("Every setting is still documented under "
                     + "\"Every setting\".")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var settingsPane: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if matches.isEmpty {
                        Text("Nothing matches \"\(query)\".")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(matches) { section in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(section.name.uppercased())
                                .font(.caption).bold()
                                .foregroundStyle(.secondary)
                            ForEach(section.entries) { entry in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.title).font(.headline)
                                    Text(entry.summary)
                                        .font(.callout).foregroundStyle(.secondary)
                                    Text(entry.detail)
                                        .font(.callout)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
    }
}
