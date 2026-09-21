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

        return ["level-only": levelOnly, "restore": restore, "disco-70s": disco]
    }()
}
