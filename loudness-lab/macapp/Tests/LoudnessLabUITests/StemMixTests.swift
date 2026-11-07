import XCTest
@testable import LoudnessLabUI

/// The stem mix's faders, Bass and Air, mapped to gains as the Python maps
/// them. The app plays these gains and the Python writes with its own, so
/// the two have to agree to the last digit that matters -- every number
/// here comes from `loudnesslab/stemmix.py` (tests/test_stemmix.py holds
/// the same vectors from that side).
final class StemMixTests: XCTestCase {

    /// A mix.json as `stemmix.prepare` writes it (a real one, with the path
    /// and key replaced, and kick stats added so both sub layers are used).
    static let bundleJSON = """
    {"version": 1, "key": "0000", "path": "/Music/Song.flac", "name": "Song",
     "rate": 48000, "frames": 480000, "seconds": 10.0,
     "files": {"residual": "residual.wav", "drums": "drums.wav", "bass": "bass.wav",
               "other": "other.wav", "vocals": "vocals.wav", "sub_tone": "sub_tone.wav",
               "sub_kick": "sub_kick.wav", "air": "air.wav"},
     "stems": ["drums", "bass", "other", "vocals"],
     "limits": {"floor_db": -30.0, "level_max_db": 12.0, "sub_max_db": 16.0, "air_max_db": 12.0},
     "defaults": {"sub_db": 4.0, "air_db": 3.0},
     "sub": {"available": true, "note": null, "kick": true,
             "energy": 0.003227959278614402, "tone_cross": 0.002442543837098113,
             "tone_energy": 0.07378995986175009, "kick_cross": -0.0003, "kick_energy": 0.001,
             "kicks_per_minute": 120.0, "bass_share": 0.0, "polarity_flipped": true,
             "freq": 42.5, "decay": 0.2},
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

    /// `stemmix.layer_gains` on this bundle, for two choices: one ordinary,
    /// one past every limit (a fader over the top, one at the floor, one
    /// just above it, the sub past its cap, air below zero).
    func testLayerGainsMatchThePython() throws {
        let bundle = try Self.bundle()
        let cases: [([String: Double], Double, Double, [String: Double])] = [
            (["drums": -4, "bass": 3, "other": 0, "vocals": -60], 5, 2,
             ["residual": 1, "drums": 0.6309573444801932, "bass": 1.4125375446227544,
              "other": 1, "vocals": 0, "sub_tone": 0.27622869025007535,
              "sub_kick": 2.9588990646658924, "air": 230.93183689851492]),
            (["drums": 20, "bass": -30, "other": -29.9, "vocals": -6], 40, -3,
             ["residual": 1, "drums": 3.9810717055349722, "bass": 0,
              "other": 0.031988951096913985, "vocals": 0.5011872336272722,
              "sub_tone": 1.270309495410147, "sub_kick": 11.496848406069201, "air": 0]),
        ]
        for (levels, sub, air, expected) in cases {
            let choice = StemMix.Choice(bundle: "/tmp/x", levelsDB: levels, subDB: sub, airDB: air)
            let gains = StemMix.gains(bundle, choice)
            XCTAssertEqual(Set(gains.keys), Set(StemMix.layers))
            for (layer, value) in expected {
                XCTAssertEqual(gains[layer] ?? -1, value, accuracy: abs(value) * 1e-12 + 1e-15,
                               "\(layer)")
            }
        }
    }

    func testAtTheStartEverythingIsAsTheSettingsHadIt() throws {
        let bundle = try Self.bundle()
        let start = StemMix.Choice.start(bundle, folder: URL(fileURLWithPath: "/tmp/b"))
        XCTAssertEqual(start.levelsDB, ["drums": 0, "bass": 0, "other": 0, "vocals": 0])
        XCTAssertEqual(start.subDB, 4)
        XCTAssertEqual(start.airDB, 3)
        let gains = StemMix.gains(bundle, start)
        for layer in ["residual"] + StemMix.stems { XCTAssertEqual(gains[layer], 1) }
    }

    func testANothingLayerStaysSilent() throws {
        var bundle = try Self.bundle()
        bundle.sub.available = false
        bundle.air.available = false
        let choice = StemMix.Choice(bundle: "/tmp/x", levelsDB: [:], subDB: 6, airDB: 6)
        let gains = StemMix.gains(bundle, choice)
        XCTAssertEqual([gains["sub_tone"], gains["sub_kick"], gains["air"]], [0, 0, 0])
        XCTAssertEqual(StemMix.Choice.start(bundle, folder: URL(fileURLWithPath: "/b")).subDB, 0)
    }

    /// The choice file the command reads (`--stem-mix`), in its keys.
    func testTheChoiceFileIsWhatThePythonReads() throws {
        let choice = StemMix.Choice(bundle: "/tmp/b", levelsDB: ["drums": -2], subDB: 3, airDB: 1)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(choice)) as? [String: Any]
        XCTAssertEqual(object?["bundle"] as? String, "/tmp/b")
        XCTAssertEqual(object?["levels_db"] as? [String: Double], ["drums": -2])
        XCTAssertEqual(object?["sub_db"] as? Double, 3)
        XCTAssertEqual(object?["air_db"] as? Double, 1)
    }

    func testReadouts() {
        XCTAssertEqual(StemMix.readout(-30), "off")
        XCTAssertEqual(StemMix.readout(-3.04), "-3.0 dB")
        XCTAssertEqual(StemMix.readout(0), "+0.0 dB")
    }
}
