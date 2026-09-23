import Foundation

/// SET ASIDE. The app runs `loudness-lab subbass` instead.
///
/// Kept, with its golden tests, because it is validated work that costs
/// nothing sitting here and is the fallback if bundling Python ever
/// becomes the better answer. Nothing in the app calls it: see
/// `Engine.run`, which builds the command line and drives the progress bar
/// from the JSON the tool writes.
///
/// One track through the chain, off the main thread and several at a time.
///
/// This lived in the app's Engine, which is `@MainActor` -- so every decode,
/// every filter pass and every FLAC write ran on the main thread. The window
/// could not redraw, the progress bar could not move and the Stop button
/// could not be clicked, for as long as the whole run took. It was also
/// strictly one track after another on a machine with eight or more cores.
///
/// Nothing about the audio changed in moving it. The order is still the
/// order the measurements settled on: de-clip first, on the file as it
/// arrived, because it puts peaks BACK and everything after has to fit under
/// them; then the sub and the attack shaping; then levelling, last, because
/// everything before it moves loudness.
public enum Processor {

    public struct Variant: Sendable {
        public let kind, label, path: String
        public let seconds, lufsI, truePeakDBTP: Double
        public let sP95: Double?
    }

    public struct Outcome: Sendable {
        public let source, name, folder: String
        public let subDB, punchDB, clipLiftDB: Double
        public let clipsRestored: Int
        public let variants: [Variant]
        /// The line to print for this track, already worded.
        public let line: String
        /// True when nothing was written: skipped, or a dry run.
        public let wroteNothing: Bool
    }

    public struct Progress: Sendable {
        public let done: Int, total: Int, name: String
    }

    public struct Job: Sendable {
        public let path: String, name: String, amountDB: Double
        public init(path: String, name: String, amountDB: Double) {
            self.path = path; self.name = name; self.amountDB = amountDB
        }
    }

    /// How many at once. See `Concurrency` -- cores against memory, and
    /// memory is what binds here.
    public static func defaultJobs() -> Int { Concurrency.forProcessing() }

    /// Run `jobs` tracks at a time, reporting each as it lands.
    ///
    /// `isCancelled` is checked between tracks rather than inside one: a
    /// half-written FLAC is worse than a few more seconds of waiting.
    public static func run(_ jobs: [Job], profile: Profile, compare: Bool,
                           dryRun: Bool, outputDirectory: URL,
                           format: AudioWriter.Format = .flac,
                           width: Int = defaultJobs(),
                           isCancelled: @escaping @Sendable () -> Bool = { false },
                           progress: (@Sendable (Progress) -> Void)? = nil
    ) async -> [Outcome] {
        guard !jobs.isEmpty else { return [] }
        var results: [Int: Outcome] = [:]
        var done = 0
        var next = 0
        let width = max(1, min(width, jobs.count))

        // Bounded, and refilled as each finishes -- the same shape as the
        // analyser, for the same reason.
        await withTaskGroup(of: (Int, Outcome?).self) { group in
            while next < jobs.count, next < width {
                let index = next; next += 1
                group.addTask {
                    (index, one(jobs[index], profile: profile, compare: compare,
                                dryRun: dryRun, outputDirectory: outputDirectory,
                                format: format))
                }
            }
            for await (index, outcome) in group {
                done += 1
                if let outcome {
                    results[index] = outcome
                    progress?(Progress(done: done, total: jobs.count, name: outcome.name))
                } else {
                    progress?(Progress(done: done, total: jobs.count,
                                       name: jobs[index].name))
                }
                guard !isCancelled(), next < jobs.count else { continue }
                let following = next; next += 1
                group.addTask {
                    (following, one(jobs[following], profile: profile, compare: compare,
                                    dryRun: dryRun, outputDirectory: outputDirectory,
                                    format: format))
                }
            }
        }
        // Back into the order asked for. A task group yields whichever
        // finishes first, and a results table that reorders itself by track
        // length is not a table anyone can read.
        return jobs.indices.compactMap { results[$0] }
    }

    /// One track. Never throws: a file that will not decode is a line in the
    /// log, not a run that stops halfway through a folder.
    public static func one(_ job: Job, profile: Profile, compare: Bool,
                           dryRun: Bool, outputDirectory: URL,
                           format: AudioWriter.Format = .flac) -> Outcome? {
        let source = URL(fileURLWithPath: job.path)
        let rate = AudioDecoder.targetRate
        let folder = source.deletingLastPathComponent().lastPathComponent

        func skipped(_ reason: String) -> Outcome {
            Outcome(source: job.path, name: job.name, folder: folder,
                    subDB: 0, punchDB: 0, clipLiftDB: 0, clipsRestored: 0,
                    variants: [], line: "  \(job.name): \(reason)",
                    wroteNothing: true)
        }

        let original: [[Double]]
        do { (original, _) = try AudioDecoder.decode(source) }
        catch { return skipped("could not be decoded -- \(error.localizedDescription)") }

        var audio = original
        var clipReport = Declip.Report()
        if profile.declip {
            (audio, clipReport) = Declip.restore(audio, rate: rate,
                                                 maxRestoreDB: profile.declipMax)
        }

        var amount = job.amountDB
        var note: String?
        if amount > 0 {
            let activity = SubBass.lowBandActivity(audio, rate: rate)
            if activity.isFinite, activity < profile.minActivity {
                note = String(format: "sub octave barely moves (%.0f dB) -- "
                              + "a static floor rather than a bassline", activity)
                amount = 0
            }
        }
        if amount <= 0, profile.punch <= 0, clipReport.restored == 0 {
            return skipped(note ?? "nothing to do")
        }

        let (processed, report) = SubBass.enhance(audio, rate: rate, amountDB: amount,
                                                  punchDB: profile.punch,
                                                  punchDecayMS: profile.punchDecay)
        let measured = BS1770.measure(processed)
        let line = String(format: "  %@: sub %+.2f dB, punch %+.1f dB, %d clip run(s) "
                          + "restored%@", job.name, report.appliedDB, report.punchDB,
                          clipReport.restored, note.map { ", \($0)" } ?? "")

        guard !dryRun else {
            return Outcome(source: job.path, name: job.name, folder: folder,
                           subDB: report.appliedDB, punchDB: report.punchDB,
                           clipLiftDB: clipReport.liftDB,
                           clipsRestored: clipReport.restored,
                           variants: [], line: line, wroteNothing: true)
        }

        let stem = source.deletingPathExtension().lastPathComponent
        let name = label(profile, amount)
        var variants: [Variant] = []
        do {
            if compare {
                // Level-matched, or the comparison only measures which is
                // louder, and louder wins every blind test regardless of
                // merit. Both are brought DOWN to whichever is quieter, so
                // neither can clip.
                let originalLoudness = BS1770.measure(original).lufsI
                let target = min(originalLoudness, measured.lufsI)
                var a = scale(original, by: target - originalLoudness)
                var b = scale(processed, by: target - measured.lufsI)
                // A restored peak stands above full scale by design, and the
                // writer clips what it is given -- which would put back
                // exactly the flat tops the de-clipper just took out. Trim
                // BOTH equally so the level match survives the headroom.
                let room = max(peak(a), peak(b))
                if room > 0.99 {
                    a = scale(a, byFactor: 0.99 / room); b = scale(b, byFactor: 0.99 / room)
                }
                let suffix = format.fileExtension
                let aURL = outputDirectory
                    .appendingPathComponent("\(stem) -- A original.\(suffix)")
                let bURL = outputDirectory
                    .appendingPathComponent("\(stem) -- B \(name).\(suffix)")
                // Both sides in the same format, always. A lossless original
                // against a lossy processed version has you listening to the
                // codec and calling it the processing.
                try AudioWriter.write(a, to: aURL, format: format, tagsFrom: source)
                try AudioWriter.write(b, to: bURL, format: format, tagsFrom: source)
                variants = [variant("original", aURL, "original", a),
                            variant("processed", bURL, name, b)]
            } else {
                let levelled = levelToTarget(processed, profile: profile, measured: measured)
                let url = outputDirectory
                    .appendingPathComponent("\(stem).\(format.fileExtension)")
                try AudioWriter.write(levelled, to: url, format: format,
                                      tagsFrom: source)
                variants = [variant("processed", url, name, levelled)]
            }
        } catch {
            return skipped("could not be written -- \(error.localizedDescription)")
        }

        return Outcome(source: job.path, name: job.name, folder: folder,
                       subDB: report.appliedDB, punchDB: report.punchDB,
                       clipLiftDB: clipReport.liftDB,
                       clipsRestored: clipReport.restored,
                       variants: variants, line: line, wroteNothing: false)
    }

    /// Levelling happens here because the lossless gain path cannot do it:
    /// global_gain exists only in an MP3 bitstream, and what comes out of the
    /// sub stage is FLAC. Without this the pipeline ends un-levelled, which
    /// is the one state worse than not having started.
    static func levelToTarget(_ audio: [[Double]], profile: Profile,
                              measured: BS1770.Result) -> [[Double]] {
        let value = profile.estimator == "lufs_i"
            ? measured.lufsI : (measured.sP95 ?? measured.lufsI)
        guard value.isFinite else { return audio }
        var wanted = profile.target - value
        if measured.truePeakDBTP.isFinite,
           measured.truePeakDBTP + wanted > profile.peakCeiling {
            wanted = profile.peakCeiling - measured.truePeakDBTP
        }
        return scale(audio, by: wanted)
    }

    static func variant(_ kind: String, _ url: URL, _ label: String,
                        _ audio: [[Double]]) -> Variant {
        let m = BS1770.measure(audio)
        return Variant(kind: kind, label: label, path: url.path,
                       seconds: Double(audio[0].count) / AudioDecoder.targetRate,
                       lufsI: m.lufsI, truePeakDBTP: m.truePeakDBTP, sP95: m.sP95)
    }

    static func label(_ profile: Profile, _ amount: Double) -> String {
        var parts: [String] = []
        if profile.declip { parts.append("declipped") }
        if amount > 0 { parts.append(String(format: "sub%+.1fdB", amount)) }
        if profile.punch > 0 { parts.append(String(format: "punch%+.0fdB", profile.punch)) }
        return parts.isEmpty ? "unchanged" : parts.joined(separator: " ")
    }

    static func scale(_ audio: [[Double]], by db: Double) -> [[Double]] {
        scale(audio, byFactor: pow(10, db / 20))
    }
    static func scale(_ audio: [[Double]], byFactor factor: Double) -> [[Double]] {
        audio.map { $0.map { $0 * factor } }
    }
    static func peak(_ audio: [[Double]]) -> Double {
        audio.flatMap { $0 }.map(abs).max() ?? 0
    }
}
