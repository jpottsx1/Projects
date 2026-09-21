import Foundation

/// Mirrors `profiles.FIELDS` on the Python side.
///
/// Deliberately a mirror and not a second source of truth: the tool decides
/// what a setting means and what it defaults to, and anything set here is
/// passed through as the same flag a person would type. Where a value equals
/// the default it is not passed at all, so a chosen profile keeps deciding it.
struct Settings: Codable, Equatable {
    var target: Double = -16.0
    var estimator: String = "s_p95"
    var peakCeiling: Double = -1.0
    var auto: Bool = false
    var reference: String? = nil
    var amount: Double = 5.0
    var maxAmount: Double = 6.0
    var minActivity: Double = 20.0
    var punch: Double = 0.0
    var punchDecay: Double = 8.0
    var declip: Bool = false
    var declipMax: Double = 6.0

    enum CodingKeys: String, CodingKey {
        case target, estimator, auto, reference, amount, punch, declip
        case peakCeiling = "peak_ceiling"
        case maxAmount = "max_amount"
        case minActivity = "min_activity"
        case punchDecay = "punch_decay"
        case declipMax = "declip_max"
    }

    static let estimators = ["lufs_i", "s_p50", "s_p90", "s_p95", "s_max"]

    /// The flags this differs from the defaults by. A profile the user picked
    /// still decides everything left out.
    func flags() -> [String] {
        var out: [String] = []
        let base = Settings()
        if target != base.target { out += ["--target", String(target)] }
        if estimator != base.estimator { out += ["--estimator", estimator] }
        if peakCeiling != base.peakCeiling { out += ["--peak-ceiling", String(peakCeiling)] }
        if auto { out += ["--auto"] }
        if let reference, !reference.isEmpty { out += ["--reference", reference] }
        if amount != base.amount { out += ["--amount", String(amount)] }
        if maxAmount != base.maxAmount { out += ["--max-amount", String(maxAmount)] }
        if minActivity != base.minActivity { out += ["--min-activity", String(minActivity)] }
        if punch != base.punch { out += ["--punch", String(punch)] }
        if punchDecay != base.punchDecay { out += ["--punch-decay", String(punchDecay)] }
        if declip { out += ["--declip"] }
        if declipMax != base.declipMax { out += ["--declip-max", String(declipMax)] }
        return out
    }
}
