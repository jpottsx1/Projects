import Foundation

/// What a library actually looks like, without leaving the app.
///
/// This is the `report loudness` and `report lowend --by folder` pair from
/// the command line, which is where they have lived and which is why every
/// question about a folder has meant opening a terminal. The two things it
/// is for:
///
/// - **Clipping.** Whether de-clipping earns a lossy generation on this
///   material is a question about how much of it arrived already clipped.
/// - **Low end by folder.** A profile's caps are supposed to come from
///   measuring a corpus. Without this you cannot see what a corpus measures,
///   so a new profile would be a guess -- which is the one thing this
///   project keeps proving is not good enough.
public struct Survey: Sendable {

    public struct Clipping: Sendable {
        public var tracks = 0            // tracks carrying at least one run
        public var heavy = 0             // more than a hundred runs
        public var medianRuns = 0        // among those that have any
        public var worst: (name: String, runs: Int)?

        public var share: Double { measured == 0 ? 0 : Double(tracks) / Double(measured) }
        public var heavyShare: Double { measured == 0 ? 0 : Double(heavy) / Double(measured) }
        public internal(set) var measured = 0

        public init() {}
    }

    /// One row of "what would happen if I levelled to this".
    ///
    /// A negative gain is free. A positive gain eventually needs a limiter,
    /// which is the thing this project exists to avoid, so the useful target
    /// is the one where almost nothing is turned up.
    public struct TargetRow: Sendable, Identifiable {
        public let targetLUFS: Double
        public let needBoost: Double     // share of tracks, 0...1
        public let bigBoost: Double      // share needing more than +3 dB
        public let wouldExceedCeiling: Double
        public var id: Double { targetLUFS }
    }

    public struct FolderLowEnd: Sendable, Identifiable {
        public let folder: String
        public let tracks: Int
        /// Median shape per band, 31.5 to 63 Hz.
        public let curve: [Double: Double]
        /// Mean of the above -- one number to sort and compare folders on.
        public let mean: Double
        /// dB under the reference folder, when one was named.
        public var deficitVsReference: Double?
        public var id: String { folder }
    }

    public var measured = 0
    public var medianLUFSI: Double?
    public var medianSP95: Double?
    public var medianLRA: Double?
    public var medianTruePeak: Double?
    public var clipping = Clipping()
    public var targets: [TargetRow] = []
    public var folders: [FolderLowEnd] = []
    public var reference: String?

    public init() {}

    /// Built entirely from what the library already holds, so it costs a few
    /// queries rather than a re-measure.
    public static func of(_ library: Library, under roots: [URL] = [],
                          reference wanted: String? = nil,
                          peakCeiling: Double = -1.0) throws -> Survey {
        var survey = Survey()
        let rows = try library.tracks(under: roots)
        survey.measured = rows.count
        guard !rows.isEmpty else { return survey }

        survey.medianLUFSI = BS1770.percentile(rows.compactMap(\.lufsI), 50)
        survey.medianSP95 = BS1770.percentile(rows.compactMap(\.sP95), 50)
        survey.medianLRA = BS1770.percentile(rows.compactMap(\.lra), 50)
        survey.medianTruePeak = BS1770.percentile(rows.compactMap(\.truePeakDBTP), 50)

        // --- clipping ---
        var clipping = Clipping()
        clipping.measured = rows.count
        let withRuns = rows.filter { ($0.clipRuns ?? 0) > 0 }
        clipping.tracks = withRuns.count
        clipping.heavy = rows.filter { ($0.clipRuns ?? 0) > 100 }.count
        clipping.medianRuns = Int(BS1770.percentile(
            withRuns.map { Double($0.clipRuns ?? 0) }, 50) ?? 0)
        if let worst = withRuns.max(by: { ($0.clipRuns ?? 0) < ($1.clipRuns ?? 0) }) {
            clipping.worst = (worst.name, worst.clipRuns ?? 0)
        }
        survey.clipping = clipping

        // --- what levelling would cost, per target ---
        let levels = rows.compactMap { row -> (Double, Double)? in
            guard let value = row.sP95 ?? row.lufsI, value.isFinite else { return nil }
            return (value, row.truePeakDBTP ?? -.infinity)
        }
        if !levels.isEmpty {
            for target in stride(from: -10.0, through: -18.0, by: -2.0) {
                let gains = levels.map { (target - $0.0, $0.1) }
                let count = Double(gains.count)
                survey.targets.append(TargetRow(
                    targetLUFS: target,
                    needBoost: Double(gains.filter { $0.0 > 0 }.count) / count,
                    bigBoost: Double(gains.filter { $0.0 > 3 }.count) / count,
                    wouldExceedCeiling: Double(gains.filter {
                        $0.1.isFinite && $0.1 + $0.0 > peakCeiling
                    }.count) / count))
            }
        }

        // --- low end, by folder ---
        let curves = try library.referenceCurves()
        var counts: [String: Int] = [:]
        for row in rows {
            let folder = ((row.path as NSString).deletingLastPathComponent
                          as NSString).lastPathComponent
            counts[folder, default: 0] += 1
        }
        let referenceName = wanted.flatMap { Library.resolveReference(curves, $0) }
        survey.reference = referenceName
        let referenceCurve = referenceName.flatMap { curves[$0] }

        survey.folders = curves.compactMap { folder, curve in
            let values = Library.lowShapeBands.compactMap { curve[$0] }
            guard !values.isEmpty else { return nil }
            let mean = values.reduce(0, +) / Double(values.count)
            var row = FolderLowEnd(folder: folder, tracks: counts[folder] ?? 0,
                                   curve: curve, mean: mean, deficitVsReference: nil)
            if let referenceCurve, folder != referenceName {
                // Band by band, and only where both sides have the band --
                // averaging over a band one corpus does not have compares a
                // folder against a hole.
                let pairs = Library.lowShapeBands.compactMap { band -> Double? in
                    guard let mine = curve[band], let theirs = referenceCurve[band]
                    else { return nil }
                    return mine - theirs
                }
                if !pairs.isEmpty {
                    row.deficitVsReference = pairs.reduce(0, +) / Double(pairs.count)
                }
            }
            return row
        }
        .sorted { $0.mean < $1.mean }     // thinnest first, as everywhere else

        return survey
    }

    /// The same thing as text, for pasting into a note or a message.
    public func asText() -> String {
        var out = ["LIBRARY  (\(measured) tracks measured)", String(repeating: "=", count: 62), ""]
        func dB(_ value: Double?) -> String {
            value.map { String(format: "%.2f", $0) } ?? "--"
        }
        out += ["  median LUFS-I   \(dB(medianLUFSI))",
                "  median s_p95    \(dB(medianSP95))",
                "  median LRA      \(dB(medianLRA))",
                "  median peak     \(dB(medianTruePeak)) dBTP", ""]

        out += ["Masters that were already clipped", String(repeating: "-", count: 62),
                String(format: "  runs of consecutive full-scale samples: %d of %d (%.1f%%)",
                       clipping.tracks, measured, clipping.share * 100),
                String(format: "  more than 100 such runs:                %d (%.1f%%)",
                       clipping.heavy, clipping.heavyShare * 100)]
        if clipping.tracks > 0 {
            out.append("  median runs among those that have any:  \(clipping.medianRuns)")
        }
        if let worst = clipping.worst {
            out.append("  worst: \(worst.name) (\(worst.runs) runs)")
        }

        if !targets.isEmpty {
            out += ["", "How many tracks would need a BOOST", String(repeating: "-", count: 62),
                    "   target   need boost   > +3 dB   over ceiling"]
            for row in targets {
                out.append(String(format: "  %6.0f   %9.1f%%   %6.1f%%   %11.1f%%",
                                  row.targetLUFS, row.needBoost * 100,
                                  row.bigBoost * 100, row.wouldExceedCeiling * 100))
            }
        }

        if !folders.isEmpty {
            out += ["", "Low end by folder, 31.5-63 Hz"
                    + (reference.map { " (against \($0))" } ?? ""),
                    String(repeating: "-", count: 62),
                    "   tracks   mean    vs ref   folder"]
            for row in folders {
                let versus = row.deficitVsReference.map { String(format: "%+7.2f", $0) }
                    ?? "      -"
                out.append(String(format: "  %6d  %+6.2f  %@   %@",
                                  row.tracks, row.mean, versus, row.folder))
            }
        }
        return out.joined(separator: "\n")
    }
}
