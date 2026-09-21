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

    static let golden: Golden = {
        guard let url = Bundle.module.url(forResource: "Golden/golden", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Golden.self, from: data) else {
            fatalError("Golden/golden.json is missing or unreadable. "
                       + "Run: python3 tools/make_golden.py")
        }
        return decoded
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

    // MARK: - Helpers

    func bank() -> [String: SOS] {
        ["subBand": FilterBank.subBand, "kickBand": FilterBank.kickBand,
         "punchBand": FilterBank.punchBand, "subFloor": FilterBank.subFloor,
         "subCeiling": FilterBank.subCeiling, "envelope20": FilterBank.envelope20,
         "envelope200": FilterBank.envelope200, "onsetFast": FilterBank.onsetFast]
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
