import Foundation

/// Cascaded second-order sections, and the two ways to run audio through them.
///
/// The coefficients are not designed here. Every filter this project uses has
/// a fixed order and fixed corner frequencies, so they are generated once by
/// scipy and shipped in `FilterBank` -- which removes a Butterworth
/// prototype, a frequency transform, a bilinear transform and scipy's own
/// pole-zero pairing from the list of things that could be ported wrongly,
/// none of which the app needs to be able to do while it is running.
///
/// What IS implemented here is the running: the direct-form-II transposed
/// recursion, the steady-state initial conditions, and the forward-backward
/// pass. Those are algorithms rather than numbers, and they have to match.
public struct SOS: Sendable {

    /// One section: b0, b1, b2, a0, a1, a2, in scipy's layout, a0 normalised.
    public struct Section: Sendable {
        public let b0, b1, b2, a1, a2: Double

        public init(_ c: [Double]) {
            precondition(c.count == 6, "a section is six coefficients")
            let a0 = c[3]
            b0 = c[0] / a0; b1 = c[1] / a0; b2 = c[2] / a0
            a1 = c[4] / a0; a2 = c[5] / a0
        }
    }

    public let sections: [Section]

    public init(_ rows: [[Double]]) { sections = rows.map(Section.init) }

    // MARK: - Causal

    /// Direct form II transposed, section by section. `state` carries the two
    /// delays per section so a signal can be filtered in pieces.
    public func filter(_ x: [Double], state: inout [(Double, Double)]) -> [Double] {
        var out = x
        for (index, s) in sections.enumerated() {
            var z1 = state[index].0
            var z2 = state[index].1
            for i in out.indices {
                let input = out[i]
                let y = s.b0 * input + z1
                z1 = s.b1 * input - s.a1 * y + z2
                z2 = s.b2 * input - s.a2 * y
                out[i] = y
            }
            state[index] = (z1, z2)
        }
        return out
    }

    public func filter(_ x: [Double]) -> [Double] {
        var state = zeroState()
        return filter(x, state: &state)
    }

    public func zeroState() -> [(Double, Double)] {
        Array(repeating: (0.0, 0.0), count: sections.count)
    }

    // MARK: - Zero phase

    /// Forward then backward, so the result has no phase shift at all.
    ///
    /// This distinction is not cosmetic in this project and has caused real
    /// bugs: a band taken out causally cannot be added back without leaving a
    /// phase-shifted residue, so `x - band` fails to cancel and a transient
    /// shaper quietly becomes an equaliser. Anything that splits a signal and
    /// recombines it has to use this.
    ///
    /// Follows scipy's `sosfiltfilt`: odd-extend both ends by
    /// `3 * (2 * sections + 1)` samples (less any section without a second
    /// numerator or denominator term), start each pass from the steady state
    /// scaled by the first sample so the filter does not have to charge up,
    /// and trim the extension off at the end.
    public func filtfilt(_ x: [Double]) -> [Double] {
        let edge = padLength
        guard x.count > edge else { return x }

        let extended = SOS.oddExtend(x, by: edge)
        let zi = steadyState()

        var state = zi.map { ($0.0 * extended[0], $0.1 * extended[0]) }
        var forward = filter(extended, state: &state)

        forward.reverse()
        let last = forward[0]
        var backState = zi.map { ($0.0 * last, $0.1 * last) }
        var backward = filter(forward, state: &backState)
        backward.reverse()

        return Array(backward[edge..<(backward.count - edge)])
    }

    /// scipy counts a section with a zero b2 or a zero a2 as shorter, so the
    /// pad shrinks for first-order sections carried in a biquad's clothing.
    var padLength: Int {
        let zeroB2 = sections.filter { $0.b2 == 0 }.count
        let zeroA2 = sections.filter { $0.a2 == 0 }.count
        let taps = 2 * sections.count + 1 - min(zeroB2, zeroA2)
        return 3 * taps
    }

    /// Reflect each end through its endpoint: 2*x[0] - x[k]. Padding with
    /// zeros instead would make the filter charge from silence into the
    /// signal, and the transient that causes lands inside the audio.
    static func oddExtend(_ x: [Double], by edge: Int) -> [Double] {
        guard edge > 0, x.count > edge else { return x }
        var out = [Double]()
        out.reserveCapacity(x.count + 2 * edge)
        let first = x[0], last = x[x.count - 1]
        for k in stride(from: edge, through: 1, by: -1) { out.append(2 * first - x[k]) }
        out.append(contentsOf: x)
        for k in 2...(edge + 1) { out.append(2 * last - x[x.count - k]) }
        return out
    }

    /// The state a section settles into for a constant input of 1, scaled
    /// through the cascade by each earlier section's DC gain -- scipy's
    /// `sosfilt_zi`.
    func steadyState() -> [(Double, Double)] {
        var scale = 1.0
        var out: [(Double, Double)] = []
        out.reserveCapacity(sections.count)
        for s in sections {
            // Solve (I - A) z = B for the transposed companion form.
            let determinant = 1 + s.a1 + s.a2
            guard abs(determinant) > 1e-300 else { out.append((0, 0)); continue }
            let b1 = s.b1 - s.a1 * s.b0
            let b2 = s.b2 - s.a2 * s.b0
            let z0 = (b1 + b2) / determinant
            let z1 = ((1 + s.a1) * b2 - s.a2 * b1) / determinant
            out.append((scale * z0, scale * z1))
            scale *= (s.b0 + s.b1 + s.b2) / (1 + s.a1 + s.a2)
        }
        return out
    }
}
