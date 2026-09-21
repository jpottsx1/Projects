import Foundation

/// Putting back peaks that were clipped before the file reached us.
///
/// A port of `loudnesslab/declip.py`. The method and every constant come
/// from there, along with the evidence for them; this comment does not
/// repeat it, but two things are worth restating because they govern the
/// code rather than just explaining it.
///
/// It is self-limiting. On a genuine clipped peak the arc lands within
/// 0.13 dB of the true peak; on a bass note that merely touched full scale,
/// the shoulders are already turning over, so the arc drawn through them is
/// the peak that is already there and the audio moves by less than a
/// millionth of full scale. A false detection therefore costs nothing, which
/// is the only basis on which this is safe to run across a library.
///
/// And it returns audio that may exceed full scale, because a restored peak
/// is taller than the ceiling it hit. The caller owns making room.
public enum Declip {

    public static let clipThreshold = 0.9995
    public static let mergeTolerance = 0.0002
    public static let minRun = 2
    public static let shoulder = 3
    public static let maxRunMS = 10.0
    public static let maxRestoreDB = 6.0

    public struct Report: Sendable {
        public var runs = 0
        public var restored = 0
        public var samples = 0
        public var flattened = 0
        public var tooLong = 0
        public var atEdge = 0
        public var shoulderClipped = 0
        public var nothingToAdd = 0
        public var liftDB = 0.0
        public var liftMaxDB = 0.0
        public var peakChangeDB = 0.0
        public var headroomDB = 0.0
        public var peakBeforeDBFS = -Double.infinity
        public var peakAfterDBFS = -Double.infinity

        public var refused: Int { tooLong + atEdge + shoulderClipped + nothingToAdd }

        /// Spelled out because a public struct's implicit initialiser is
        /// internal, so another module cannot make one without this however
        /// public its properties are.
        public init() {}
    }

    public struct Run: Equatable, Sendable {
        public let start: Int, end: Int, sign: Int
    }

    // MARK: - Detection

    /// Spans of samples pinned at the ceiling. Positive and negative are found
    /// separately, so one can never straddle a sign change and be handed to
    /// the arc as a single peak.
    public static func findRuns(_ channel: [Double],
                                threshold: Double = clipThreshold,
                                minRun: Int = minRun,
                                mergeGap: Int = shoulder) -> [Run] {
        var out: [Run] = []
        for sign in [1, -1] {
            let raw = spans(channel, sign: sign, threshold: threshold, minRun: minRun)
            for (start, end) in merge(raw, channel, sign: sign, gap: mergeGap,
                                      floor: threshold - mergeTolerance) {
                out.append(Run(start: start, end: end, sign: sign))
            }
        }
        return out.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    static func spans(_ channel: [Double], sign: Int, threshold: Double,
                      minRun: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var start: Int?
        for i in channel.indices {
            let above = channel[i] * Double(sign) >= threshold
            if above, start == nil { start = i }
            if !above, let began = start {
                if i - began >= minRun { out.append((began, i)) }
                start = nil
            }
        }
        if let began = start, channel.count - began >= minRun {
            out.append((began, channel.count))
        }
        return out
    }

    /// Join runs a sample or two apart, but only across a sample that is
    /// itself within a handful of 16-bit steps of the ceiling.
    ///
    /// The tolerance is tight on evidence, not taste. A sample below the
    /// threshold was never clipped, so it is the truth, and arcing over it
    /// replaces a measurement with a guess; joining freely raised the count
    /// of runs restored and made the result worse. See declip.py for the
    /// table this was chosen from.
    static func merge(_ runs: [(Int, Int)], _ channel: [Double], sign: Int,
                      gap: Int, floor: Double) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for run in runs {
            if let last = out.last, run.0 - last.1 < gap {
                let between = (last.1..<run.0).map { channel[$0] * Double(sign) }
                if between.isEmpty || between.allSatisfy({ $0 >= floor }) {
                    out[out.count - 1] = (last.0, run.1)
                    continue
                }
            }
            out.append(run)
        }
        return out
    }

    // MARK: - Restoration

    public static func restore(_ x: [[Double]], rate: Double,
                               threshold: Double = clipThreshold,
                               maxRestoreDB: Double = maxRestoreDB,
                               shoulder: Int = shoulder,
                               maxRunMS: Double = maxRunMS,
                               minRun: Int = minRun) -> (audio: [[Double]], report: Report) {
        precondition(shoulder >= 2, "a shoulder needs at least two samples for a slope")
        var report = Report()
        var lifts: [Double] = []
        var out = x
        var changed = false

        for channel in x.indices {
            if restoreChannel(&out[channel], rate: rate, report: &report,
                              lifts: &lifts, threshold: threshold,
                              maxRestoreDB: maxRestoreDB, shoulder: shoulder,
                              maxRunMS: maxRunMS, minRun: minRun) {
                changed = true
            }
        }

        let before = x.flatMap { $0 }.map(abs).max() ?? 0
        let after = changed ? (out.flatMap { $0 }.map(abs).max() ?? 0) : before
        report.peakBeforeDBFS = before > 0 ? 20 * log10(before) : -.infinity
        report.peakAfterDBFS = after > 0 ? 20 * log10(after) : -.infinity
        // The lift is measured over the RUNS, not over the file's peak: an
        // MP3 of a clipped master decodes with overshoot, so its tallest
        // sample sits above everything the arcs reach and never moves.
        report.liftDB = BS1770.percentile(lifts, 50) ?? 0
        report.liftMaxDB = lifts.max() ?? 0
        report.peakChangeDB = (before > 0 && after > 0) ? 20 * log10(after / before) : 0
        report.headroomDB = after > 1 ? 20 * log10(after) : 0
        return (changed ? out : x, report)
    }

    static func restoreChannel(_ channel: inout [Double], rate: Double,
                               report: inout Report, lifts: inout [Double],
                               threshold: Double, maxRestoreDB: Double,
                               shoulder: Int, maxRunMS: Double,
                               minRun: Int) -> Bool {
        let original = channel
        let runs = findRuns(original, threshold: threshold, minRun: minRun,
                            mergeGap: shoulder)
        // Which samples belong to a run, so a shoulder is judged against the
        // runs rather than the raw threshold. A lone sample grazing the
        // ceiling is not a flat top and must not veto its neighbour.
        var damaged = [Bool](repeating: false, count: original.count)
        for run in runs { for i in run.start..<run.end { damaged[i] = true } }

        let longest = max(minRun, Int(maxRunMS * rate / 1000))
        var changed = false

        for run in runs {
            report.runs += 1
            let length = run.end - run.start
            if length > longest { report.tooLong += 1; continue }

            let before = run.start - 1, after = run.end
            guard before - shoulder + 1 >= 0, after + shoulder <= original.count else {
                report.atEdge += 1; continue
            }
            let leftRange = (before - shoulder + 1)...before
            let rightRange = after..<(after + shoulder)
            if leftRange.contains(where: { damaged[$0] })
                || rightRange.contains(where: { damaged[$0] }) {
                report.shoulderClipped += 1; continue
            }

            // A peak climbs into its run and drops out of it. Where a shoulder
            // does not, its slope is dropped rather than the run refused; with
            // both dropped the arc flattens to a line and falls out below as
            // nothing to add, so the degenerate case refuses itself.
            var rising = slope(Array(original[leftRange]), atEnd: true)
            var falling = slope(Array(original[rightRange]), atEnd: false)
            let sign = Double(run.sign)
            if rising * sign <= 0 || falling * sign >= 0 {
                if rising * sign <= 0 { rising = 0 }
                if falling * sign >= 0 { falling = 0 }
                report.flattened += 1
            }

            let arc = hermite(width: after - before, yA: original[before], mA: rising,
                              yB: original[after], mB: falling, count: length)
            // Clipping can only have made a sample smaller, so the truth is at
            // least what survived: work in the excess over what is there.
            let signed = (run.start..<run.end).map { original[$0] * sign }
            var excess = zip(arc, signed).map { max($0 * sign - $1, 0) }
            guard let largest = excess.max(), largest > 0 else {
                report.nothingToAdd += 1; continue
            }

            let peak = signed.max() ?? 0
            let ceiling = peak * pow(10, maxRestoreDB / 20)
            let reached = zip(signed, excess).map(+).max() ?? peak
            if reached > ceiling, reached > peak {
                let scale = (ceiling - peak) / (reached - peak)
                for i in excess.indices { excess[i] *= scale }
            }
            for i in excess.indices { excess[i] = min(excess[i], max(ceiling - signed[i], 0)) }

            // Added to the sample rather than replacing it, so restoration can
            // only ever move away from zero.
            for (offset, add) in excess.enumerated() {
                channel[run.start + offset] = original[run.start + offset] + sign * add
            }
            if peak > 0 {
                let top = zip(signed, excess).map(+).max() ?? peak
                lifts.append(20 * log10(top / peak))
            }
            report.restored += 1
            report.samples += length
            changed = true
        }
        return changed
    }

    /// Slope per sample at the outer end of a shoulder: a quadratic through
    /// it, differentiated. At the default three samples this is exactly the
    /// three-point derivative; a wider shoulder smooths it.
    static func slope(_ values: [Double], atEnd: Bool) -> Double {
        let n = values.count
        guard n >= 2 else { return 0 }
        if n == 2 { return values[1] - values[0] }
        // Least-squares quadratic, then its derivative at the outer sample.
        let xs = (0..<n).map(Double.init)
        let fit = quadraticFit(xs, values)
        let at = atEnd ? Double(n - 1) : 0
        return 2 * fit.0 * at + fit.1
    }

    /// Returns (a, b, c) of a*x^2 + b*x + c by normal equations. Three points
    /// interpolate exactly, which is the default and the case that matters.
    static func quadraticFit(_ xs: [Double], _ ys: [Double]) -> (Double, Double, Double) {
        var s = [Double](repeating: 0, count: 5)
        var t = [Double](repeating: 0, count: 3)
        for (x, y) in zip(xs, ys) {
            var power = 1.0
            for k in 0..<5 { s[k] += power; power *= x }
            t[0] += y; t[1] += y * x; t[2] += y * x * x
        }
        // Solve the 3x3 system [[s4,s3,s2],[s3,s2,s1],[s2,s1,s0]] [a,b,c] = [t2,t1,t0].
        let m = [[s[4], s[3], s[2]], [s[3], s[2], s[1]], [s[2], s[1], s[0]]]
        let rhs = [t[2], t[1], t[0]]
        guard let solved = solve3(m, rhs) else { return (0, 0, 0) }
        return (solved[0], solved[1], solved[2])
    }

    static func solve3(_ m: [[Double]], _ rhs: [Double]) -> [Double]? {
        var a = m, b = rhs
        for column in 0..<3 {
            var pivot = column
            for row in column..<3 where abs(a[row][column]) > abs(a[pivot][column]) {
                pivot = row
            }
            guard abs(a[pivot][column]) > 1e-300 else { return nil }
            a.swapAt(column, pivot); b.swapAt(column, pivot)
            for row in 0..<3 where row != column {
                let factor = a[row][column] / a[column][column]
                for k in column..<3 { a[row][k] -= factor * a[column][k] }
                b[row] -= factor * b[column]
            }
        }
        return (0..<3).map { b[$0] / a[$0][$0] }
    }

    /// Cubic Hermite across a gap, at its interior points. Matching value AND
    /// slope at both shoulders is the point: a least-squares fit through the
    /// surrounding samples would leave a step at each end, and a step in a
    /// waveform is a click.
    static func hermite(width: Int, yA: Double, mA: Double, yB: Double,
                        mB: Double, count: Int) -> [Double] {
        let w = Double(width)
        return (1...max(count, 1)).prefix(count).map { index -> Double in
            let u = Double(index) / w
            let u2 = u * u, u3 = u2 * u
            return (2 * u3 - 3 * u2 + 1) * yA
                + (u3 - 2 * u2 + u) * w * mA
                + (-2 * u3 + 3 * u2) * yB
                + (u3 - u2) * w * mB
        }
    }
}
