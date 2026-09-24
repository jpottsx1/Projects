import Foundation
import Accelerate

/// The 1/3-octave analysis's transform.
///
/// This used to be a plain radix-2 loop, with a note saying it was the hot
/// spot to swap when analysis felt slow, and to do it with the tests
/// saying whether the swap was right. Analysis felt slow. At nfft = 32768
/// that loop called `cos` and `sin` once per butterfly group per stage --
/// a quarter of a million transcendental calls per frame, and something
/// like half a billion per track.
///
/// It now goes through vDSP. The packing its real FFT uses is the thing
/// that note was wary of: Nyquist is folded into the imaginary part of bin
/// zero, and the output carries a factor of two that numpy's `rfft` does
/// not. Both are handled in `Plan.powerSpectrum`, and the old loop is kept
/// below so a test can hold the new one to it rather than take it on
/// trust.
public enum FFT {

    /// A reusable transform of one size.
    ///
    /// vDSP wants a setup object built once -- it holds the twiddle tables,
    /// which is precisely the work the old loop was redoing per frame. One
    /// of these is made per channel per track and used for every frame, so
    /// the tables are computed once rather than a thousand times, and the
    /// scratch buffers are allocated once rather than per frame.
    ///
    /// Not shared between threads: each call to `framePower` makes its own,
    /// which keeps concurrent analysis free of any question about whether a
    /// setup may be used from two places at once.
    public final class Plan {
        let setup: FFTSetupD
        let n: Int
        let log2n: vDSP_Length
        var realPart: [Double]
        var imaginaryPart: [Double]

        public init?(size n: Int) {
            guard n > 1, (n & (n - 1)) == 0 else { return nil }
            let log2n = vDSP_Length(log2(Double(n)).rounded())
            guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))
            else { return nil }
            self.setup = setup
            self.n = n
            self.log2n = log2n
            self.realPart = [Double](repeating: 0, count: n / 2)
            self.imaginaryPart = [Double](repeating: 0, count: n / 2)
        }

        deinit { vDSP_destroy_fftsetupD(setup) }

        /// Magnitude squared of bins 0...n/2, matching `FFT.powerSpectrum`.
        public func powerSpectrum(_ x: [Double]) -> [Double] {
            precondition(x.count == n, "signal length must match the plan")
            var out = [Double](repeating: 0, count: n / 2 + 1)
            let half = n / 2

            realPart.withUnsafeMutableBufferPointer { realBuffer in
                imaginaryPart.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPDoubleSplitComplex(
                        realp: realBuffer.baseAddress!,
                        imagp: imaginaryBuffer.baseAddress!)

                    // Even samples to the real part, odd to the imaginary:
                    // a real signal of length n transformed as n/2 complex
                    // points, which is the whole reason the real FFT is
                    // faster than the general one.
                    x.withUnsafeBytes { raw in
                        let complex = raw.bindMemory(to: DSPDoubleComplex.self)
                        vDSP_ctozD(complex.baseAddress!, 2, &split, 1,
                                   vDSP_Length(half))
                    }
                    vDSP_fft_zripD(setup, &split, 1, log2n,
                                   FFTDirection(FFT_FORWARD))

                    // vDSP scales its forward real transform by two, and
                    // folds Nyquist into the imaginary part of bin zero.
                    // Undo both, so these are numpy's numbers.
                    let dc = realBuffer[0] * 0.5
                    let nyquist = imaginaryBuffer[0] * 0.5
                    out[0] = dc * dc
                    out[half] = nyquist * nyquist
                    for k in 1..<half {
                        let re = realBuffer[k] * 0.5
                        let im = imaginaryBuffer[k] * 0.5
                        out[k] = re * re + im * im
                    }
                }
            }
            return out
        }
    }

    /// In-place forward transform. `count` must be a power of two.
    ///
    /// The original. Kept because `Plan` is held to it by a test: an
    /// optimisation nobody can check is a rewrite.
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
        if let plan = Plan(size: x.count) { return plan.powerSpectrum(x) }
        return powerSpectrumScalar(x)
    }

    /// The old path, straight through the radix-2 loop above.
    static func powerSpectrumScalar(_ x: [Double]) -> [Double] {
        var real = x
        var imaginary = [Double](repeating: 0, count: x.count)
        forward(real: &real, imaginary: &imaginary)
        let bins = x.count / 2 + 1
        return (0..<bins).map { real[$0] * real[$0] + imaginary[$0] * imaginary[$0] }
    }
}
