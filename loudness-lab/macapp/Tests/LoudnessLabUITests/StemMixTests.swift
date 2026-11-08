import XCTest
@testable import LoudnessLabUI

/// The stem mix's faders, Bass, the kicks, Punch and Air, mapped to gains as the Python maps
/// them. The app plays these gains and the Python writes with its own, so
/// the two have to agree to the last digit that matters -- every number
/// here comes from `loudnesslab/stemmix.py` (tests/test_stemmix.py holds
/// the same vectors from that side).
final class StemMixTests: XCTestCase {

    /// A mix.json as `stemmix.prepare` writes it (sums from a real one,
    /// with the path and key replaced and the kick and punch sums made up).
    static let bundleJSON = """
    {"version": 2, "key": "0000", "path": "/Music/Song.flac", "name": "Song",
     "rate": 48000, "frames": 480000, "seconds": 10.0,
     "files": {"residual": "residual.wav", "drums": "drums.wav", "bass": "bass.wav",
               "other": "other.wav", "vocals": "vocals.wav", "sub_tone": "sub_tone.wav",
               "sub_kick": "sub_kick.wav", "sub_mix_kick": "sub_mix_kick.wav",
               "punch_band": "punch_band.wav", "punch_drum_kicks": "punch_drum_kicks.wav",
               "punch_mix_kicks": "punch_mix_kicks.wav", "air": "air.wav"},
     "stems": ["drums", "bass", "other", "vocals"],
     "limits": {"floor_db": -30.0, "level_max_db": 12.0, "sub_max_db": 16.0, "air_max_db": 12.0,
                "punch_max_db": 10.0},
     "defaults": {"sub_db": 4.0, "air_db": 3.0, "punch_db": 2.0, "kicks": "drums", "bassline": true},
     "sub": {"available": true, "note": null, "energy": 0.003227959278614402,
             "tone": {"available": true, "note": null, "cross": 0.002442543837098113,
                      "energy": 0.07378995986175009},
             "kicks": {"available": true, "note": null, "cross": -0.0003, "energy": 0.001},
             "mix_kicks": {"available": true, "note": null, "cross": 0.0004, "energy": 0.0021},
             "kicks_per_minute": 120.0, "mix_kicks_per_minute": 131.0, "bass_share": 0.4,
             "bass_note": null, "freq": 42.5, "decay": 0.2, "mix_freq": 45.0, "mix_decay": 0.12},
     "punch": {"decay_ms": 8.0, "energy": 1.2e-4,
               "kicks": {"available": true, "cross": 2.1e-5, "attack_energy": 3.3e-5},
               "mix_kicks": {"available": true, "cross": 1.4e-5, "attack_energy": 1.9e-5}},
     "air": {"available": true, "note": null, "tune_hz": 3500.0, "guided": false,
             "before": 3.260331215111568e-05, "cross": -3.0777597172526597e-09,
             "added": 3.842330348346323e-10, "guided_cross": -3.0777597172526597e-09,
             "guided_added": 3.842330348346323e-10},
     "front": {"clip": null}}
    """

    static func bundle() throws -> StemMix.Bundle {
        try JSONDecoder().decode(StemMix.Bundle.self, from: Data(bundleJSON.utf8))
    }

    func testFaderLevels() {
        let cases: [(Double, Double)] = [(0, 1), (-6, 0.501187), (6, 1.995262),
                                         (-29.9, 0.031989), (-30, 0), (-80, 0),
                                         (12, 3.981072), (20, 3.981072)]
        for (db, gain) in cases {
            XCTAssertEqual(StemMix.levelGain(db), gain, accuracy: 5e-6, "\(db) dB")
        }
        XCTAssertEqual(StemMix.levelGain(.nan), 0)
        XCTAssertEqual(StemMix.levelGain(-.infinity), 0)
    }

    /// `subbass.gain_from_stats` / `air.gain_from_stats` on the same sums.
    func testTheQuadraticMatchesThePython() {
        let cases: [(Double, Double, Double, Double, Double)] = [
            (2.5e-3, 4.0e-4, 1.0e-3, 5.0, 1.959172344365911),
            (2.5e-3, -3.0e-4, 1.0e-3, 3.0, 1.905663659494789),
            (1.0e-5, 0.0, 4.0e-6, 12.0, 6.092809681216691),
            (2.5e-3, 4.0e-4, 1.0e-3, 0.0, 0.0),
            (2.5e-3, 4.0e-4, 0.0, 6.0, 0.0),
        ]
        for (energy, cross, layer, amount, expected) in cases {
            let gain = StemMix.quadraticGain(energy: energy, cross: cross,
                                             layerEnergy: layer, amountDB: amount)
            XCTAssertEqual(gain, expected, accuracy: 1e-12)
            if layer > 0 {
                // And it does what it is for: the band up by the amount.
                let ratio = (energy + 2 * gain * cross + gain * gain * layer) / energy
                XCTAssertEqual(ratio, pow(10, amount / 10), accuracy: 1e-9)
            }
        }
    }

    /// `stemmix.layer_gains` on this bundle, for three choices: one
    /// ordinary; one past every limit (a fader over the top, one at the
    /// floor, one just above it, the sub and punch past their caps, air
    /// below zero) and not following the bass line; one with the kicks
    /// from the full mix.
    func testLayerGainsMatchThePython() throws {
        let bundle = try Self.bundle()
        let cases: [(StemMix.Choice, [String: Double])] = [
            (StemMix.Choice(bundle: "/tmp/x",
                            levelsDB: ["drums": -4, "bass": 3, "other": 0, "vocals": -60],
                            subDB: 5, airDB: 2, punchDB: 4, kicks: .drums, bassline: true),
             ["residual": 1, "drums": 0.6309573444801932, "bass": 1.4125375446227544,
              "other": 1, "vocals": 0, "sub_tone": 0.27622869025007535,
              "sub_kick": 2.9588990646658924, "sub_mix_kick": 0,
              "punch_band": -0.07731345606422294, "punch_drum_kicks": 0.32382254138220146,
              "punch_mix_kicks": 0, "air": 230.93183689851492]),
            (StemMix.Choice(bundle: "/tmp/x",
                            levelsDB: ["drums": 20, "bass": -30, "other": -29.9, "vocals": -6],
                            subDB: 40, airDB: -3, punchDB: 30, kicks: .drums, bassline: false),
             ["residual": 1, "drums": 3.9810717055349722, "bass": 0,
              "other": 0.031988951096913985, "vocals": 0.5011872336272722,
              "sub_tone": 0, "sub_kick": 11.496848406069201, "sub_mix_kick": 0,
              "punch_band": -1.698725445853651, "punch_drum_kicks": 4.93506633007778,
              "punch_mix_kicks": 0, "air": 0]),
            (StemMix.Choice(bundle: "/tmp/x", levelsDB: ["drums": 3],
                            subDB: 6, airDB: 0, punchDB: 6, kicks: .mix, bassline: true),
             ["residual": 1, "drums": 1.4125375446227544, "bass": 1, "other": 1, "vocals": 1,
              "sub_tone": 0, "sub_kick": 0, "sub_mix_kick": 1.9586065095531067,
              "punch_band": -0.2140354570730263, "punch_drum_kicks": 0,
              "punch_mix_kicks": 1.1928239621497772, "air": 0]),
        ]
        for (choice, expected) in cases {
            let gains = StemMix.gains(bundle, choice)
            XCTAssertEqual(Set(gains.keys), Set(StemMix.layers))
            XCTAssertEqual(Set(expected.keys), Set(StemMix.layers))
            for (layer, value) in expected {
                XCTAssertEqual(gains[layer] ?? -1, value, accuracy: abs(value) * 1e-12 + 1e-15,
                               "\(layer)")
            }
        }
    }

    /// Punch renormalises the band: the emphasis adds no energy.
    func testPunchAddsNoEnergy() {
        let (b, c, d) = (1.2e-4, 2.1e-5, 3.3e-5)
        for boost in [1.0, 4.0, 10.0] {
            let g = StemMix.punchGains(energy: b, cross: c, attackEnergy: d, boostDB: boost)
            let trim = 1 + g.band, k = pow(10, boost / 20) - 1
            XCTAssertEqual(g.attack, trim * k, accuracy: 1e-12)
            XCTAssertEqual(trim * trim * (b + 2 * k * c + k * k * d), b, accuracy: 1e-16)
        }
        let off = StemMix.punchGains(energy: b, cross: c, attackEnergy: d, boostDB: 0)
        XCTAssertEqual(off.band, 0); XCTAssertEqual(off.attack, 0)
    }

    func testAtTheStartEverythingIsAsTheSettingsHadIt() throws {
        let bundle = try Self.bundle()
        let start = StemMix.Choice.start(bundle, folder: URL(fileURLWithPath: "/tmp/b"))
        XCTAssertEqual(start.levelsDB, ["drums": 0, "bass": 0, "other": 0, "vocals": 0])
        XCTAssertEqual(start.subDB, 4)
        XCTAssertEqual(start.airDB, 3)
        XCTAssertEqual(start.punchDB, 2)
        XCTAssertEqual(start.kicks, .drums)
        XCTAssertTrue(start.bassline)
        let gains = StemMix.gains(bundle, start)
        for layer in ["residual"] + StemMix.stems { XCTAssertEqual(gains[layer], 1) }
    }

    func testANothingLayerStaysSilent() throws {
        var bundle = try Self.bundle()
        bundle.sub.available = false
        bundle.air.available = false
        bundle.punch.kicks.available = false
        let choice = StemMix.Choice(bundle: "/tmp/x", levelsDB: [:], subDB: 6, airDB: 6,
                                    punchDB: 6)
        let gains = StemMix.gains(bundle, choice)
        for layer in StemMix.subLayers + StemMix.punchLayers + ["air"] {
            XCTAssertEqual(gains[layer], 0, layer)
        }
        XCTAssertEqual(StemMix.Choice.start(bundle, folder: URL(fileURLWithPath: "/b")).subDB, 0)
        // No bass line found: the sheet starts with it off.
        bundle = try Self.bundle()
        bundle.sub.tone.available = false
        XCTAssertFalse(StemMix.Choice.start(bundle, folder: URL(fileURLWithPath: "/b")).bassline)
    }

    /// The choice file the command reads (`--stem-mix`), in its keys.
    func testTheChoiceFileIsWhatThePythonReads() throws {
        let choice = StemMix.Choice(bundle: "/tmp/b", levelsDB: ["drums": -2], subDB: 3, airDB: 1,
                                    punchDB: 2.5, kicks: .mix, bassline: false)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(choice)) as? [String: Any]
        XCTAssertEqual(object?["bundle"] as? String, "/tmp/b")
        XCTAssertEqual(object?["levels_db"] as? [String: Double], ["drums": -2])
        XCTAssertEqual(object?["sub_db"] as? Double, 3)
        XCTAssertEqual(object?["air_db"] as? Double, 1)
        XCTAssertEqual(object?["punch_db"] as? Double, 2.5)
        XCTAssertEqual(object?["kicks"] as? String, "mix")
        XCTAssertEqual(object?["bassline"] as? Bool, false)
    }

    func testReadouts() {
        XCTAssertEqual(StemMix.readout(-30), "off")
        XCTAssertEqual(StemMix.readout(-3.04), "-3.0 dB")
        XCTAssertEqual(StemMix.readout(0), "+0.0 dB")
    }
}
