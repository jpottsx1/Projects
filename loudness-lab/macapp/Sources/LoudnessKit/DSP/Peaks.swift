import Foundation

/// `scipy.signal.find_peaks`, to the extent the kick detector uses it.
///
/// Ported rather than approximated because two of its details decide where
/// a sub burst lands. A plateau reports its MIDDLE sample, not its first,
/// and the minimum-distance rule keeps the tallest peak and discards its
/// neighbours rather than sweeping left to right -- so a slightly later but
/// stronger onset wins, which is usually the kick and not the thing before
/// it.
public enum Peaks {

    /// Indices of local maxima, plateaus reported at their midpoint.
    public static func localMaxima(_ x: [Double]) -> [Int] {
        var out: [Int] = []
        var i = 1
        let last = x.count - 1
        while i < last {
            if x[i - 1] < x[i] {
                var ahead = i + 1
                while ahead < last, x[ahead] == x[i] { ahead += 1 }
                if x[ahead] < x[i] {
                    out.append((i + ahead - 1) / 2)
                    i = ahead
                }
            }
            i += 1
        }
        return out
    }

    /// `find_peaks(x, height:, distance:)`.
    public static func find(_ x: [Double], height: Double?, distance: Int?) -> [Int] {
        var peaks = localMaxima(x)
        if let height { peaks = peaks.filter { x[$0] >= height } }
        guard let distance, distance > 1, peaks.count > 1 else { return peaks }

        // Tallest first; each survivor silences everything within `distance`.
        var keep = [Bool](repeating: true, count: peaks.count)
        let order = peaks.indices.sorted { x[peaks[$0]] < x[peaks[$1]] }
        for position in order.reversed() {
            guard keep[position] else { continue }
            var behind = position - 1
            while behind >= 0, peaks[position] - peaks[behind] < distance {
                keep[behind] = false; behind -= 1
            }
            var ahead = position + 1
            while ahead < peaks.count, peaks[ahead] - peaks[position] < distance {
                keep[ahead] = false; ahead += 1
            }
        }
        return zip(peaks, keep).filter { $0.1 }.map(\.0)
    }
}
