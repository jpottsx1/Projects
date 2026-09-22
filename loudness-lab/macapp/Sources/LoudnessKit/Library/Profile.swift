import Foundation

/// A named bundle of settings, so a policy can be stated once and audited.
///
/// A port of `loudnesslab/profiles.py`. A profile fixes what the tool is
/// ALLOWED to do. It does not fix what each track gets: that still comes
/// from measuring the track, and that distinction is the whole design.
///
/// It is also why there are no era profiles. Era-keyed curves were the
/// obvious idea and the measurements ruled them out twice over. Every clean
/// corpus in this project is a compilation carrying a reissue date, so a
/// rule reading the year treats old masters as modern. And within a single
/// era the spread between tracks at 32 Hz is 14-24 dB, against roughly 5 dB
/// between one era's median and the next, so a curve fitted to the era moves
/// the median and leaves most tracks further from the target than they
/// started.
public struct Profile: Codable, Equatable, Sendable {
    public var description: String = ""
    public var target: Double = -16.0        // level to aim at, on `estimator`
    public var estimator: String = "s_p95"
    public var peakCeiling: Double = -1.0    // dBTP no gain may exceed
    public var auto: Bool = false            // size the sub from each track
    public var reference: String?            // the corpus --auto measures against
    public var amount: Double = 5.0          // fixed sub, when auto is off
    public var maxAmount: Double = 6.0
    public var minActivity: Double = 20.0    // below this the sub octave is a floor
    public var punch: Double = 0.0
    public var punchDecay: Double = 8.0
    public var declip: Bool = false
    public var declipMax: Double = 6.0
    // Putting dynamics back. Both off by default: they reshape what a
    // compressor left rather than recovering anything, so they are a
    // choice about a record and not a repair every record wants.
    public var targetLRA: Double = 0.0       // loudness range to widen to
    public var maxAttenuation: Double = 6.0  // how far the quiet parts may drop
    public var transient: Double = 0.0       // dB of emphasis at an onset
    public var minCrest: Double = 12.0       // above this, nothing flattened it

    public init() {}

    /// snake_case on the wire, matching what the Python writes, so a
    /// manifest from either side is readable by the other.
    public enum CodingKeys: String, CodingKey {
        case description, target, estimator, auto, reference, amount, punch, declip
        case peakCeiling = "peak_ceiling"
        case maxAmount = "max_amount"
        case minActivity = "min_activity"
        case punchDecay = "punch_decay"
        case declipMax = "declip_max"
        case transient
        case targetLRA = "target_lra"
        case maxAttenuation = "max_attenuation"
        case minCrest = "min_crest"
    }

    /// Tolerant of a key that is not there, which the synthesised decoder
    /// is not: a property's default value does NOT make its key optional.
    ///
    /// The manifest the command line writes leaves `description` out
    /// entirely -- it is a property of the named profile, not of the run --
    /// and one missing key fails the whole document. That would have shown
    /// up as the app processing a folder correctly and then showing no
    /// results at all, which is a long way from the cause.
    ///
    /// It also means a profile written by a newer version, or an older one,
    /// still loads with the fields it does have.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Profile()
        func number(_ key: CodingKeys, _ default_: Double) throws -> Double {
            try values.decodeIfPresent(Double.self, forKey: key) ?? default_
        }
        description = try values.decodeIfPresent(String.self, forKey: .description)
            ?? fallback.description
        target = try number(.target, fallback.target)
        estimator = try values.decodeIfPresent(String.self, forKey: .estimator)
            ?? fallback.estimator
        peakCeiling = try number(.peakCeiling, fallback.peakCeiling)
        auto = try values.decodeIfPresent(Bool.self, forKey: .auto) ?? fallback.auto
        reference = try values.decodeIfPresent(String.self, forKey: .reference)
        amount = try number(.amount, fallback.amount)
        maxAmount = try number(.maxAmount, fallback.maxAmount)
        minActivity = try number(.minActivity, fallback.minActivity)
        punch = try number(.punch, fallback.punch)
        punchDecay = try number(.punchDecay, fallback.punchDecay)
        declip = try values.decodeIfPresent(Bool.self, forKey: .declip) ?? fallback.declip
        declipMax = try number(.declipMax, fallback.declipMax)
        targetLRA = try number(.targetLRA, fallback.targetLRA)
        maxAttenuation = try number(.maxAttenuation, fallback.maxAttenuation)
        transient = try number(.transient, fallback.transient)
        minCrest = try number(.minCrest, fallback.minCrest)
    }

    public static let estimators = ["lufs_i", "s_p50", "s_p90", "s_p95", "s_max"]

    public static let builtIn: [String: Profile] = {
        var levelOnly = Profile()
        levelOnly.description = "Lossless levelling and nothing else. No decode, "
            + "no re-encode, reversible."
        levelOnly.amount = 0

        var restore = Profile()
        restore.description = "Levelling, plus sub sized per track against a "
            + "reference corpus. Needs a reference. Lossy."
        restore.auto = true

        // Measured, not guessed. Three independent 1970s disco corpora -- 108
        // tracks over two compilations and a 2003 reissue -- agree within
        // about 3 dB from 32 to 63 Hz, sitting 6 to 9 dB under a current
        // reference. Nothing usable below 32 Hz: the 20 Hz band reads as
        // empty on all three. The 2003 reissue measures THINNER down low than
        // the two older compilations, which is how we know it is era
        // mastering being described rather than a remastering engineer.
        var disco = Profile()
        disco.description = "1970s disco. Deficit of 6-9 dB across 32-63 Hz, "
            + "agreed by three independent corpora; nothing below 32 Hz to "
            + "lift. Needs a reference. Lossy."
        disco.auto = true
        disco.maxAmount = 8
        // Lower than the default 20. Disco is the most groove-locked material
        // in the project and sits nearest the threshold; on a corpus this
        // consistent a marginal track is better reviewed than silently dropped.
        disco.minActivity = 18
        // Off to start: live drummers, and 2-6 kHz is full of hi-hat and
        // tambourine rather than beater click.
        disco.punch = 0
        // On, and measured rather than assumed. Two discs of a 2003 disco
        // reissue: 9 of 17 clipped on one, 13 of 17 on the other -- 53% and
        // 76%, against 0% on four of five discs of an eighties compilation
        // in the same library. Worst offenders at 324 and 398 runs. The
        // library average would have said 13.6% and decided nothing.
        //
        // The gain through a lossy codec is small -- about 2 dB at light
        // clipping falling to 0.4 at heavy, and this is heavy -- so it is on
        // because the damage is real and the method is self-limiting, not
        // because it is free. Listen before committing a folder to it.
        disco.declip = true

        // Measured the same way, on a library this project did not come
        // from: five discs of "100 Hits - The New Romantics (2011)", 100
        // tracks, against 43 tracks of current music in the same database.
        //
        //   New Romantics discs   -25.81  -23.54  -23.32  -21.88  -21.07
        //   current reference     -14.89
        //
        // 6.2 to 10.9 dB short across 31.5-63 Hz, median near 8.2 --
        // THINNER than the disco corpora at 6 to 9. Worth stating because
        // it was not the expected result: that compilation is a 2011
        // master, so the mastering is modern and the low end still was not
        // put there. The 4.7 dB spread across five discs of one boxed set
        // is why `auto` is on rather than a fixed amount.
        var eighties = Profile()
        eighties.description = "1980s pop and new wave. Short by 6-11 dB "
            + "across 31.5-63 Hz, measured over five discs. Needs a "
            + "reference. Lossy."
        eighties.auto = true
        // Eleven, just above the thinnest disc measured. It was ten until
        // the full table came back with a reference set: Disc 4 sits 10.92
        // under, so a cap of ten held about half that disc below what it
        // actually needed -- the exact failure this comment warned about
        // when the cap was first chosen from a partial reading.
        //
        // Disco's eight sits the same distance above ITS measured worst
        // (7.35), so the two profiles bound their material the same way
        // rather than by taste.
        eighties.maxAmount = 11
        // Left at the default. Disco lowered it to 18 because that material
        // was measured sitting near the threshold; nothing has measured
        // eighties activity, and moving a gate on a guess is how a static
        // floor gets mistaken for a bassline.
        eighties.minActivity = 20

        // Measured on "Now Yearbook 99 (2026)", 82 tracks over four CDs,
        // against the same 43-track modern reference the others use. The
        // first corpus here whose problem is NOT a missing low end.
        //
        //   low end 31.5-63 Hz  CD4 -18.53  CD1 -18.43  CD3 -18.21  CD2 -17.38
        //   reference           -14.89
        //
        // A deficit of 2.5 to 3.6 dB, against 6.2-10.9 for the eighties and
        // 4.9-7.4 for the disco. By 1999 the bottom end was being put there.
        //
        // What IS wrong with it is everything the loudness war did:
        //
        //   median LUFS-I  -9.48      median true peak  +0.86 dBTP
        //   median s_p95   -7.71      median LRA         5.40
        //   median crest              10.01 dB
        //   arrived clipped           36 of 82 (43.9%), CD4 at 60%
        //   worst offender            9652 clipped runs
        //
        // Crest at 10.0 is squarely in the hard-limited band (8-11) and LRA
        // at 5.4 in the loudness-war band (4-6). Both dynamics stages have
        // something to do here, which is not true of any other corpus in
        // this library. Per disc:
        //
        //   disc   LRA   crest   clipped
        //   CD2    6.49   9.88     29%
        //   CD3    5.45   9.95     38%
        //   CD4    5.66  10.47     60%
        //   CD1    4.44  10.73     50%
        //
        // LRA and crest run in OPPOSITE directions (r = -0.80 on four
        // folder medians, so suggestive rather than settled). CD2 has the
        // most range left and the least punch; CD1 the reverse. A single
        // "how squashed is it" number would call CD2 the healthiest and CD1
        // the worst, when they are damaged in different ways and want
        // different stages. The top end needs nothing: these discs run 3.6 to
        // 6.4 dB ABOVE the reference at 8-16 kHz.
        var nineties = Profile()
        nineties.description = "Late 1990s pop. Low end nearly there "
            + "(2.5-3.6 dB short), but hard-limited: crest 10.0, LRA 5.4, "
            + "44% arrived clipped. Needs a reference. Lossy."
        nineties.auto = true
        // Just above the measured worst of 3.64, on the same rule that gave
        // disco 8 against 7.35 and the eighties 11 against 10.92.
        nineties.maxAmount = 4
        nineties.minActivity = 20
        // Between the eighties (0-10%, off) and the disco reissue (53-76%,
        // on). Expect the SMALLEST gain here: de-clipping returns about
        // 2 dB at light clipping and 0.4 at heavy, and 9652 runs is heavy.
        nineties.declip = true
        // Off. 2-6 kHz here is programmed hats and samples, and the top end
        // already sits above the reference.
        nineties.punch = 0
        // From 5.40, deliberately modest: +1.6 LU drops the quietest
        // passages 1.6 dB and never approaches the cap. A bigger target
        // would make these duck under the next record, which for a DJ is
        // the failure and not the feature.
        nineties.targetLRA = 7
        // Crest 10.01 -> about 11.5 at roughly half a dB per dB, landing
        // just under the gate rather than past it. The exchange rate was
        // measured on a synthetic fixture, so that is an extrapolation
        // until this corpus is processed and measured again. All four discs
        // (9.88 to 10.73) pass the gate and the spread is only 0.85 dB, so
        // unlike the sub, one figure genuinely suits the whole corpus.
        nineties.transient = 3
        nineties.minCrest = 12

        return ["level-only": levelOnly, "restore": restore,
                "disco-70s": disco, "eighties": eighties,
                "nineties": nineties]
    }()
}
