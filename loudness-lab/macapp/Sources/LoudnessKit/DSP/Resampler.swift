import Foundation
import Accelerate

/// Integer upsampling, for true-peak detection only.
///
/// A port of what `scipy.signal.resample_poly` does by default, because that
/// is what the reference implementation calls: a Kaiser-windowed FIR at
/// `10 * rate` taps each side, cutoff at the new Nyquist, applied
/// polyphase. The filter is reproduced rather than approximated so the
/// number this yields is the number the Python yields.
///
/// Only the peak is ever wanted, so nothing keeps the upsampled signal --
/// it is walked one output sample at a time and the largest magnitude
/// retained. A twelve-minute mix at 4x would otherwise be a gigabyte.
public enum Resampler {

    /// scipy: `half_len = 10 * max(up, down)`, cutoff `1 / max(up, down)`,
    /// Kaiser beta 5.0, then scaled by `up`.
    public static func polyphaseFIR(up: Int) -> [Double] {
        let halfLength = 10 * up
        let taps = 2 * halfLength + 1
        let cutoff = 1.0 / Double(up)
        var h = firwin(taps: taps, cutoff: cutoff, beta: 5.0)
        for i in h.indices { h[i] *= Double(up) }
        return h
    }

    /// A windowed ideal low-pass, normalised to unity gain at DC -- the
    /// `pass_zero` case of scipy's `firwin`, which is the only one needed.
    /// `cutoff` is a fraction of Nyquist.
    static func firwin(taps: Int, cutoff: Double, beta: Double) -> [Double] {
        let alpha = 0.5 * Double(taps - 1)
        let window = kaiser(taps: taps, beta: beta)
        var h = (0..<taps).map { index -> Double in
            let m = Double(index) - alpha
            return cutoff * sinc(cutoff * m) * window[index]
        }
        let sum = h.reduce(0, +)
        if sum != 0 { for i in h.indices { h[i] /= sum } }
        return h
    }

    static func sinc(_ x: Double) -> Double {
        x == 0 ? 1.0 : sin(.pi * x) / (.pi * x)
    }

    static func kaiser(taps: Int, beta: Double) -> [Double] {
        guard taps > 1 else { return [1.0] }
        let alpha = Double(taps - 1) / 2
        let denominator = besselI0(beta)
        return (0..<taps).map { index in
            let ratio = (Double(index) - alpha) / alpha
            let inside = max(0, 1 - ratio * ratio)
            return besselI0(beta * inside.squareRoot()) / denominator
        }
    }

    /// Modified Bessel function of the first kind, order zero, by its series.
    /// The argument never exceeds the Kaiser beta, so this converges quickly.
    static func besselI0(_ x: Double) -> Double {
        var term = 1.0, sum = 1.0
        let half = x / 2
        for k in 1...40 {
            term *= (half / Double(k)) * (half / Double(k))
            sum += term
            if term < sum * 1e-18 { break }
        }
        return sum
    }

    /// Largest magnitude of `x` upsampled by `up`, without building it.
    /// The true peak, without ever holding the upsampled signal.
    ///
    /// This was the slowest thing in the app by a wide margin: measuring a
    /// six-minute track meant about 1.3 billion multiply-adds per channel,
    /// written as a scalar loop with a bounds check on every one. Accelerate
    /// does the same arithmetic vectorised.
    ///
    /// The arithmetic really is the same, and that is checkable rather than
    /// asserted: `peakOfUpsampledScalar` below is the original, kept so a
    /// test can hold this to it. If the two ever disagree, this is wrong.
    public static func peakOfUpsampled(_ x: [Double], by up: Int) -> Double {
        guard up > 1 else { return x.map(abs).max() ?? 0 }
        guard !x.isEmpty else { return 0 }

        let phases = polyphase(up: up)
        let count = x.count
        // Blocked, so memory stays flat whatever the track length. The
        // original comment still applies -- a twelve-minute mix upsampled
        // four times would be a gigabyte -- and a block plus its history is
        // half a megabyte.
        let block = 1 << 16
        var peak = 0.0

        for phase in phases {
            // vDSP correlates; convolution is correlation against the
            // reversed taps, reversed once here rather than per sample.
            let taps = Array(phase.reversed())
            let width = taps.count
            guard width > 0 else { continue }

            var padded = [Double](repeating: 0, count: block + width - 1)
            var out = [Double](repeating: 0, count: block)
            var start = 0

            while start < count {
                let n = min(block, count - start)
                // The `width - 1` input samples before this block, zero
                // before the signal begins -- the same zero padding the
                // scalar version did, so the edges still agree with scipy.
                for i in 0..<(width - 1) {
                    let source = start - (width - 1) + i
                    padded[i] = source >= 0 ? x[source] : 0
                }
                for i in 0..<n { padded[width - 1 + i] = x[start + i] }

                padded.withUnsafeBufferPointer { a in
                    taps.withUnsafeBufferPointer { b in
                        out.withUnsafeMutableBufferPointer { c in
                            vDSP_convD(a.baseAddress!, 1, b.baseAddress!, 1,
                                       c.baseAddress!, 1,
                                       vDSP_Length(n), vDSP_Length(width))
                        }
                    }
                }
                var largest = 0.0
                out.withUnsafeBufferPointer { c in
                    vDSP_maxmgvD(c.baseAddress!, 1, &largest, vDSP_Length(n))
                }
                peak = max(peak, largest)
                start += n
            }
        }
        return peak
    }

    /// One set of taps per output position within an input sample.
    static func polyphase(up: Int) -> [[Double]] {
        let h = polyphaseFIR(up: up)
        var phases: [[Double]] = Array(repeating: [], count: up)
        for (index, tap) in h.enumerated() { phases[index % up].append(tap) }
        return phases
    }

    /// The original, one output sample at a time. Kept only so the fast one
    /// can be held to it -- an optimisation nobody can check is a rewrite.
    static func peakOfUpsampledScalar(_ x: [Double], by up: Int) -> Double {
        guard up > 1 else { return x.map(abs).max() ?? 0 }
        guard !x.isEmpty else { return 0 }
        let phases = polyphase(up: up)
        var peak = 0.0
        let count = x.count
        for m in 0..<(count * up) {
            let taps = phases[m % up]
            let base = m / up
            var accumulator = 0.0
            let highest = min(taps.count - 1, base)
            if highest >= 0 {
                for j in 0...highest { accumulator += taps[j] * x[base - j] }
            }
            peak = max(peak, abs(accumulator))
        }
        return peak
    }
}
