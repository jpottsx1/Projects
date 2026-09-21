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

        return ["level-only": levelOnly, "restore": restore,
                "disco-70s": disco, "eighties": eighties]
    }()
}
