import Foundation

/// The stem mix's numbers: what the prepared layers are, what was chosen,
/// and the gain each layer plays at.
///
/// The Python prepares the layers (`loudnesslab/stemmix.py`) and writes
/// the stems, the sub, punch and the air into a folder with a `mix.json`. This
/// plays them; Commit hands the choice back and the same Python builds the
/// track from the same layers at the same gains. So the mapping from a
/// fader to a gain is written twice -- here, to play it, and in
/// `stemmix.layer_gains`, to write it -- and `StemMixTests` holds this one
/// to the Python's numbers (tests/test_stemmix.py has the same vectors).
enum StemMix {

    static let stems = ["drums", "bass", "other", "vocals"]
    static let subLayers = ["sub_tone", "sub_kick", "sub_mix_kick"]
    static let punchLayers = ["punch_band", "punch_drum_kicks", "punch_mix_kicks"]
    /// Summed in this order, here and in the Python.
    static let layers = ["residual"] + stems + subLayers + punchLayers + ["air"]

    /// What each stem's fader is called on screen.
    static func label(_ stem: String) -> String {
        switch stem {
        case "drums": return "Drums"
        case "bass": return "Bass guitar"
        case "other": return "Melody"
        case "vocals": return "Vocals"
        default: return stem
        }
    }

    /// Where the sub and punch find their kicks.
    enum Kicks: String, Codable, CaseIterable, Identifiable {
        case drums, mix
        var id: String { rawValue }
        var label: String { self == .drums ? "Drum track" : "Full mix" }
    }

    /// The bundle's mix.json.
    struct Bundle: Decodable, Equatable {
        struct Limits: Decodable, Equatable {
            var floorDB: Double, levelMaxDB: Double, subMaxDB: Double, airMaxDB: Double
            var punchMaxDB: Double
            enum CodingKeys: String, CodingKey {
                case floorDB = "floor_db", levelMaxDB = "level_max_db"
                case subMaxDB = "sub_max_db", airMaxDB = "air_max_db"
                case punchMaxDB = "punch_max_db"
            }
        }
        struct Defaults: Decodable, Equatable {
            var subDB: Double, airDB: Double, punchDB: Double
            var kicks: Kicks, bassline: Bool
            enum CodingKeys: String, CodingKey {
                case subDB = "sub_db", airDB = "air_db", punchDB = "punch_db"
                case kicks, bassline
            }
        }
        /// One sub layer's sums: its own band energy and its cross term
        /// with the track's.
        struct Part: Decodable, Equatable {
            var available: Bool
            var note: String?
            var cross: Double = 0, energy: Double = 0
        }
        /// The sub: `energy` is the track's 31.5-63 Hz octave. `tone` is the
        /// bass line's tone, `kicks` the bursts under the drum track's
        /// kicks, `mixKicks` the bursts under the full mix's.
        struct Sub: Decodable, Equatable {
            var available: Bool
            var note: String?
            var energy: Double
            var tone: Part, kicks: Part, mixKicks: Part
            enum CodingKeys: String, CodingKey {
                case available, note, energy, tone, kicks
                case mixKicks = "mix_kicks"
            }
        }
        /// Punch's sums on the drum stem: the 2-6 kHz band's energy, and
        /// for each set of kicks the attack layer's cross term and energy.
        struct Punch: Decodable, Equatable {
            struct Part: Decodable, Equatable {
                var available: Bool
                var note: String?
                var cross: Double, attackEnergy: Double
                enum CodingKeys: String, CodingKey {
                    case available, note, cross, attackEnergy = "attack_energy"
                }
            }
            var energy: Double
            var kicks: Part, mixKicks: Part
            enum CodingKeys: String, CodingKey {
                case energy, kicks, mixKicks = "mix_kicks"
            }
        }
        /// Air's: the track's 16-20 kHz band, and the harmonics'.
        struct Air: Decodable, Equatable {
            var available: Bool
            var note: String?
            var guided: Bool?
            var before: Double, cross: Double, added: Double
        }
        var version: Int
        var path: String
        var name: String?
        var seconds: Double
        var files: [String: String]
        var limits: Limits
        var defaults: Defaults
        var sub: Sub
        var punch: Punch
        var air: Air

        static func read(_ folder: URL) throws -> Bundle {
            let data = try Data(contentsOf: folder.appendingPathComponent("mix.json"))
            return try JSONDecoder().decode(Bundle.self, from: data)
        }

        /// The sub under these kicks, or why there is none.
        func subPart(_ kicks: Kicks) -> Part { kicks == .mix ? sub.mixKicks : sub.kicks }
        func punchPart(_ kicks: Kicks) -> Punch.Part { kicks == .mix ? punch.mixKicks : punch.kicks }
    }

    /// What the faders say. Written as the choice file Commit hands to the
    /// command (`--stem-mix`).
    struct Choice: Codable, Equatable {
        var bundle: String
        var levelsDB: [String: Double]
        var subDB: Double
        var airDB: Double
        var punchDB: Double = 0
        var kicks: Kicks = .drums
        var bassline: Bool = true

        enum CodingKeys: String, CodingKey {
            case bundle, levelsDB = "levels_db", subDB = "sub_db", airDB = "air_db"
            case punchDB = "punch_db", kicks, bassline
        }

        /// Every stem at 0 dB; the sub, punch and air, and where the kicks
        /// are found, as the settings would have had them for this track.
        static func start(_ bundle: Bundle, folder: URL) -> Choice {
            let d = bundle.defaults
            return Choice(bundle: folder.path,
                          levelsDB: Dictionary(uniqueKeysWithValues: stems.map { ($0, 0) }),
                          subDB: bundle.sub.available ? d.subDB : 0,
                          airDB: bundle.air.available ? d.airDB : 0,
                          punchDB: d.punchDB, kicks: d.kicks,
                          bassline: d.bassline && bundle.sub.tone.available)
        }
    }

    // MARK: - The mapping

    /// A stem fader's gain: off at or under the floor, not merely quiet.
    /// `stemmix.level_gain`.
    static func levelGain(_ db: Double, floor: Double = -30, maximum: Double = 12) -> Double {
        guard db.isFinite, db > floor else { return 0 }
        return pow(10, min(db, maximum) / 20)
    }

    /// The gain on a layer that lifts its band by `amountDB`, from the
    /// track's band energy, the layer's, and their cross term: the positive
    /// root of E + 2gC + g^2 S = E * 10^(a/10). `subbass.gain_from_stats`
    /// and `air.gain_from_stats`, line for line.
    static func quadraticGain(energy: Double, cross: Double, layerEnergy: Double,
                              amountDB: Double) -> Double {
        guard layerEnergy > 0 else { return 0 }
        let wanted = energy * (pow(10, amountDB / 10) - 1)
        let discriminant = cross * cross + layerEnergy * wanted
        guard discriminant >= 0 else { return 0 }
        return max(0, (-cross + discriminant.squareRoot()) / layerEnergy)
    }

    /// Punch's (band gain, attack gain): the attack emphasis, and the band
    /// brought back to the energy it had. `subbass.punch_gains`.
    static func punchGains(energy: Double, cross: Double, attackEnergy: Double,
                           boostDB: Double) -> (band: Double, attack: Double) {
        guard boostDB > 0, energy > 0 else { return (0, 0) }
        let k = pow(10, boostDB / 20) - 1
        let after = energy + 2 * k * cross + k * k * attackEnergy
        let trim = after > 0 ? (energy / after).squareRoot() : 1
        return (trim - 1, trim * k)
    }

    private static func clamp(_ value: Double, _ top: Double) -> Double {
        value.isFinite ? min(max(value, 0), top) : 0
    }

    /// Every layer's gain for a choice. `stemmix.layer_gains`.
    static func gains(_ bundle: Bundle, _ choice: Choice) -> [String: Double] {
        let limits = bundle.limits
        var out: [String: Double] = ["residual": 1]
        for stem in stems {
            out[stem] = levelGain(choice.levelsDB[stem] ?? 0, floor: limits.floorDB,
                                  maximum: limits.levelMaxDB)
        }
        for layer in subLayers + punchLayers + ["air"] { out[layer] = 0 }
        let sub = clamp(choice.subDB, limits.subMaxDB)
        if bundle.sub.available, sub > 0 {
            func lift(_ part: Bundle.Part) -> Double {
                part.available ? quadraticGain(energy: bundle.sub.energy, cross: part.cross,
                                               layerEnergy: part.energy, amountDB: sub) : 0
            }
            if choice.kicks == .mix {
                out["sub_mix_kick"] = lift(bundle.sub.mixKicks)
            } else {
                out["sub_kick"] = lift(bundle.sub.kicks)
                if choice.bassline { out["sub_tone"] = lift(bundle.sub.tone) }
            }
        }
        let boost = clamp(choice.punchDB, limits.punchMaxDB)
        let part = bundle.punchPart(choice.kicks)
        if part.available, boost > 0 {
            let g = punchGains(energy: bundle.punch.energy, cross: part.cross,
                               attackEnergy: part.attackEnergy, boostDB: boost)
            // On the drum stem, so it moves with the drum fader.
            let drums = out["drums"] ?? 0
            out["punch_band"] = drums * g.band
            out[choice.kicks == .mix ? "punch_mix_kicks" : "punch_drum_kicks"] = drums * g.attack
        }
        let air = clamp(choice.airDB, limits.airMaxDB)
        if bundle.air.available, air > 0 {
            out["air"] = quadraticGain(energy: bundle.air.before, cross: bundle.air.cross,
                                       layerEnergy: bundle.air.added, amountDB: air)
        }
        return out
    }

    /// A fader's reading.
    static func readout(_ db: Double, floor: Double = -30) -> String {
        db <= floor ? "off" : String(format: "%+.1f dB", db)
    }
}
