import Foundation

/// Test signals, defined identically here and in `tools/make_golden.py`.
///
/// Defined rather than shipped. A few kilobytes of expected values travel
/// better than megabytes of audio, and -- more usefully -- the fixtures are
/// checked first, so a disagreement about the INPUT is caught before it can
/// be mistaken for a disagreement about the DSP.
public enum Fixtures {

    public static let rate = 48000.0

    /// xorshift64*, taken to a double in [-1, 1).
    ///
    /// Deliberately not a good generator and deliberately not the platform's:
    /// it has to produce the same stream in Swift as in Python, and
    /// `&*`/`&<<` here mean exactly what masking to 64 bits means there.
    public static func xorshift(seed: UInt64, count: Int) -> [Double] {
        var state = seed
        var out = [Double](); out.reserveCapacity(count)
        for _ in 0..<count {
            state ^= state >> 12
            state = state ^ (state << 25)
            state ^= state >> 27
            let value = state &* 0x2545F491_4F6CDD1D
            out.append(Double(value >> 11) / Double(1 << 53) * 2.0 - 1.0)
        }
        return out
    }

    static let tones: [(f: Double, a: Double, p: Double)] = [
        (55.0, 0.45, 0.0), (110.0, 0.30, 0.7), (330.0, 0.18, 1.9),
        (1480.0, 0.10, 2.6), (5200.0, 0.06, 0.4),
    ]

    public enum Kind: String, CaseIterable {
        case tones, programme, noise, quiet
    }

    /// Per-channel, matching the Python's column-stacked stereo.
    public static func make(_ kind: Kind, seconds: Double = 3.0) -> [[Double]] {
        let n = Int(seconds * rate)
        func t(_ i: Int) -> Double { Double(i) / rate }
        func toneSum(_ i: Int) -> Double {
            tones.reduce(0) { $0 + $1.a * sin(2 * .pi * $1.f * t(i) + $1.p) }
        }

        switch kind {
        case .tones:
            let mono = (0..<n).map(toneSum)
            return [mono, mono.map { $0 * 0.8 }]
        case .programme:
            let noise = xorshift(seed: 0x2BAD, count: n).map { $0 * 0.02 }
            let mono = (0..<n).map { toneSum($0) * (0.7 + 0.3 * sin(2 * .pi * 0.6 * t($0))) }
            return [(0..<n).map { mono[$0] + noise[$0] },
                    (0..<n).map { mono[$0] * 0.9 - noise[$0] }]
        case .noise:
            return [xorshift(seed: 1, count: n).map { $0 * 0.35 },
                    xorshift(seed: 2, count: n).map { $0 * 0.35 }]
        case .quiet:
            let mono = (0..<n).map { 0.001 * sin(2 * .pi * 220.0 * t($0)) }
            return [mono, mono]
        }
    }

    /// The fixture normalised and driven `overDB` past full scale, then hard
    /// clipped -- the de-clipper's input, with the truth still available.
    public static func clipped(_ kind: Kind, overDB: Double,
                               seconds: Double = 3.0) -> [[Double]] {
        var x = make(kind, seconds: seconds)
        let peak = x.flatMap { $0 }.map(abs).max() ?? 1
        let scale = pow(10, overDB / 20) / peak
        for c in x.indices {
            for i in x[c].indices { x[c][i] = min(max(x[c][i] * scale, -1), 1) }
        }
        return x
    }
}
