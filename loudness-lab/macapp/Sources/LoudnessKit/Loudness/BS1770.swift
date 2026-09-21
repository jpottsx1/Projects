import Foundation

/// ITU-R BS.1770-4 loudness, and EBU Tech 3342 loudness range.
///
/// A port of `loudnesslab/bs1770.py`, which is this project's reference and
/// is validated against ffmpeg's ebur128 to within 0.05 LU. This file is held
/// to the Python's own numbers by the golden vectors in the test target; if
/// they disagree, the Python is right and this is wrong.
///
/// Everything runs at 48 kHz. The K-weighting coefficients published in
/// BS.1770-4 are defined at that rate, and deriving them for another one is
/// an extra source of error that decoding to 48 kHz on the way in avoids.
///
/// The short-term percentiles are the numbers this project actually acts on.
/// Matching tracks on the 95th percentile of a rolling three-second loudness
/// is what keeps the loud body of a dynamic record level with a flat modern
/// master; integrated loudness averages the quiet passages into the answer
/// and lands a dynamic track up to 2.8 dB quieter to the ear.
public enum BS1770 {

    public static let rate = 48000.0

    // BS.1770-4 Table 1/2: stage 1 high shelf, stage 2 RLB high-pass.
    static let stage1B = [1.53512485958697, -2.69169618940638, 1.19839281085285]
    static let stage1A = [1.0, -1.69065929318241, 0.73248077421585]
    static let stage2B = [1.0, -2.0, 1.0]
    static let stage2A = [1.0, -1.99004745483398, 0.99007225036621]

    public static let offset = -0.691        // BS.1770-4 eq. 2
    public static let absoluteGate = -70.0   // LUFS
    public static let relativeGateI = -10.0  // LU, for integrated loudness
    public static let relativeGateLRA = -20.0

    public static let momentarySeconds = 0.400
    public static let momentaryHopSeconds = 0.100   // 75% overlap, as specified
    public static let shortSeconds = 3.000
    public static let shortHopSeconds = 0.100       // what libebur128 uses

    public struct Result: Sendable {
        public var lufsI: Double
        public var lra: Double?
        public var sMax: Double?
        public var sP95: Double?
        public var sP90: Double?
        public var sP50: Double?
        public var sP10: Double?
        public var truePeakDBTP: Double
        public var samplePeakDBFS: Double
        public var clippedSamples: Int
        public var clipRuns: Int
        public var crestDB: Double?
        public var shortTerm: [Double]
    }

    // MARK: - K-weighting

    /// Both K-weighting stages, as a plain difference equation per channel.
    /// Not the SOS path: these coefficients come straight from the standard
    /// as transfer functions and are used exactly as published.
    public static func kWeight(_ x: [[Double]]) -> [[Double]] {
        x.map { channel in
            biquad(biquad(channel, stage1B, stage1A), stage2B, stage2A)
        }
    }

    static func biquad(_ x: [Double], _ b: [Double], _ a: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in x.indices {
            let input = x[i]
            let y = b[0] * input + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
            out[i] = y
            x2 = x1; x1 = input
            y2 = y1; y1 = y
        }
        return out
    }

    // MARK: - Blocks

    /// Mean square per block per channel.
    ///
    /// Runs on a cumulative sum so a twelve-minute extended mix stays cheap.
    /// The residual error only ever reaches blocks far below the absolute
    /// gate, which are discarded anyway.
    static func blockMeanSquare(_ y: [[Double]], window: Double, hop: Double)
    -> [[Double]] {
        guard let first = y.first else { return [] }
        let n = first.count
        let win = Int((window * rate).rounded())
        let step = Int((hop * rate).rounded())
        guard n >= win, win > 0, step > 0 else { return [] }
        let blocks = 1 + (n - win) / step

        var perChannel: [[Double]] = []
        perChannel.reserveCapacity(y.count)
        for channel in y {
            var cumulative = [Double](repeating: 0, count: n + 1)
            for i in 0..<n { cumulative[i + 1] = cumulative[i] + channel[i] * channel[i] }
            var means = [Double](repeating: 0, count: blocks)
            for b in 0..<blocks {
                let start = b * step
                means[b] = (cumulative[start + win] - cumulative[start]) / Double(win)
            }
            perChannel.append(means)
        }
        // Transposed to block-major, which is how every consumer wants it.
        return (0..<blocks).map { b in perChannel.map { $0[b] } }
    }

    /// BS.1770-4 eq. 2. Stereo only; the standard weights surround channels
    /// at 1.41 and everything here is decoded to stereo.
    static func blockLoudness(_ meanSquare: [[Double]]) -> [Double] {
        meanSquare.map { channels in
            let power = channels.reduce(0, +)
            return power > 0 ? offset + 10 * log10(power) : -.infinity
        }
    }

    /// Two passes: an absolute gate, then a gate relative to what that gave.
    /// The averaging is over mean squares, not over decibels.
    static func gatedMean(_ meanSquare: [[Double]], _ loudness: [Double],
                          relativeGate: Double) -> Double {
        func mean(_ keep: [Bool]) -> Double? {
            let kept = zip(meanSquare, keep).filter { $0.1 }.map(\.0)
            guard !kept.isEmpty, let width = kept.first?.count else { return nil }
            var sums = [Double](repeating: 0, count: width)
            for row in kept { for i in 0..<width { sums[i] += row[i] } }
            let power = sums.reduce(0, +) / Double(kept.count)
            return power > 0 ? power : nil
        }
        var keep = loudness.map { $0 > absoluteGate }
        guard let first = mean(keep) else { return -.infinity }
        let threshold = offset + 10 * log10(first) + relativeGate
        keep = zip(keep, loudness).map { $0 && $1 > threshold }
        guard let second = mean(keep) else { return -.infinity }
        return offset + 10 * log10(second)
    }

    // MARK: - Measurement

    /// `x` is per-channel, each the same length, in [-1, 1].
    public static func measure(_ x: [[Double]]) -> Result {
        let y = kWeight(x)
        let momentaryMS = blockMeanSquare(y, window: momentarySeconds, hop: momentaryHopSeconds)
        let shortMS = blockMeanSquare(y, window: shortSeconds, hop: shortHopSeconds)
        let momentaryL = blockLoudness(momentaryMS)
        let shortL = blockLoudness(shortMS)

        let lufsI = momentaryMS.isEmpty
            ? -Double.infinity
            : gatedMean(momentaryMS, momentaryL, relativeGate: relativeGateI)

        // Percentiles run over absolutely-gated short-term values, so a long
        // silent intro or run-out cannot drag the low ones down.
        let gatedShort = shortL.filter { $0 > absoluteGate }

        let peak = x.flatMap { $0 }.map(abs).max() ?? 0
        let truePeak = truePeakDBTP(x)
        let clipping = countClipping(x)
        let integrated = lufsI.isFinite ? lufsI : nil

        return Result(
            lufsI: lufsI,
            lra: loudnessRange(shortMS, shortL),
            sMax: gatedShort.max(),
            sP95: percentile(gatedShort, 95),
            sP90: percentile(gatedShort, 90),
            sP50: percentile(gatedShort, 50),
            sP10: percentile(gatedShort, 10),
            truePeakDBTP: truePeak,
            samplePeakDBFS: peak > 0 ? 20 * log10(peak) : -.infinity,
            clippedSamples: clipping.samples,
            clipRuns: clipping.runs,
            crestDB: (truePeak.isFinite && integrated != nil) ? truePeak - integrated! : nil,
            shortTerm: gatedShort)
    }

    /// EBU Tech 3342: P95 - P10 of the gated short-term loudness.
    static func loudnessRange(_ shortMS: [[Double]], _ shortL: [Double]) -> Double? {
        guard !shortMS.isEmpty else { return nil }
        var keep = shortL.map { $0 > absoluteGate }
        guard keep.filter({ $0 }).count >= 2 else { return nil }

        let kept = zip(shortMS, keep).filter { $0.1 }.map(\.0)
        guard let width = kept.first?.count else { return nil }
        var sums = [Double](repeating: 0, count: width)
        for row in kept { for i in 0..<width { sums[i] += row[i] } }
        let power = sums.reduce(0, +) / Double(kept.count)
        guard power > 0 else { return nil }
        let threshold = offset + 10 * log10(power) + relativeGateLRA
        keep = zip(keep, shortL).map { $0 && $1 > threshold }

        let values = zip(shortL, keep).filter { $0.1 }.map(\.0)
        guard values.count >= 2,
              let high = percentile(values, 95), let low = percentile(values, 10)
        else { return nil }
        return high - low
    }

    /// numpy's default: linear interpolation between the two nearest ranks.
    public static func percentile(_ values: [Double], _ q: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        if sorted.count == 1 { return sorted[0] }
        let position = q / 100 * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    // MARK: - Peaks

    /// Runs of samples pinned at full scale: the signature of a master that
    /// was clipped before it reached us.
    public static func countClipping(_ x: [[Double]], threshold: Double = 0.9995,
                                     runLength: Int = 4) -> (samples: Int, runs: Int) {
        guard let first = x.first else { return (0, 0) }
        var samples = 0, runs = 0, current = 0
        for i in 0..<first.count {
            var loudest = 0.0
            for channel in x { loudest = max(loudest, abs(channel[i])) }
            if loudest >= threshold {
                samples += 1
                current += 1
            } else {
                if current >= runLength { runs += 1 }
                current = 0
            }
        }
        if current >= runLength { runs += 1 }
        return (samples, runs)
    }

    /// Peak of the 4x-oversampled signal, in dBTP.
    ///
    /// BS.1770-4 puts 4x oversampling within about 0.5 dB of the real peak,
    /// which is why this project aims at -1.0 dBTP rather than -0.1.
    public static func truePeakDBTP(_ x: [[Double]], oversample: Int = 4) -> Double {
        var peak = 0.0
        for channel in x {
            peak = max(peak, Resampler.peakOfUpsampled(channel, by: oversample))
        }
        return peak > 0 ? 20 * log10(peak) : -.infinity
    }
}
