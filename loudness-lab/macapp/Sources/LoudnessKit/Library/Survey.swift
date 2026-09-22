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
        /// Tracks in this folder carrying clipped runs.
        ///
        /// Per folder rather than only per library, because the library
        /// figure hides exactly what matters: a 2003 disco reissue measured
        /// 53% clipped while the library it sits in averaged 13.6%. Whether
        /// a profile de-clips by default is a question about the material
        /// that profile is for, and an average over everything else cannot
        /// answer it.
        public var clipped = 0
        public var clippedShare: Double {
            tracks == 0 ? 0 : Double(clipped) / Double(tracks)
        }

        /// Median loudness range, per folder.
        ///
        /// How far apart the quiet parts and the loud parts sit -- the
        /// number that says whether a record has drops or just has volume.
        /// Classical runs 15 to 20, a well-mastered pop record 8 to 10,
        /// loudness-war pop 4 to 6.
        ///
        /// Here because restoring dynamics is the one thing a reference
        /// folder cannot help with: modern masters are the MOST compressed,
        /// so there is no folder to aim at. It needs an absolute target,
        /// and this is the measurement that would set one.
        public var lra: Double?
        /// Median crest, per folder: true peak minus integrated loudness,
        /// the peak-to-loudness ratio.
        ///
        /// The OTHER half of "over-compressed", and a different injury from
        /// the one LRA describes. LRA is what a slow compressor took out
        /// over bars; this is what a fast limiter took out over
        /// milliseconds. A record limited hard measures 8 to 11 dB, one
        /// that was not measures 13 and up.
        ///
        /// Both are needed because a folder can be short of one and not the
        /// other, and the stage that repairs one does nothing for the
        /// other. Reading only LRA would have the attack stage set from a
        /// number that says nothing about attacks.
        public var crest: Double?
        /// Median shape per band, 31.5 to 63 Hz.
        public let curve: [Double: Double]
        /// Mean of the above -- one number to sort and compare folders on.
        public let mean: Double
        /// dB under the reference folder, when one was named.
        public var deficitVsReference: Double?

        /// The same, 8 to 16 kHz -- what an "air" stage would work on.
        ///
        /// Measured before being offered, because a high shelf can only
        /// lift what is there. Where an MP3's low-pass has already removed
        /// the top, a deficit is the codec being described rather than the
        /// master, and boosting it raises noise and nothing else. Which is
        /// why the bands are carried individually as well as averaged: a
        /// cliff between 12.5 and 16 kHz is the codec, a gentle slope is
        /// the record.
        public var topCurve: [Double: Double] = [:]
        public var topMean: Double = .nan
        public var topDeficitVsReference: Double?

        public var id: String { folder }
    }

    public var measured = 0
    public var medianLUFSI: Double?
    public var medianSP95: Double?
    public var medianLRA: Double?
    public var medianCrest: Double?
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
        survey.medianCrest = BS1770.percentile(rows.compactMap(\.crestDB), 50)
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
        let tops = try library.curves(bands: Library.topShapeBands)
        // Counted across the WHOLE library, not just the selected folders,
        // because the curves are: `referenceCurves` has no root filter, and
        // it should not have one -- naming a reference folder measured in an
        // earlier pass is the normal case, not an edge one. Counting only
        // the selection would show those folders with zero tracks.
        //
        // Labelled the same way the curves were grouped, or a track count
        // would end up beside another folder's measurements.
        let everything = try library.tracks()
        let labels = Library.folderLabels(everything.map(\.path))
        var counts: [String: Int] = [:]
        var clipped: [String: Int] = [:]
        var ranges: [String: [Double]] = [:]
        var crests: [String: [Double]] = [:]
        for row in everything {
            let label = labels[row.path] ?? "(root)"
            counts[label, default: 0] += 1
            if (row.clipRuns ?? 0) > 0 { clipped[label, default: 0] += 1 }
            if let lra = row.lra, lra.isFinite { ranges[label, default: []].append(lra) }
            if let crest = row.crestDB, crest.isFinite {
                crests[label, default: []].append(crest)
            }
        }
        let referenceName = wanted.flatMap { Library.resolveReference(curves, $0) }
        survey.reference = referenceName
        let referenceCurve = referenceName.flatMap { curves[$0] }
        let referenceTop = referenceName.flatMap { tops[$0] }

        /// Mean of the bands both sides actually have. Averaging over a band
        /// one corpus is missing compares a folder against a hole.
        func gap(_ mine: [Double: Double], _ theirs: [Double: Double],
                 _ bands: [Double]) -> Double? {
            let pairs = bands.compactMap { band -> Double? in
                guard let a = mine[band], let b = theirs[band] else { return nil }
                return a - b
            }
            return pairs.isEmpty ? nil : pairs.reduce(0, +) / Double(pairs.count)
        }

        survey.folders = curves.compactMap { folder, curve in
            let values = Library.lowShapeBands.compactMap { curve[$0] }
            guard !values.isEmpty else { return nil }
            let mean = values.reduce(0, +) / Double(values.count)
            var row = FolderLowEnd(folder: folder, tracks: counts[folder] ?? 0,
                                   clipped: clipped[folder] ?? 0,
                                   lra: ranges[folder].flatMap {
                                       BS1770.percentile($0, 50)
                                   },
                                   crest: crests[folder].flatMap {
                                       BS1770.percentile($0, 50)
                                   },
                                   curve: curve, mean: mean, deficitVsReference: nil)
            if let referenceCurve, folder != referenceName {
                row.deficitVsReference = gap(curve, referenceCurve,
                                             Library.lowShapeBands)
            }

            if let top = tops[folder] {
                row.topCurve = top
                let values = Library.topShapeBands.compactMap { top[$0] }
                if !values.isEmpty {
                    row.topMean = values.reduce(0, +) / Double(values.count)
                }
                if let referenceTop, folder != referenceName {
                    row.topDeficitVsReference = gap(top, referenceTop,
                                                    Library.topShapeBands)
                }
            }
            return row
        }
        .sorted { $0.mean < $1.mean }     // thinnest first, as everywhere else

        return survey
    }

    /// The same thing as text, for pasting into a note or a message.
    public func asText() -> String {
        // Says "selected" because it is: the figures above count the
        // folders chosen, while the tables below cover everything measured.
        // Both are wanted -- a reference folder has to keep counting after
        // it is cleared from the list -- but a bare "177 tracks" over a
        // table listing eight folders invites the wrong reading.
        var out = ["LIBRARY  (\(measured) track(s) in the selected folder(s))",
                   String(repeating: "=", count: 62), ""]
        func dB(_ value: Double?) -> String {
            value.map { String(format: "%.2f", $0) } ?? "--"
        }
        out += ["  median LUFS-I   \(dB(medianLUFSI))",
                "  median s_p95    \(dB(medianSP95))",
                "  median LRA      \(dB(medianLRA))",
                "  median crest    \(dB(medianCrest)) dB",
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
            out += ["", "How many tracks would need a BOOST (on s_p95)",
                    String(repeating: "-", count: 62),
                    "  A negative gain is free. A positive one eventually needs a limiter,",
                    "  which is the thing this project exists to avoid.", "",
                    "   target   need boost   > +3 dB   over ceiling"]
            for row in targets {
                out.append(String(format: "  %6.0f   %9.1f%%   %6.1f%%   %11.1f%%",
                                  row.targetLUFS, row.needBoost * 100,
                                  row.bigBoost * 100, row.wouldExceedCeiling * 100))
            }
        }

        if !folders.isEmpty {
            out += ["", "Low end by folder, 31.5-63 Hz"
                    + (reference.map { " (against \($0))" }
                       ?? "  — no reference named, so vs ref is blank"),
                    String(repeating: "-", count: 62),
                    "   tracks   mean    vs ref   clipped    LRA   folder"]
            for row in folders {
                let versus = row.deficitVsReference.map { String(format: "%+7.2f", $0) }
                    ?? "      -"
                let range = row.lra.map { String(format: "%5.2f", $0) } ?? "    -"
                out.append(String(format: "  %6d  %+6.2f  %@   %3d (%3.0f%%)  %@   %@",
                                  row.tracks, row.mean, versus,
                                  row.clipped, row.clippedShare * 100,
                                  range, row.folder))
            }
        }
        if folders.contains(where: { $0.lra != nil || $0.crest != nil }) {
            out += ["", "Dynamics by folder — what the loudness war took out",
                    String(repeating: "-", count: 62),
                    "  Two different injuries, and the stage that repairs one does",
                    "  nothing for the other, so both are here.",
                    "",
                    "  LRA is range over BARS: verse against chorus, breakdown",
                    "  against drop. Loudness-war pop runs 4 to 6, a well-mastered",
                    "  record 8 to 10. Low means the 'Loudness range' setting has",
                    "  something to do — but keep the target modest, because a track",
                    "  that ducks 8 LU in the breakdown disappears under the next one.",
                    "",
                    "  Crest is punch over MILLISECONDS: peak minus loudness. Low",
                    "  means the 'Attack' setting has something to do, and it is the",
                    "  one that makes a record hit harder without making it duck.",
                    "",
                    "  'range' needs BOTH to be low, not LRA alone. A seven-minute",
                    "  disco groove runs at one level because that is the record, not",
                    "  because a compressor did it -- and expanding it would invent",
                    "  dynamics it never had. Low LRA with crest intact is the",
                    "  arrangement; low LRA with crest gone is the mastering.",
                    "",
                    "  tracks    LRA   crest  clipped   wants                  folder"]
            for row in folders.sorted(by: { ($0.crest ?? 99) < ($1.crest ?? 99) }) {
                let range = row.lra.map { String(format: "%5.2f", $0) } ?? "    -"
                let crest = row.crest.map { String(format: "%5.2f", $0) } ?? "    -"
                // Said plainly rather than left to be worked out from three
                // columns, and "wants" rather than "needs" because these are
                // thresholds, not a diagnosis.
                //
                // The crest figure of 12 was taken from the published range
                // and then measured here: across this library, material from
                // before the loudness war reads 11.87 to 12.11 and 1999 pop
                // reads 9.88 to 10.73. The threshold sits in the gap.
                //
                // `range` deliberately requires a low crest as well. Asking
                // LRA alone marked every disco compilation in the library as
                // wanting it, on records whose crest was the highest measured
                // anywhere -- a groove that holds one level for seven minutes
                // is the arrangement, and expanding it invents dynamics the
                // record never had.
                var wants: [String] = []
                let flattened = (row.crest ?? 99) < 12.0
                if row.clippedShare > 0.20 { wants.append("declip") }
                if let lra = row.lra, lra < 6.0, flattened { wants.append("range") }
                if flattened, row.crest != nil { wants.append("attack") }
                let verdict = (wants.isEmpty ? "—" : wants.joined(separator: "+"))
                    .padding(toLength: 23, withPad: " ", startingAt: 0)
                out.append(String(format: "  %6d  %@   %@    %3.0f%%    %@%@",
                                  row.tracks, range, crest,
                                  row.clippedShare * 100, verdict, row.folder))
            }
        }

        if !folders.isEmpty {
            out += ["", "Top end by folder, 8-20 kHz"
                    + (reference.map { " (against \($0))" } ?? ""),
                    String(repeating: "-", count: 62),
                    "  A high shelf can only lift what is THERE, so this is the "
                    + "table that says",
                    "  whether adding air is even an option.",
                    "",
                    "  'cliff' is the drop from 16k to 20k. Recorded music rolls "
                    + "off a few dB",
                    "  across that step; a lossy codec falls off a wall. 128 kbps "
                    + "cuts near 16k",
                    "  and 320 near 20k, so a large figure here means the band is "
                    + "empty and a",
                    "  shelf would raise nothing but the noise under it. Only a "
                    + "harmonic",
                    "  exciter can put content where there is none -- and that is "
                    + "invention,",
                    "  not restoration, which is why nothing here does it.",
                    "",
                    "   mean    vs ref      8k    10k   12.5k     16k     20k"
                    + "   cliff   folder"]
            for row in folders {
                let versus = row.topDeficitVsReference.map { String(format: "%+7.2f", $0) }
                    ?? "      -"
                let bands = [8000.0, 10000.0, 12500.0, 16000.0, 20000.0].map { band in
                    row.topCurve[band].map { String(format: "%6.1f", $0) } ?? "     -"
                }.joined(separator: "  ")
                // The step that shows a codec, rather than the 12.5k-to-16k
                // one this table used to name: at 320 kbps the low-pass sits
                // near 20k, so it does not touch 16k at all and the old
                // reading could not see it.
                let cliff: String
                if let a = row.topCurve[16000.0], let b = row.topCurve[20000.0] {
                    cliff = String(format: "%6.1f", a - b)
                } else {
                    cliff = "     -"
                }
                out.append(String(format: "  %+6.2f  %@  %@  %@   %@",
                                  row.topMean.isFinite ? row.topMean : 0,
                                  versus, bands, cliff, row.folder))
            }
        }
        return out.joined(separator: "\n")
    }
}
