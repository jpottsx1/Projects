import Foundation

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
    public static func peakOfUpsampled(_ x: [Double], by up: Int) -> Double {
        guard up > 1 else { return x.map(abs).max() ?? 0 }
        guard !x.isEmpty else { return 0 }
        let h = polyphaseFIR(up: up)

        // One phase of the filter per output position within an input sample.
        var phases: [[Double]] = Array(repeating: [], count: up)
        for (index, tap) in h.enumerated() { phases[index % up].append(tap) }

        var peak = 0.0
        let count = x.count
        for m in 0..<(count * up) {
            let phase = m % up
            let base = m / up
            let taps = phases[phase]
            var accumulator = 0.0
            // Zero outside the signal, which is what a convolution does at the
            // ends and what scipy does too, so the edges agree as well.
            let highest = min(taps.count - 1, base)
            if highest >= 0 {
                for j in 0...highest { accumulator += taps[j] * x[base - j] }
            }
            peak = max(peak, abs(accumulator))
        }
        return peak
    }
}
