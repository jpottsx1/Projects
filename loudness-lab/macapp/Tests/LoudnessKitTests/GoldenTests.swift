import XCTest
@testable import LoudnessKit

/// The Swift held to the Python's numbers.
///
/// This project's worth is that its measurements are validated -- BS.1770
/// against ffmpeg's ebur128 to within 0.05 LU, the de-clipper against
/// known-clean audio, the constants against measured corpora. A rewrite in
/// another language throws that away unless the rewrite is held to the same
/// values, so `tools/make_golden.py` writes them down and this reads them
/// back. Where the two disagree, the Python is right.
///
/// The order is deliberate: fixtures, then filters, then everything built on
/// them. A fixture that does not match makes every later failure meaningless,
/// so it is worth knowing first.
final class GoldenTests: XCTestCase {

    // MARK: - Loading

    struct Golden: Decodable {
        let rate: Int
        let fixtures: [String: FixtureCase]
        let filters: [String: FilterCase]
        let kWeighting: [String: SignalCase]
        let measure: [String: MeasureCase]
        let declip: [String: DeclipCase]
        let countClipping: [String: [Int]]
        let grooves: [String: FixtureCase]
        let spectrum: [String: SpectrumCase]
        let findPeaks: [PeaksCase]
        let subbass: [String: SubBassCase]
        let mp3: [String: MP3Case]
        let decode: [String: DecodeCase]
        let yearFromText: [String: Int?]
        let yearFromTags: [YearTagCase]
        let library: LibraryCase
        let folderLabels: [FolderLabelCase]
    }

    struct FolderLabelCase: Decodable {
        let paths: [String]
        let labels: [String: String]
    }

    struct LibraryCase: Decodable {
        let schemaVersion, lowBands: Int
        let tracks: [LibraryTrack]
        let lowShapeBands: [Double]
        let referenceFolder: String
        let curve: [String: Double]
        let shortfalls: [ShortfallCase]
    }
    struct ShortfallCase: Decodable { let path: String; let meanDeficitDB: Double? }
    struct LibraryTrack: Decodable {
        let path, artist, title: String
        let year: Int
        let lufs_i, s_p95: Double
    }

    struct DecodeCase: Decodable {
        let frames: Int
        let seconds, lufs_i, s_p95, true_peak_dbtp, sample_peak_dbfs: Double
    }
    /// `isOriginal` is 1, 0 or absent, NOT a boolean, because that is what
    /// the Python writes -- it keeps the flag as an INTEGER so it can live
    /// in the SQLite column the era reports aggregate with SUM(CASE WHEN
    /// year_is_original = 0 ...). Swift models the same three states as
    /// `Bool?`, which is the better type on this side and binds to exactly
    /// the same 1/0/NULL. These structs describe the FILE, so this one
    /// follows the file and the test bridges at the comparison, where the
    /// difference is visible.
    struct YearTagCase: Decodable {
        let tags: [String: String]; let year: Int?; let isOriginal: Int?
    }

    struct MP3Case: Decodable {
        let frames, infoFrames, crcFrames, id3Bytes, movable: Int
        let firstGainBits, firstGains: [Int]
        let lowestGain, highestGain: Int
        let sourceFNV: String
        let plans: [String: PlanCase]
        let applied: [String: AppliedCase]
    }
    struct PlanCase: Decodable {
        let steps, granules, skippedGranules, protectedFrames: Int
        let crossingGranules, lowestGain, lowestCount: Int
        let appliedDB, headroomDownDB: Double
        let clamped: Bool
    }
    struct AppliedCase: Decodable {
        let fnv: String; let crossed, changedBytes: Int; let sameLength: Bool
    }

    struct SpectrumCase: Decodable { let bands: Int; let rows: [BandRow] }
    struct BandRow: Decodable {
        let band_hz: Double
        let ltas_db, shape_db, p10_db, p90_db, side_mid_db: Double?
    }
    struct PeaksCase: Decodable { let seed: UInt64, distance: Int, peaks: [Int] }
    struct SubBassCase: Decodable {
        let kicks: [Int], strengths: [Double]
        let lowBandActivityDB, attackContrastDB, appliedDB, punchDB: Double
        let sustainTrimDB, bandLevelChangeDB, safetyTrimDB: Double
        let polarityFlipped: Bool
        let outputRMS, outputPeak: Double
    }

    struct FixtureCase: Decodable {
        let frames: Int, head: [Double], tail: [Double], rms: Double, peak: Double
    }
    struct SignalCase: Decodable { let head: [Double], rms: Double }
    struct FilterCase: Decodable {
        let order: Int, btype: String, cutoff: [Double], sos: [[Double]]
        let sosfilt: SignalCase, sosfiltfilt: SignalCase
    }
    struct MeasureCase: Decodable {
        let lufs_i: Value, lra: Value?, s_max: Value?, s_p95: Value?, s_p90: Value?
        let s_p50: Value?, s_p10: Value?, true_peak_dbtp: Value
        let sample_peak_dbfs: Value, clipped_samples: Value, clip_runs: Value
        let crest_db: Value?, shortTermCount: Int, shortTermHead: [Double]
    }
    struct DeclipCase: Decodable {
        let runs, restored, flattened, too_long, at_edge: Int
        let shoulder_clipped, nothing_to_add: Int
        let liftDB, liftMaxDB, peakChangeDB, outputRMS, outputPeak: Double
        let firstRuns: [[Int]]
    }

    /// The generator writes non-finite values as strings, so that a missing
    /// -inf cannot silently decode as zero.
    struct Value: Decodable {
        let double: Double
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) { double = number }
            else {
                let text = try container.decode(String.self)
                double = text == "-inf" ? -.infinity : .infinity
            }
        }
    }

    /// Loaded once, and it MUST say which of the two failures happened.
    /// A `try?` around the decode here once turned "the generator and this
    /// file disagree about one key in one section" into "the file is
    /// missing" -- which sent the search to the build system and the
    /// resource rules, while the actual mismatch sat in plain sight. The
    /// decoding error names the key and the path to it; throwing that away
    /// to get a tidier `guard` costs more than it saves.
    static let golden: Golden = {
        guard let url = Bundle.module.url(forResource: "Golden/golden", withExtension: "json") else {
            fatalError("Golden/golden.json is not in the test bundle. "
                       + "Run: python3 tools/make_golden.py")
        }
        do {
            return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
        } catch {
            fatalError("Golden/golden.json did not decode: \(error)\n"
                       + "The vectors and the structs in this file have drifted. "
                       + "Re-run: python3 tools/make_golden.py")
        }
    }()

    var golden: Golden { Self.golden }

    // MARK: - Fixtures first

    func testTheFixturesAreTheSameSignalInBothLanguages() throws {
        for kind in Fixtures.Kind.allCases {
            let expected = try XCTUnwrap(golden.fixtures[kind.rawValue], kind.rawValue)
            let x = Fixtures.make(kind)
            XCTAssertEqual(x[0].count, expected.frames, kind.rawValue)
            for (index, value) in expected.head.enumerated() {
                XCTAssertEqual(x[0][index], value, accuracy: 1e-9,
                               "\(kind.rawValue) sample \(index)")
            }
            for (offset, value) in expected.tail.enumerated() {
                XCTAssertEqual(x[1][x[1].count - expected.tail.count + offset], value,
                               accuracy: 1e-9, "\(kind.rawValue) tail \(offset)")
            }
            XCTAssertEqual(rms(x), expected.rms, accuracy: 1e-9, kind.rawValue)
            XCTAssertEqual(peak(x), expected.peak, accuracy: 1e-9, kind.rawValue)
        }
    }

    func testTheRandomStreamMatchesPython() {
        // Spelled out rather than derived, so a change to the generator that
        // happens to keep the statistics cannot pass unnoticed.
        let values = Fixtures.xorshift(seed: 0x2BAD, count: 5)
        let expected = [-0.466650023228031, -0.465457306744228, 0.721777633163229,
                        -0.638761121851832, -0.152316400600119]
        for (index, value) in expected.enumerated() {
            XCTAssertEqual(values[index], value, accuracy: 1e-12, "draw \(index)")
        }
    }

    // MARK: - Filters

    /// The filter tests iterate `bank()`, so a filter missing from that table
    /// would go untested in silence rather than fail. This is what makes
    /// adding one to the generator and forgetting the test a loud mistake --
    /// which it has already been once, when the kick detector's envelopes
    /// turned out to be 60 and 3 Hz rather than the single 200 Hz guessed at.
    func testEveryFilterInTheVectorsIsActuallyTested() {
        XCTAssertEqual(Set(bank().keys), Set(golden.filters.keys),
                       "the filter bank and the golden vectors have drifted apart")
    }

    func testTheFilterBankCarriesTheCoefficientsScipyDesigned() throws {
        for (name, filter) in bank() {
            let expected = try XCTUnwrap(golden.filters[name], name)
            XCTAssertEqual(filter.sections.count, expected.sos.count, name)
            for (index, row) in expected.sos.enumerated() {
                let section = filter.sections[index]
                let a0 = row[3]
                XCTAssertEqual(section.b0, row[0] / a0, accuracy: 1e-12, "\(name).\(index).b0")
                XCTAssertEqual(section.b1, row[1] / a0, accuracy: 1e-12, "\(name).\(index).b1")
                XCTAssertEqual(section.b2, row[2] / a0, accuracy: 1e-12, "\(name).\(index).b2")
                XCTAssertEqual(section.a1, row[4] / a0, accuracy: 1e-12, "\(name).\(index).a1")
                XCTAssertEqual(section.a2, row[5] / a0, accuracy: 1e-12, "\(name).\(index).a2")
            }
        }
    }

    func testCausalFilteringMatches() throws {
        let signal = Fixtures.make(.programme)[0]
        for (name, filter) in bank() {
            let expected = try XCTUnwrap(golden.filters[name]?.sosfilt, name)
            let out = filter.filter(signal)
            for (index, value) in expected.head.enumerated() {
                XCTAssertEqual(out[index], value, accuracy: 1e-10, "\(name) sample \(index)")
            }
            XCTAssertEqual(rms([out]), expected.rms, accuracy: 1e-10, name)
        }
    }

    func testZeroPhaseFilteringMatches() throws {
        // The one this project has actually been bitten by: a causal filter
        // where a zero-phase one was meant leaves a phase-shifted residue, so
        // `x - band` does not cancel and a transient shaper silently becomes
        // an equaliser. The padding and the steady-state start both have to
        // be right, and neither shows up in a spectrum plot.
        let signal = Fixtures.make(.programme)[0]
        for (name, filter) in bank() {
            let expected = try XCTUnwrap(golden.filters[name]?.sosfiltfilt, name)
            let out = filter.filtfilt(signal)
            XCTAssertEqual(out.count, signal.count, "\(name) changed the length")
            for (index, value) in expected.head.enumerated() {
                XCTAssertEqual(out[index], value, accuracy: 1e-9, "\(name) sample \(index)")
            }
            XCTAssertEqual(rms([out]), expected.rms, accuracy: 1e-10, name)
        }
    }

    // MARK: - Loudness

    func testKWeightingMatches() throws {
        for kind in [Fixtures.Kind.tones, .programme] {
            let expected = try XCTUnwrap(golden.kWeighting[kind.rawValue], kind.rawValue)
            let y = BS1770.kWeight(Fixtures.make(kind))
            for (index, value) in expected.head.enumerated() {
                XCTAssertEqual(y[0][index], value, accuracy: 1e-10,
                               "\(kind.rawValue) sample \(index)")
            }
            XCTAssertEqual(rms(y), expected.rms, accuracy: 1e-10, kind.rawValue)
        }
    }

    func testEveryMeasurementMatches() throws {
        for kind in Fixtures.Kind.allCases {
            let expected = try XCTUnwrap(golden.measure[kind.rawValue], kind.rawValue)
            let got = BS1770.measure(Fixtures.make(kind))
            let name = kind.rawValue

            same(got.lufsI, expected.lufs_i, 1e-7, "\(name).lufs_i")
            same(got.lra, expected.lra, 1e-7, "\(name).lra")
            same(got.sMax, expected.s_max, 1e-7, "\(name).s_max")
            same(got.sP95, expected.s_p95, 1e-7, "\(name).s_p95")
            same(got.sP90, expected.s_p90, 1e-7, "\(name).s_p90")
            same(got.sP50, expected.s_p50, 1e-7, "\(name).s_p50")
            same(got.sP10, expected.s_p10, 1e-7, "\(name).s_p10")
            same(got.samplePeakDBFS, expected.sample_peak_dbfs, 1e-9,
                 "\(name).sample_peak_dbfs")
            same(got.crestDB, expected.crest_db, 1e-4, "\(name).crest_db")

            // The resampler is reproduced rather than shared, so this gets a
            // tolerance the rest do not: the filter is identical but the edge
            // handling need only be equivalent, not identical.
            same(got.truePeakDBTP, expected.true_peak_dbtp, 0.02,
                 "\(name).true_peak_dbtp")

            XCTAssertEqual(got.clippedSamples, Int(expected.clipped_samples.double),
                           "\(name).clipped_samples")
            XCTAssertEqual(got.clipRuns, Int(expected.clip_runs.double), "\(name).clip_runs")
            XCTAssertEqual(got.shortTerm.count, expected.shortTermCount,
                           "\(name).shortTermCount")
            for (index, value) in expected.shortTermHead.enumerated() {
                XCTAssertEqual(got.shortTerm[index], value, accuracy: 1e-7,
                               "\(name).shortTerm[\(index)]")
            }
        }
    }

    func testClippingCountsMatch() throws {
        for (name, expected) in golden.countClipping {
            let over = Double(name.dropFirst("programme+".count).dropLast("dB".count)) ?? 0
            let got = BS1770.countClipping(Fixtures.clipped(.programme, overDB: over))
            XCTAssertEqual(got.samples, expected[0], "\(name) samples")
            XCTAssertEqual(got.runs, expected[1], "\(name) runs")
        }
    }

    // MARK: - De-clipping

    func testDeclippingMatches() throws {
        for (name, expected) in golden.declip {
            let over = Double(name.dropFirst("programme+".count).dropLast("dB".count)) ?? 0
            let x = Fixtures.clipped(.programme, overDB: over)
            let (out, report) = Declip.restore(x, rate: Fixtures.rate)

            XCTAssertEqual(report.runs, expected.runs, "\(name).runs")
            XCTAssertEqual(report.restored, expected.restored, "\(name).restored")
            XCTAssertEqual(report.flattened, expected.flattened, "\(name).flattened")
            XCTAssertEqual(report.tooLong, expected.too_long, "\(name).too_long")
            XCTAssertEqual(report.atEdge, expected.at_edge, "\(name).at_edge")
            XCTAssertEqual(report.shoulderClipped, expected.shoulder_clipped,
                           "\(name).shoulder_clipped")
            XCTAssertEqual(report.nothingToAdd, expected.nothing_to_add,
                           "\(name).nothing_to_add")
            XCTAssertEqual(report.liftDB, expected.liftDB, accuracy: 1e-7, "\(name).liftDB")
            XCTAssertEqual(report.liftMaxDB, expected.liftMaxDB, accuracy: 1e-7,
                           "\(name).liftMaxDB")
            XCTAssertEqual(report.peakChangeDB, expected.peakChangeDB, accuracy: 1e-7,
                           "\(name).peakChangeDB")
            XCTAssertEqual(rms(out), expected.outputRMS, accuracy: 1e-10, "\(name).rms")
            XCTAssertEqual(peak(out), expected.outputPeak, accuracy: 1e-10, "\(name).peak")

            let runs = Declip.findRuns(x[0])
            for (index, triple) in expected.firstRuns.enumerated() {
                XCTAssertEqual(runs[index],
                               Declip.Run(start: triple[0], end: triple[1], sign: triple[2]),
                               "\(name).run[\(index)]")
            }
        }
    }

    /// Restated here rather than left to the Python: it is the property that
    /// makes de-clipping safe to run across a library, and a port that lost it
    /// would still pass every numeric comparison above on clipped fixtures.
    func testACleanFullScalePeakIsStillLeftAlone() {
        for freq in [50.0, 100.0, 200.0] {
            let n = Int(2 * Fixtures.rate)
            let wave = (0..<n).map { sin(2 * .pi * freq * Double($0) / Fixtures.rate) }
            let (out, report) = Declip.restore([wave, wave], rate: Fixtures.rate)
            XCTAssertGreaterThan(report.runs, 0, "\(freq) Hz no longer trips the detector")
            let moved = zip(out[0], wave).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThan(moved, 1e-6, "\(freq) Hz moved by \(moved)")
            XCTAssertLessThan(abs(report.peakChangeDB), 0.01, "\(freq) Hz peak moved")
        }
    }

    // MARK: - Spectrum

    func testTheGrooveFixtureIsTheSameSignalInBothLanguages() throws {
        for (bpm, expected) in golden.grooves {
            let x = Fixtures.groove(bpm: Double(bpm) ?? 0)
            XCTAssertEqual(x[0].count, expected.frames, bpm)
            for (index, value) in expected.head.enumerated() {
                XCTAssertEqual(x[0][index], value, accuracy: 1e-9, "\(bpm) sample \(index)")
            }
            for (offset, value) in expected.tail.enumerated() {
                XCTAssertEqual(x[1][x[1].count - expected.tail.count + offset], value,
                               accuracy: 1e-9, "\(bpm) tail \(offset)")
            }
            XCTAssertEqual(rms(x), expected.rms, accuracy: 1e-9, bpm)
            XCTAssertEqual(peak(x), expected.peak, accuracy: 1e-9, bpm)
        }
    }

    /// Below this, a band holds arithmetic and nothing else.
    ///
    /// A 16-bit master's noise floor is about -96 dBFS and a 24-bit file's
    /// last bit is about -144. At -120 there is no record, no converter and
    /// no room that has anything to say.
    static let spectrumFloorDB = -120.0

    func testTheThirdOctaveSpectrumMatches() throws {
        // Loose on purpose. numpy's rfft on a float32 frame returns
        // complex64, so the Python does this FFT in SINGLE precision while
        // this does it in double; band levels differ by around a millionth
        // of a decibel, and the Python rounds to three places anyway.
        //
        // That holds only while there is signal in the band. The `tones`
        // fixture puts tones in seven bands and leaves the other
        // twenty-four holding filter residue at -150 to -240 dB, and down
        // there the two languages are not disagreeing about the spectrum --
        // float32 runs out of mantissa around -140 and flattens into its
        // own rounding noise, while double keeps resolving to -247. Held to
        // 0.002 dB that produced eighty-eight failures, every one of them
        // an argument about a number neither side means.
        //
        // So the claim is stated the way it is actually true: where a band
        // carries anything, the levels match; where it does not, both sides
        // have to agree there is nothing there. The second half is not a
        // free pass -- energy in the wrong band shows up as a floor band
        // that is no longer empty, and the band it left as a signal band
        // that moved.
        for (kind, expected) in golden.spectrum {
            let rows = Spectrum.analyse(Fixtures.make(Fixtures.Kind(rawValue: kind)!,
                                                      seconds: 4.0),
                                        rate: Fixtures.rate)
            XCTAssertEqual(rows.count, expected.bands, kind)
            var compared = 0
            for (index, row) in expected.rows.enumerated() {
                let got = rows[index]
                XCTAssertEqual(got.bandHz, row.band_hz, "\(kind) band \(index)")
                // One decision per band, taken on its absolute level: if the
                // band is empty then its shape and percentiles are empty too.
                guard (row.ltas_db ?? -.infinity) >= Self.spectrumFloorDB else {
                    XCTAssertLessThan(got.ltasDB ?? -.infinity, Self.spectrumFloorDB,
                                      "\(kind) \(row.band_hz): Python has nothing "
                                      + "here and this does")
                    continue
                }
                compared += 1
                close(got.ltasDB, row.ltas_db, 0.002, "\(kind) \(row.band_hz) ltas")
                close(got.shapeDB, row.shape_db, 0.002, "\(kind) \(row.band_hz) shape")
                close(got.p10DB, row.p10_db, 0.002, "\(kind) \(row.band_hz) p10")
                close(got.p90DB, row.p90_db, 0.002, "\(kind) \(row.band_hz) p90")
                close(got.sideMidDB, row.side_mid_db, 0.01, "\(kind) \(row.band_hz) width")
            }
            // Otherwise a fixture that went quiet, or a floor set too high,
            // would leave this test asserting nothing and still passing.
            XCTAssertGreaterThanOrEqual(compared, 8,
                                        "\(kind): only \(compared) band(s) had enough "
                                        + "level to compare -- this test has stopped "
                                        + "testing the spectrum")
        }
    }

    /// Restated rather than left to the numbers: a band with nothing in it
    /// holds filter residue, which is uncorrelated and therefore reads as
    /// WIDE. Reporting that would invert the vinyl-mono signal exactly where
    /// it matters most, so the width has to be withheld instead.
    func testWidthIsWithheldWhereABandIsEmpty() {
        let rows = Spectrum.analyse(Fixtures.make(.tones, seconds: 4.0),
                                    rate: Fixtures.rate)
        let empty = rows.filter { ($0.shapeDB ?? 0) < Spectrum.minShapeForWidthDB }
        XCTAssertFalse(empty.isEmpty, "the fixture no longer has an empty band")
        for row in empty {
            XCTAssertNil(row.sideMidDB, "\(row.bandHz) Hz reported a width")
        }
    }

    // MARK: - Peak picking

    func testPeakPickingMatches() {
        for expected in golden.findPeaks {
            let signal = Fixtures.xorshift(seed: expected.seed, count: 400)
                .map { abs($0) * 1.6 }
            let got = Peaks.find(signal, height: 0.8, distance: expected.distance)
            XCTAssertEqual(got, expected.peaks,
                           "seed \(expected.seed) distance \(expected.distance)")
        }
    }

    // MARK: - Sub-bass

    func testKickDetectionAndTheSubStageMatch() throws {
        for (name, expected) in golden.subbass {
            let bpm = Double(name.dropFirst("groove".count)) ?? 0
            let x = Fixtures.groove(bpm: bpm)

            let (kicks, strengths) = SubBass.detectKicks(x, rate: Fixtures.rate)
            // Asserted position by position. "About the right number of
            // onsets" is not the property that matters -- a burst laid a few
            // milliseconds late against a 45 Hz cycle of 22 ms flams and
            // partly cancels the kick it was meant to reinforce.
            XCTAssertEqual(kicks, expected.kicks, "\(name) kick positions")
            XCTAssertEqual(strengths.count, expected.strengths.count, "\(name) strengths")
            for (index, value) in expected.strengths.enumerated() where index < strengths.count {
                XCTAssertEqual(strengths[index], value, accuracy: 1e-7,
                               "\(name) strength \(index)")
            }

            XCTAssertEqual(SubBass.lowBandActivity(x, rate: Fixtures.rate),
                           expected.lowBandActivityDB, accuracy: 1e-6,
                           "\(name) low band activity")
            // Loose for a reason, and the reason is on the PYTHON's side:
            // `subbass.enhance` returns `.astype(np.float32)`, because
            // float32 is what the pipeline decodes to and writes back out.
            // So the recorded numbers carry float32's seven digits, while
            // this runs in double. The giveaway was `outputPeak`: Python
            // says 0.990000009537, which is float32(0.99) exactly, against
            // this side's flat 0.99.
            //
            // Attack contrast gets the loosest of these because it is dB of
            // a ratio whose denominator is near silence between kicks -- a
            // 200 dB number amplifies the last float32 digit into the third
            // decimal. Even so 0.01 dB is a thousand times finer than any
            // difference this stage is trying to make.
            XCTAssertEqual(SubBass.attackContrast(x, rate: Fixtures.rate, kicks: kicks),
                           expected.attackContrastDB, accuracy: 0.01,
                           "\(name) attack contrast")

            let (out, report) = SubBass.enhance(x, rate: Fixtures.rate,
                                                amountDB: 5.0, punchDB: 3.0)
            XCTAssertEqual(report.appliedDB, expected.appliedDB, accuracy: 1e-6,
                           "\(name) applied")
            XCTAssertEqual(report.punchDB, expected.punchDB, accuracy: 1e-9, "\(name) punch")
            XCTAssertEqual(report.sustainTrimDB, expected.sustainTrimDB, accuracy: 1e-6,
                           "\(name) sustain trim")
            XCTAssertEqual(report.bandLevelChangeDB, expected.bandLevelChangeDB,
                           accuracy: 1e-6, "\(name) band level change")
            XCTAssertEqual(report.safetyTrimDB, expected.safetyTrimDB, accuracy: 1e-6,
                           "\(name) safety trim")
            XCTAssertEqual(report.polarityFlipped, expected.polarityFlipped,
                           "\(name) polarity")
            // float32 again: these come off an array Python cast on the way
            // out. 1e-6 is still forty times tighter than the quietest bit
            // of a 24-bit file.
            XCTAssertEqual(rms(out), expected.outputRMS, accuracy: 1e-6, "\(name) rms")
            XCTAssertEqual(peak(out), expected.outputPeak, accuracy: 1e-6, "\(name) peak")
        }
    }

    /// The property that makes attack shaping a transient shaper rather than
    /// an equaliser: the band it works on comes out holding the energy it
    /// went in with, so only the distribution in time has changed. A port
    /// that dropped the renormalisation would still match every number above
    /// except this one.
    func testAttackShapingDoesNotChangeTheBandsEnergy() {
        let x = Fixtures.groove(bpm: 124)
        let (kicks, strengths) = SubBass.detectKicks(x, rate: Fixtures.rate)
        var report = SubBass.Report()
        _ = SubBass.shapeAttacks(x, rate: Fixtures.rate, kicks: kicks,
                                 strengths: strengths, boostDB: 6.0, report: &report)
        XCTAssertLessThan(abs(report.bandLevelChangeDB), 0.001,
                          "the punch band gained \(report.bandLevelChangeDB) dB")
        XCTAssertLessThan(report.sustainTrimDB, 0, "nothing was trimmed back")
    }

    // MARK: - Lossless MP3 gain

    func loadMP3(_ name: String) throws -> [UInt8] {
        let stem = String(name.dropLast(4))
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Golden/mp3/\(stem)", withExtension: "mp3"),
            "missing fixture \(name)")
        return [UInt8](try Data(contentsOf: url))
    }

    func testTheMP3FixturesAreTheFilesPythonRead() throws {
        for (name, expected) in golden.mp3 {
            let data = try loadMP3(name)
            XCTAssertEqual(String(Checksum.fnv1a(data)), expected.sourceFNV,
                           "\(name) is not the file the vectors were made from")
        }
    }

    func testFrameParsingMatches() throws {
        for (name, expected) in golden.mp3 {
            let data = try loadMP3(name)
            let frames = MP3Gain.parseFrames(data)
            XCTAssertEqual(frames.count, expected.frames, "\(name) frames")
            XCTAssertEqual(frames.filter(\.isInfoFrame).count, expected.infoFrames,
                           "\(name) info frames")
            XCTAssertEqual(frames.filter(\.hasCRC).count, expected.crcFrames,
                           "\(name) CRC frames")
            XCTAssertEqual(MP3Gain.skipID3v2(data), expected.id3Bytes, "\(name) ID3 size")

            let bits = MP3Gain.gainBits(data, frames: frames)
            XCTAssertEqual(bits.count, expected.movable, "\(name) movable granules")
            XCTAssertEqual(Array(bits.prefix(6)), expected.firstGainBits,
                           "\(name) gain bit offsets")
            let gains = MP3Gain.readGains(data, frames: frames)
            XCTAssertEqual(Array(gains.prefix(6)), expected.firstGains, "\(name) gains")
            XCTAssertEqual(gains.min(), expected.lowestGain, "\(name) lowest")
            XCTAssertEqual(gains.max(), expected.highestGain, "\(name) highest")
        }
    }

    func testPlanningMatches() throws {
        for (name, expected) in golden.mp3 {
            let data = try loadMP3(name)
            for (target, want) in expected.plans {
                let got = try MP3Gain.plan(data, targetDB: Double(target) ?? 0)
                let label = "\(name) @ \(target)"
                XCTAssertEqual(got.steps, want.steps, "\(label) steps")
                XCTAssertEqual(got.appliedDB, want.appliedDB, accuracy: 1e-9,
                               "\(label) applied")
                XCTAssertEqual(got.granules, want.granules, "\(label) granules")
                XCTAssertEqual(got.skippedGranules, want.skippedGranules,
                               "\(label) skipped")
                XCTAssertEqual(got.protectedFrames, want.protectedFrames,
                               "\(label) protected")
                XCTAssertEqual(got.clamped, want.clamped, "\(label) clamped")
                XCTAssertEqual(got.crossingGranules, want.crossingGranules,
                               "\(label) crossing")
                XCTAssertEqual(got.lowestGain, want.lowestGain, "\(label) lowest")
                XCTAssertEqual(got.lowestCount, want.lowestCount, "\(label) lowest count")
                XCTAssertEqual(got.headroomDownDB, want.headroomDownDB, accuracy: 1e-9,
                               "\(label) headroom")
            }
        }
    }

    func testApplyingProducesTheSameBytesAsPython() throws {
        for (name, expected) in golden.mp3 {
            let data = try loadMP3(name)
            for (steps, want) in expected.applied {
                let (out, crossed) = try MP3Gain.apply(data, steps: Int(steps) ?? 0)
                let label = "\(name) \(steps) steps"
                XCTAssertEqual(String(Checksum.fnv1a(out)), want.fnv, "\(label) bytes")
                XCTAssertEqual(crossed.count, want.crossed, "\(label) crossed")
                XCTAssertEqual(out.count == data.count, want.sameLength, "\(label) length")
                let changed = zip(data, out).filter { $0 != $1 }.count
                XCTAssertEqual(changed, want.changedBytes, "\(label) changed bytes")
            }
        }
    }

    /// The guarantee this whole approach exists for. Serato keeps cue points,
    /// beatgrids and waveform overviews in ID3 GEOB frames; a gain pass that
    /// disturbed a single byte of them would silently destroy someone's
    /// preparation for a set, and they would not find out until they were
    /// playing.
    func testTheID3RegionIsNeverTouched() throws {
        for (name, expected) in golden.mp3 where expected.id3Bytes > 0 {
            let data = try loadMP3(name)
            for steps in [-3, -1, 1, 2] {
                let (out, _) = try MP3Gain.apply(data, steps: steps)
                XCTAssertEqual(Array(out.prefix(expected.id3Bytes)),
                               Array(data.prefix(expected.id3Bytes)),
                               "\(name): \(steps) steps disturbed the ID3 tag")
            }
        }
    }

    /// Lossless means reversible, and reversible means byte-for-byte. Any
    /// weaker reading of it would let a library drift with every pass.
    func testAGainChangeIsExactlyReversible() throws {
        for (name, _) in golden.mp3 {
            let data = try loadMP3(name)
            for steps in [-4, -2, -1, 1, 3] {
                let (down, crossed) = try MP3Gain.apply(data, steps: steps)
                // Granules pushed across the audible floor no longer look
                // movable, so the way back has to be told about them by name.
                // Without that the reversal quietly leaves them behind.
                let (back, _) = try MP3Gain.apply(down, steps: -steps, alsoMove: crossed)
                XCTAssertEqual(back, data, "\(name): \(steps) steps did not reverse")
            }
        }
    }

    /// A protected frame carries a CRC over the last two header bytes and the
    /// side information -- exactly the bytes a gain change rewrites. Leave it
    /// stale and a checking decoder drops the frame.
    func testProtectedFramesGetACorrectCRC() throws {
        let data = try loadMP3("crc.mp3")
        let (out, _) = try MP3Gain.apply(data, steps: -2)
        let frames = MP3Gain.parseFrames(out)
        XCTAssertGreaterThan(frames.filter(\.hasCRC).count, 0, "fixture lost its CRCs")
        for frame in frames where frame.hasCRC && !frame.isInfoFrame {
            let header = try XCTUnwrap(MP3Gain.parseHeader(out, at: frame.offset))
            let stored = (Int(out[frame.offset + 4]) << 8) | Int(out[frame.offset + 5])
            let recomputed = MP3Gain.frameCRC(out, frame: frame,
                                              sideInfoSize: header.sideInfoSize)
            XCTAssertEqual(stored, recomputed,
                           "stale CRC on the frame at \(frame.offset)")
        }
    }

    /// Python rounds half to even. A track sitting exactly half a step from
    /// the target would otherwise move here and not there.
    func testStepRoundingIsHalfToEven() {
        let half = MP3Gain.dbPerStep / 2
        XCTAssertEqual(MP3Gain.steps(forDB: half), 0, "0.5 should round to 0")
        XCTAssertEqual(MP3Gain.steps(forDB: 3 * half), 2, "1.5 should round to 2")
        XCTAssertEqual(MP3Gain.steps(forDB: -half), 0, "-0.5 should round to 0")
        XCTAssertEqual(MP3Gain.steps(forDB: -3 * half), -2, "-1.5 should round to -2")
    }

    /// The ceiling exists because rounding to the nearest 1.5 dB step can
    /// round UP: a gain capped at +0.9 dB would become +1.505 and overshoot
    /// the very limit that capped it.
    ///
    /// `clamped` is NOT part of that. It means the FILE had less headroom
    /// than was asked for, and a ceiling is applied before the headroom is
    /// consulted -- so a request the ceiling cut down, and the file then
    /// granted in full, is not clamped. This test asserted otherwise and
    /// failed against a port that was right; the Python, asked the same
    /// question, also answers false. Both meanings are worth having, so
    /// both are checked, and the flag is exercised where it genuinely
    /// fires rather than left to the one case that does not.
    func testAStepCeilingIsNeverExceeded() throws {
        let data = try loadMP3("stereo.mp3")
        let uncapped = try MP3Gain.plan(data, targetDB: 4.5)
        XCTAssertGreaterThan(uncapped.steps, 0, "fixture has no room to go up")
        XCTAssertEqual(uncapped.steps, 3, "4.5 dB is three 1.505 dB steps")

        let capped = try MP3Gain.plan(data, targetDB: 4.5, maxSteps: 1)
        XCTAssertEqual(capped.steps, 1, "the ceiling was exceeded")
        XCTAssertFalse(capped.clamped,
                       "the file granted the ceiling's request in full")

        // What clamped does mean: 160 dB down, from a file holding 152.
        let beyond = try MP3Gain.plan(data, targetDB: -160)
        XCTAssertTrue(beyond.clamped, "asked for more than the file had")
        XCTAssertEqual(beyond.steps, -101, "and got exactly what it had")
    }

    /// Nothing outside an audio frame may move, whatever the step.
    func testOnlyAudioFrameBytesChange() throws {
        let data = try loadMP3("serato.mp3")
        let (out, _) = try MP3Gain.apply(data, steps: -2)
        let frames = MP3Gain.parseFrames(data)
        var insideAFrame = [Bool](repeating: false, count: data.count)
        for frame in frames {
            for i in frame.offset..<min(data.count, frame.offset + frame.length) {
                insideAFrame[i] = true
            }
        }
        for index in data.indices where data[index] != out[index] {
            XCTAssertTrue(insideAFrame[index],
                          "byte \(index) changed and is outside every audio frame")
        }
    }

    // MARK: - Decoding

    /// Not held to the Python sample for sample, because it cannot be. The
    /// Python shells out to ffmpeg and this uses Apple's decoder; they
    /// disagree slightly and may trim encoder priming by different amounts.
    ///
    /// That difference is worth knowing rather than assuming, so this prints
    /// it. If the printed numbers are ever larger than a few hundredths of a
    /// decibel, the app and the command line will disagree about a library
    /// and the cause is here, not in the measurement.
    func testDecodingAgreesWithFFmpegCloselyEnough() throws {
        for (name, expected) in golden.decode {
            let url = try XCTUnwrap(
                Bundle.module.url(forResource: "Golden/mp3/\(name.dropLast(4))",
                                  withExtension: "mp3"))
            let (audio, _) = try AudioDecoder.decode(url)
            let got = BS1770.measure(audio)

            let frameDrift = abs(audio[0].count - expected.frames)
            let integrated = abs(got.lufsI - expected.lufs_i)
            let percentile = abs((got.sP95 ?? 0) - expected.s_p95)
            let peak = abs(got.truePeakDBTP - expected.true_peak_dbtp)
            print(String(format: "decode %@: %+d frames, LUFS-I %+.4f, "
                         + "s_p95 %+.4f, true peak %+.4f",
                         name, audio[0].count - expected.frames,
                         got.lufsI - expected.lufs_i,
                         (got.sP95 ?? 0) - expected.s_p95,
                         got.truePeakDBTP - expected.true_peak_dbtp))

            XCTAssertEqual(audio.count, 2, "\(name) should always come out stereo")
            // A tenth of a second of priming difference is tolerable; a
            // second means the file was decoded wrongly, not differently.
            XCTAssertLessThan(frameDrift, 4800, "\(name) length drift")
            XCTAssertLessThan(integrated, 0.25, "\(name) LUFS-I")
            XCTAssertLessThan(percentile, 0.25, "\(name) s_p95")
            XCTAssertLessThan(peak, 0.25, "\(name) true peak")
        }
    }

    func testAMonoFileComesOutAsDualMono() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Golden/mp3/mono",
                                                  withExtension: "mp3"))
        let (audio, sourceChannels) = try AudioDecoder.decode(url)
        // Deliberate: a mono record played in a club comes out of both
        // stacks, so that is the signal worth measuring. What it really was
        // is reported separately rather than lost.
        XCTAssertEqual(sourceChannels, 1, "fixture is no longer mono")
        XCTAssertEqual(audio.count, 2)
        XCTAssertEqual(audio[0], audio[1], "the two channels should be identical")
    }

    // MARK: - The year rule

    func testTheYearRegexMatchesPython() {
        for (text, expected) in golden.yearFromText {
            XCTAssertEqual(Tags.year(in: text), expected, "year in \(text.debugDescription)")
        }
    }

    /// The rule that a compilation's plain `date` is the REISSUE year.
    /// Reading 2011 off "100 Hits - The New Romantics (2011)" filed
    /// early-eighties mastering into the modern reference curve and quietly
    /// spoiled every era comparison drawn from it.
    func testOriginalYearBeatsReleaseYear() {
        for expected in golden.yearFromTags {
            let (year, original) = Tags.year(from: expected.tags)
            XCTAssertEqual(year, expected.year, "\(expected.tags)")
            XCTAssertEqual(original, expected.isOriginal.map { $0 != 0 },
                           "\(expected.tags) provenance")
        }
    }

    // MARK: - Walking a library

    func testTheSurveyCountsWhatItPassedOver() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("survey-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("CD1")
        let hidden = root.appendingPathComponent(".Trashes")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func write(_ url: URL) throws { try Data([0]).write(to: url) }
        try write(root.appendingPathComponent("a.mp3"))
        try write(root.appendingPathComponent("b.MP3"))          // case
        try write(root.appendingPathComponent("notes.txt"))      // counted, skipped
        try write(root.appendingPathComponent("._a.mp3"))        // AppleDouble
        try write(nested.appendingPathComponent("c.flac"))
        try write(hidden.appendingPathComponent("junk.mp3"))     // dot-directory

        let result = FileSurvey.survey(root)
        let names = result.audio.map(\.lastPathComponent).sorted()
        XCTAssertEqual(names, ["a.mp3", "b.MP3", "c.flac"])
        XCTAssertEqual(result.skipped["txt"], 1)
        XCTAssertEqual(result.folders, 2, "the dot-directory should not be walked")
        XCTAssertFalse(result.singleFile)
    }

    func testASingleFileIsReportedAsSuch() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Golden/mp3/stereo",
                                                  withExtension: "mp3"))
        let result = FileSurvey.survey(url)
        XCTAssertTrue(result.singleFile)
        XCTAssertEqual(result.audio, [url])
    }

    // MARK: - The scan database

    /// Opens a database the PYTHON wrote. The compatibility claim -- same
    /// file, same schema, either side -- is only worth making if it is
    /// demonstrated, and it cannot be demonstrated from one side alone.
    /// Re-measuring a real library costs hours; someone who already scanned
    /// six hundred tracks from the command line should not have to do it
    /// again to open a window.
    /// Copied before opening, because opening writes a journal and a test
    /// should not modify its own fixtures.
    func openGoldenLibrary() throws -> Library {
        let source = try XCTUnwrap(
            Bundle.module.url(forResource: "Golden/library", withExtension: "db"))
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-\(UUID().uuidString).db")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: source, to: copy)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        return try Library(at: copy)
    }

    func testADatabaseWrittenByPythonOpensAndReads() throws {
        let library = try openGoldenLibrary()
        let rows = try library.tracks()
        XCTAssertEqual(rows.count, golden.library.tracks.count)

        for expected in golden.library.tracks {
            let row = try XCTUnwrap(rows.first { $0.path.hasSuffix(expected.path) },
                                    "missing \(expected.path)")
            XCTAssertEqual(row.artist, expected.artist)
            XCTAssertEqual(row.title, expected.title)
            XCTAssertEqual(row.year, expected.year)
            XCTAssertEqual(try XCTUnwrap(row.lufsI), expected.lufs_i, accuracy: 1e-6)
            XCTAssertEqual(try XCTUnwrap(row.sP95), expected.s_p95, accuracy: 1e-6)
        }

        let shape = try library.lowEndShape()
        XCTAssertEqual(shape.count, golden.library.tracks.count,
                       "every track should have a low-end figure")
    }

    /// How much each track gets when the sub is sized per track rather than
    /// set by hand. This is the number that decides what actually happens to
    /// a library under the `restore` and `disco-70s` profiles, so it is
    /// checked against the Python's own arithmetic rather than assumed.
    func testPerTrackSizingMatchesThePython() throws {
        let library = try openGoldenLibrary()
        XCTAssertEqual(Library.lowShapeBands, golden.library.lowShapeBands,
                       "the bands the sub reasons about moved")

        let curves = try library.referenceCurves()
        let name = try XCTUnwrap(
            Library.resolveReference(curves, golden.library.referenceFolder))
        let curve = try XCTUnwrap(curves[name])
        for (band, expected) in golden.library.curve {
            let got = try XCTUnwrap(curve[Double(band) ?? 0], "no curve at \(band) Hz")
            XCTAssertEqual(got, expected, accuracy: 1e-6, "curve at \(band) Hz")
        }

        for expected in golden.library.shortfalls {
            let path = try XCTUnwrap(
                try library.tracks().first { $0.path.hasSuffix(expected.path) })
            let (amount, reason) = try library.shortfall(of: path.path, against: curve,
                                                         cap: 8)
            guard let mean = expected.meanDeficitDB else { continue }
            if mean <= 0.5 {
                // Half a decibel is below what anyone hears on a dancefloor
                // and inside the spread between pressings of one record.
                XCTAssertEqual(amount, 0, "\(expected.path) should be left alone")
                XCTAssertNotNil(reason, "\(expected.path) declined without saying why")
            } else {
                XCTAssertEqual(amount, min(mean, 8), accuracy: 1e-6, expected.path)
                XCTAssertNil(reason, expected.path)
            }
        }
    }

    /// An ambiguous reference names no folder rather than guessing at one.
    /// Sizing every track in a library against the wrong corpus is not a
    /// mistake worth making quietly.
    func testAnAmbiguousReferenceResolvesToNothing() {
        let curves: [String: [Double: Double]] = ["Disco Gold": [:], "Disco Delight": [:],
                                                  "Yearbook 99": [:]]
        XCTAssertEqual(Library.resolveReference(curves, "Disco Gold"), "Disco Gold")
        XCTAssertEqual(Library.resolveReference(curves, "yearbook"), "Yearbook 99")
        XCTAssertNil(Library.resolveReference(curves, "disco"), "two folders match")
        XCTAssertNil(Library.resolveReference(curves, "nothing"))
    }

    /// Grouping on the bare parent name merges two compilations that each
    /// have a CD1, and a corpus silently averaged with another corpus is
    /// worse than no answer at all -- it is a wrong number that looks
    /// exactly like a right one. This is the table a profile's caps get set
    /// from, so it has to be the Python's answer and not merely a plausible
    /// one.
    func testFolderLabelsMatchPython() {
        for expected in golden.folderLabels {
            XCTAssertEqual(Library.folderLabels(expected.paths), expected.labels,
                           "\(expected.paths)")
        }
    }

    func testTwoCompilationsWithACD1StayApart() {
        let labels = Library.folderLabels([
            "/m/Now Yearbook 99 (2026)/CD1/a.mp3",
            "/m/NOW 100 Hits Party/CD1/b.mp3"])
        XCTAssertEqual(Set(labels.values).count, 2,
                       "two different CD1 folders were merged into one corpus")
    }

    /// The vectorised true-peak detector against the scalar one it replaced.
    ///
    /// The golden vectors already pin true peak to the Python's number, but
    /// only for the four fixtures. This holds the two implementations to
    /// each other on signals chosen to be awkward -- the first samples,
    /// where the filter is still hanging off the front of the signal, a
    /// length that is not a multiple of the block size, and a peak placed
    /// deliberately at the very end.
    func testTheFastTruePeakMatchesTheSlowOne() {
        for (name, signal) in truePeakCases() {
            let fast = Resampler.peakOfUpsampled(signal, by: 4)
            let slow = Resampler.peakOfUpsampledScalar(signal, by: 4)
            XCTAssertEqual(fast, slow, accuracy: 1e-12,
                           "\(name): Accelerate and the scalar loop disagree")
        }
    }

    func truePeakCases() -> [(String, [Double])] {
        var cases: [(String, [Double])] = []
        cases.append(("empty", []))
        cases.append(("one sample", [0.9]))
        // Shorter than the filter, so every output is an edge case.
        cases.append(("shorter than the taps", (0..<7).map { sin(Double($0)) * 0.5 }))
        // Longer than one block, and not a whole number of them.
        let long = (0..<(70_000)).map { sin(Double($0) * 0.07) * 0.8 }
        cases.append(("across a block boundary", long))
        // A peak on the last sample: the one an off-by-one would drop.
        var trailing = [Double](repeating: 0.01, count: 70_001)
        trailing[trailing.count - 1] = 0.95
        cases.append(("peak at the very end", trailing))
        // And on the first, where there is no history to convolve with.
        var leading = [Double](repeating: 0.01, count: 1000)
        leading[0] = 0.95
        cases.append(("peak at the very start", leading))
        return cases
    }

    /// vDSP's real FFT against the radix-2 loop it replaced.
    ///
    /// The packing is the part worth checking: Nyquist is folded into the
    /// imaginary part of bin zero and the output carries a factor of two
    /// that numpy does not. Both are corrections that would leave a
    /// spectrum looking entirely plausible while being wrong -- the shape
    /// right, the level out by 6 dB, or one band at each end nonsense.
    func testTheFastFFTMatchesTheSlowOne() throws {
        for size in [8, 64, 1024, 4096] {
            let plan = try XCTUnwrap(FFT.Plan(size: size), "no plan for \(size)")
            for (name, signal) in fftCases(size) {
                let fast = plan.powerSpectrum(signal)
                let slow = FFT.powerSpectrumScalar(signal)
                XCTAssertEqual(fast.count, slow.count, "\(name) at \(size)")
                // Relative, because power spans many orders of magnitude and
                // an absolute tolerance would be vacuous at the top end and
                // impossible at the bottom.
                let scale = max(slow.max() ?? 1, 1e-300)
                for (index, expected) in slow.enumerated() {
                    XCTAssertEqual(fast[index] / scale, expected / scale,
                                   accuracy: 1e-9,
                                   "\(name) at \(size), bin \(index)")
                }
            }
        }
    }

    func fftCases(_ size: Int) -> [(String, [Double])] {
        var cases: [(String, [Double])] = []
        // DC only: everything must land in bin zero, nothing in Nyquist.
        cases.append(("constant", [Double](repeating: 0.5, count: size)))
        // Alternating: everything in Nyquist, which is the folded bin.
        cases.append(("nyquist", (0..<size).map { $0 % 2 == 0 ? 1.0 : -1.0 }))
        // A bin-centred tone, so one bin should hold it all.
        cases.append(("tone on a bin",
                      (0..<size).map { sin(2 * .pi * 4 * Double($0) / Double(size)) }))
        // And one that is not, so energy spreads and every bin matters.
        cases.append(("tone between bins",
                      (0..<size).map { sin(2 * .pi * 4.37 * Double($0) / Double(size)) }))
        cases.append(("noise", Fixtures.xorshift(seed: 99, count: size)))
        return cases
    }

    /// The tag length that decides where the audio starts.
    ///
    /// Syncsafe: seven bits per byte, so a length can never contain a run
    /// that looks like a frame sync. Read as a plain integer it comes out
    /// too large and the splice lands in the middle of the audio, which
    /// produces a file that looks right and will not play.
    func testID3v2LengthIsReadAsSyncsafe() throws {
        // 0x01 0x00 0x00 0x00 syncsafe is 2^21, not 16,777,216.
        let header: [UInt8] = [0x49, 0x44, 0x33, 4, 0, 0, 0x01, 0x00, 0x00, 0x00]
        XCTAssertEqual(AudioWriter.id3v2Length(header), 10 + (1 << 21))

        // Every byte at its maximum: 0x7F7F7F7F syncsafe is 2^28 - 1.
        let full: [UInt8] = [0x49, 0x44, 0x33, 4, 0, 0, 0x7F, 0x7F, 0x7F, 0x7F]
        XCTAssertEqual(AudioWriter.id3v2Length(full), 10 + (1 << 28) - 1)

        // The footer flag is another ten bytes at the end.
        let footed: [UInt8] = [0x49, 0x44, 0x33, 4, 0, 0x10, 0, 0, 0x02, 0x00]
        XCTAssertEqual(AudioWriter.id3v2Length(footed), 10 + 256 + 10)

        // No tag at all, and a short read.
        XCTAssertEqual(AudioWriter.id3v2Length([0xFF, 0xFB, 0xE0, 0x00]), 0)
        XCTAssertEqual(AudioWriter.id3v2Length([]), 0)
    }

    /// The same answer the gain path already relies on, from a real file.
    func testID3v2LengthAgreesWithTheGainPath() throws {
        for name in ["serato.mp3", "stereo.mp3", "crc.mp3"] {
            let data = try loadMP3(name)
            XCTAssertEqual(AudioWriter.id3v2Length(Array(data.prefix(10))),
                           MP3Gain.skipID3v2(data),
                           "\(name): the writer and the gain path disagree "
                           + "about where the audio starts")
        }
    }

    func testTheSchemaVersionMatchesThePython() {
        XCTAssertEqual(Library.schemaVersion, golden.library.schemaVersion,
                       "the two sides would stop opening each other's files")
    }

    func testANewerDatabaseIsRefusedRatherThanCorrupted() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("future-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let library = try Library(at: url)
        try library.db.run("UPDATE meta SET value = '99' WHERE key = 'schema_version'")
        XCTAssertThrowsError(try Library(at: url),
                             "a database from a newer build must not be written to")
    }

    func testStoringAndReadingBackARoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("round-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let library = try Library(at: url)
        let audio = Fixtures.make(.programme)
        var tags = Tags()
        tags.artist = "Chic"; tags.title = "Le Freak"; tags.year = 1978
        tags.yearIsOriginal = true

        let track = URL(fileURLWithPath: "/tmp/le-freak.mp3")
        try library.store(Library.Analysis(
            url: track, sizeBytes: 1234, mtimeNanoseconds: 5678, status: "ok",
            tags: tags, codec: "mp3", loudness: BS1770.measure(audio),
            bands: Spectrum.analyse(audio, rate: Fixtures.rate)))

        let rows = try library.tracks()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].artist, "Chic")
        XCTAssertEqual(rows[0].year, 1978)

        // Storing twice must replace, not accumulate: a re-scan of a library
        // that already had rows would otherwise double every band.
        try library.store(Library.Analysis(
            url: track, sizeBytes: 1234, mtimeNanoseconds: 5678, status: "ok",
            tags: tags, codec: "mp3", loudness: BS1770.measure(audio),
            bands: Spectrum.analyse(audio, rate: Fixtures.rate)))
        XCTAssertEqual(try library.tracks().count, 1, "a re-store duplicated the track")
        XCTAssertEqual(try library.lowEndShape().count, 1)

        XCTAssertFalse(try library.needsAnalysis(track, size: 1234,
                                                 mtimeNanoseconds: 5678),
                       "an unchanged file should not be measured again")
        XCTAssertTrue(try library.needsAnalysis(track, size: 9999,
                                                mtimeNanoseconds: 5678),
                      "a changed file must be measured again")
    }

    /// A silent track measures -inf, which has no SQLite representation. It
    /// has to arrive as "unknown" rather than as a number that reports would
    /// average in.
    func testANonFiniteMeasurementIsStoredAsUnknown() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silent-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let library = try Library(at: url)
        let silence = [[Double]](repeating: [Double](repeating: 0, count: 48000 * 4), count: 2)
        try library.store(Library.Analysis(
            url: URL(fileURLWithPath: "/tmp/silent.mp3"), sizeBytes: 1,
            mtimeNanoseconds: 1, status: "ok", loudness: BS1770.measure(silence)))
        let row = try XCTUnwrap(try library.tracks().first)
        XCTAssertNil(row.lufsI, "-inf was stored as a number")
    }

    // MARK: - Helpers

    func close(_ got: Double?, _ expected: Double?, _ accuracy: Double, _ label: String) {
        guard let expected else { XCTAssertNil(got, label); return }
        guard let got else { XCTFail("\(label): expected \(expected), got nil"); return }
        XCTAssertEqual(got, expected, accuracy: accuracy, label)
    }


    func bank() -> [String: SOS] {
        ["subBand": FilterBank.subBand, "kickBand": FilterBank.kickBand,
         "punchBand": FilterBank.punchBand, "subFloor": FilterBank.subFloor,
         "subCeiling": FilterBank.subCeiling, "envelope20": FilterBank.envelope20,
         "envelope200": FilterBank.envelope200, "envelope60": FilterBank.envelope60,
         "envelope3": FilterBank.envelope3]
    }

    func rms(_ x: [[Double]]) -> Double {
        let all = x.flatMap { $0 }
        guard !all.isEmpty else { return 0 }
        return (all.reduce(0) { $0 + $1 * $1 } / Double(all.count)).squareRoot()
    }

    func peak(_ x: [[Double]]) -> Double { x.flatMap { $0 }.map(abs).max() ?? 0 }

    func same(_ got: Double?, _ expected: Value?, _ accuracy: Double, _ label: String) {
        guard let expected else { XCTAssertNil(got, label); return }
        guard let got else { XCTFail("\(label): expected \(expected.double), got nil"); return }
        if expected.double.isInfinite {
            XCTAssertEqual(got, expected.double, label)
        } else {
            XCTAssertEqual(got, expected.double, accuracy: accuracy, label)
        }
    }
}
