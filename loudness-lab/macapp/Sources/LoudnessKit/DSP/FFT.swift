import Foundation

/// Iterative radix-2 FFT, used by the 1/3-octave analysis.
///
/// Deliberately plain. Accelerate's vDSP would be several times faster, but
/// its real-FFT packing -- Nyquist folded into the imaginary part of bin
/// zero, and a scaling convention that differs from numpy's -- is exactly
/// the kind of detail that is easy to get subtly wrong and hard to notice,
/// and the golden vectors are worth more here than the speed. This is the
/// hot spot if analysis ever feels slow; swap it then, with the tests to
/// say whether the swap was right.
public enum FFT {

    /// In-place forward transform. `count` must be a power of two.
    public static func forward(real: inout [Double], imaginary: inout [Double]) {
        let n = real.count
        precondition(n == imaginary.count, "real and imaginary must match")
        precondition(n > 0 && (n & (n - 1)) == 0, "length must be a power of two")
        guard n > 1 else { return }

        // Bit-reversal permutation.
        var target = 0
        for source in 0..<(n - 1) {
            if source < target {
                real.swapAt(source, target)
                imaginary.swapAt(source, target)
            }
            var mask = n >> 1
            while target & mask != 0 {
                target &= ~mask
                mask >>= 1
            }
            target |= mask
        }

        var span = 1
        while span < n {
            let step = span << 1
            let theta = -Double.pi / Double(span)
            for group in 0..<span {
                let angle = theta * Double(group)
                let wr = cos(angle), wi = sin(angle)
                var index = group
                while index < n {
                    let pair = index + span
                    let tr = wr * real[pair] - wi * imaginary[pair]
                    let ti = wr * imaginary[pair] + wi * real[pair]
                    real[pair] = real[index] - tr
                    imaginary[pair] = imaginary[index] - ti
                    real[index] += tr
                    imaginary[index] += ti
                    index += step
                }
            }
            span = step
        }
    }

    /// Magnitude squared of bins 0...n/2 of a real signal -- what `numpy`'s
    /// `rfft` gives, squared. The one-sided doubling is left to the caller,
    /// because whether DC and Nyquist are doubled is a decision about the
    /// measurement rather than about the transform.
    public static func powerSpectrum(_ x: [Double]) -> [Double] {
        var real = x
        var imaginary = [Double](repeating: 0, count: x.count)
        forward(real: &real, imaginary: &imaginary)
        let bins = x.count / 2 + 1
        return (0..<bins).map { real[$0] * real[$0] + imaginary[$0] * imaginary[$0] }
    }
}
