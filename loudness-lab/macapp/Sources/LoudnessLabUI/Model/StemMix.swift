import Foundation

/// The stem mix's numbers: what the prepared layers are, what was chosen,
/// and the gain each layer plays at.
///
/// The Python prepares the layers (`loudnesslab/stemmix.py`) and writes
/// the stems, the sub and the air into a folder with a `mix.json`. This
/// plays them; Commit hands the choice back and the same Python builds the
/// track from the same layers at the same gains. So the mapping from a
/// fader to a gain is written twice -- here, to play it, and in
/// `stemmix.layer_gains`, to write it -- and `StemMixTests` holds this one
/// to the Python's numbers (tests/test_stemmix.py has the same vectors).
enum StemMix {

    static let stems = ["drums", "bass", "other", "vocals"]
    /// Summed in this order, here and in the Python.
    static let layers = ["residual"] + stems + ["sub_tone", "sub_kick", "air"]

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

    /// The bundle's mix.json.
    struct Bundle: Decodable, Equatable {
        struct Limits: Decodable, Equatable {
            var floorDB: Double, levelMaxDB: Double, subMaxDB: Double, airMaxDB: Double
            enum CodingKeys: String, CodingKey {
                case floorDB = "floor_db", levelMaxDB = "level_max_db"
                case subMaxDB = "sub_max_db", airMaxDB = "air_max_db"
            }
        }
        struct Defaults: Decodable, Equatable {
            var subDB: Double, airDB: Double
            enum CodingKeys: String, CodingKey { case subDB = "sub_db", airDB = "air_db" }
        }
        /// The sub's sums: `energy` is the track's 31.5-63 Hz octave, the
        /// others each layer's own and its cross term with the track.
        struct Sub: Decodable, Equatable {
            var available: Bool
            var note: String?
            var kick: Bool
            var energy: Double, toneCross: Double, toneEnergy: Double
            var kickCross: Double, kickEnergy: Double
            enum CodingKeys: String, CodingKey {
                case available, note, kick, energy
                case toneCross = "tone_cross", toneEnergy = "tone_energy"
                case kickCross = "kick_cross", kickEnergy = "kick_energy"
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
        var air: Air

        static func read(_ folder: URL) throws -> Bundle {
            let data = try Data(contentsOf: folder.appendingPathComponent("mix.json"))
            return try JSONDecoder().decode(Bundle.self, from: data)
        }
    }

    /// What the faders say. Written as the choice file Commit hands to the
    /// command (`--stem-mix`).
    struct Choice: Codable, Equatable {
        var bundle: String
        var levelsDB: [String: Double]
        var subDB: Double
        var airDB: Double

        enum CodingKeys: String, CodingKey {
            case bundle, levelsDB = "levels_db", subDB = "sub_db", airDB = "air_db"
        }

        /// Every stem at 0 dB, the sub and air at what the settings would
        /// have given this track.
        static func start(_ bundle: Bundle, folder: URL) -> Choice {
            Choice(bundle: folder.path,
                   levelsDB: Dictionary(uniqueKeysWithValues: stems.map { ($0, 0) }),
                   subDB: bundle.sub.available ? bundle.defaults.subDB : 0,
                   airDB: bundle.air.available ? bundle.defaults.airDB : 0)
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

    /// Every layer's gain for a choice. `stemmix.layer_gains`.
    static func gains(_ bundle: Bundle, _ choice: Choice) -> [String: Double] {
        let limits = bundle.limits
        var out: [String: Double] = ["residual": 1]
        for stem in stems {
            out[stem] = levelGain(choice.levelsDB[stem] ?? 0, floor: limits.floorDB,
                                  maximum: limits.levelMaxDB)
        }
        let sub = min(max(choice.subDB, 0), limits.subMaxDB)
        out["sub_tone"] = 0; out["sub_kick"] = 0
        if bundle.sub.available, sub > 0 {
            out["sub_tone"] = quadraticGain(energy: bundle.sub.energy, cross: bundle.sub.toneCross,
                                            layerEnergy: bundle.sub.toneEnergy, amountDB: sub)
            if bundle.sub.kick {
                out["sub_kick"] = quadraticGain(energy: bundle.sub.energy, cross: bundle.sub.kickCross,
                                                layerEnergy: bundle.sub.kickEnergy, amountDB: sub)
            }
        }
        let air = min(max(choice.airDB, 0), limits.airMaxDB)
        out["air"] = 0
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
