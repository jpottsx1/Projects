import Foundation

/// Long-term average spectrum in 1/3-octave bands, and the low-end
/// diagnostics built on it. A port of `loudnesslab/spectrum.py`.
///
/// It answers three things a loudness number cannot: what SHAPE the low end
/// is independent of how loud the track is; whether there is musical content
/// down there or a constant floor of rumble that would only get louder if
/// equalised; and whether the record was cut for vinyl, which shows up as
/// side energy collapsing below 150-300 Hz.
public enum Spectrum {

    public static let nfft = 32768      // 1.46 Hz bins at 48 kHz
    public static let hop = nfft / 2

    /// Nominal ISO 1/3-octave centres, 20 Hz to 20 kHz.
    public static let bandCentres: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500,
        630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000,
        10000, 12500, 16000, 20000,
    ]

    public static let lowBandMaxHz = 315.0

    /// A band this far under the track's broadband level carries no audible
    /// content, so its stereo relationship is whatever the anti-alias filters
    /// left behind -- uncorrelated residue that reads as WIDE. Reporting that
    /// would invert the vinyl-mono signal exactly where it matters most, so
    /// the width is withheld instead.
    public static let minShapeForWidthDB = -40.0

    /// Frames this far below the track's loud frames are run-ins, gaps or
    /// digital black, and are kept out of the statistics.
    public static let frameGateLU = 40.0
    public static let frameGateFloorDB = -90.0

    public struct Band: Sendable {
        public let bandHz: Double
        public let ltasDB: Double?
        public let shapeDB: Double?
        public let p10DB: Double?
        public let p90DB: Double?
        public let sideMidDB: Double?
    }

    struct Edge { let centre: Double; let first: Int; let last: Int }

    /// Bin ranges per band, for the bands that fit under Nyquist.
    static func edges(rate: Double) -> [Edge] {
        let df = rate / Double(nfft)
        let nyquist = rate / 2
        var out: [Edge] = []
        for centre in bandCentres {
            let low = centre * pow(2, -1.0 / 6)
            let high = centre * pow(2, 1.0 / 6)
            if high >= nyquist { break }
            let first = max(1, Int((low / df).rounded(.up)))
            var last = Int((high / df).rounded(.down)) + 1
            if last <= first { last = first + 1 }   // narrower than a bin
            out.append(Edge(centre: centre, first: first, last: last))
        }
        return out
    }

    /// numpy's `hanning`: symmetric, so it starts and ends at exactly zero.
    /// The periodic variant differs by one sample and would shift every band
    /// level very slightly, which is the sort of discrepancy that is hard to
    /// attribute once it is buried in a report.
    static func hann(_ n: Int) -> [Double] {
        guard n > 1 else { return [1] }
        return (0..<n).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(n - 1)) }
    }

    /// Per-frame band mean square and broadband mean square, for one channel.
    /// Normalised so a full-scale sine inside a band reads 0.5 -- its mean
    /// square -- matching the dBFS-RMS convention used elsewhere.
    static func framePower(_ x: [Double], rate: Double)
    -> (bands: [[Double]], broadband: [Double]) {
        let window = hann(nfft)
        let norm = Double(nfft) * window.reduce(0) { $0 + $1 * $1 }
        let edges = edges(rate: rate)
        guard x.count >= nfft else { return ([], []) }
        let frames = 1 + (x.count - nfft) / hop

        var bands = [[Double]](); bands.reserveCapacity(frames)
        var broadband = [Double](); broadband.reserveCapacity(frames)

        for frame in 0..<frames {
            let start = frame * hop
            var windowed = [Double](repeating: 0, count: nfft)
            for i in 0..<nfft { windowed[i] = x[start + i] * window[i] }
            var spectrum = FFT.powerSpectrum(windowed)
            // One-sided: everything but DC and Nyquist counts twice.
            for i in 1..<(spectrum.count - 1) { spectrum[i] *= 2 }

            broadband.append(spectrum.reduce(0, +) / norm)
            bands.append(edges.map { edge in
                spectrum[edge.first..<edge.last].reduce(0, +) / norm
            })
        }
        return (bands, broadband)
    }

    static func db(_ power: Double) -> Double { 10 * log10(max(power, 1e-30)) }

    /// `x` is two channels. One row per band, ready for the library table.
    public static func analyse(_ x: [[Double]], rate: Double,
                               sourceIsMono: Bool = false) -> [Band] {
        precondition(x.count == 2, "expected stereo")
        let n = x[0].count
        let mid = (0..<n).map { (x[0][$0] + x[1][$0]) * 0.5 }
        let side = (0..<n).map { (x[0][$0] - x[1][$0]) * 0.5 }

        let (midBands, midBroad) = framePower(mid, rate: rate)
        guard !midBands.isEmpty else { return [] }

        // Gate out silence relative to the track's OWN loud frames, rather
        // than an absolute level: a quiet record is not a silent one.
        let broadDB = midBroad.map(db)
        let loud = BS1770.percentile(broadDB, 95) ?? 0
        let threshold = max(loud - frameGateLU, frameGateFloorDB)
        var keep = broadDB.map { $0 > threshold }
        if keep.filter({ $0 }).count < 4 { keep = keep.map { _ in true } }

        let sideBands = sourceIsMono ? [] : framePower(side, rate: rate).bands
        let kept = zip(midBands, keep).filter { $0.1 }.map(\.0)
        let keptBroad = zip(midBroad, keep).filter { $0.1 }.map(\.0)
        let broadbandDB = db(keptBroad.reduce(0, +) / Double(keptBroad.count))

        return edges(rate: rate).enumerated().map { index, edge in
            let column = kept.map { $0[index] }
            let ltas = db(column.reduce(0, +) / Double(column.count))
            let shape = ltas - broadbandDB
            let columnDB = column.map(db)

            var sideMid: Double?
            if !sideBands.isEmpty, shape >= minShapeForWidthDB {
                let keptSide = zip(sideBands, keep).filter { $0.1 }.map { $0.0[index] }
                let sideMean = keptSide.reduce(0, +) / Double(keptSide.count)
                let midMean = column.reduce(0, +) / Double(column.count)
                if midMean > 0, sideMean > 0 { sideMid = 10 * log10(sideMean / midMean) }
            }

            return Band(bandHz: edge.centre,
                        ltasDB: finite(ltas), shapeDB: finite(shape),
                        p10DB: finite(BS1770.percentile(columnDB, 10)),
                        p90DB: finite(BS1770.percentile(columnDB, 90)),
                        sideMidDB: finite(sideMid))
        }
    }

    /// Matches the Python, which rounds to three decimals on the way into the
    /// database and stores nothing at all for a value that is not finite.
    static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return (value * 1000).rounded() / 1000
    }
}
