import Foundation
import LoudnessKit

/// The work, run in this process.
///
/// This used to shell out to the Python. It no longer does: every
/// measurement and every sample now comes from LoudnessKit, which is held to
/// the Python's own numbers by the golden vectors in its test target. What
/// that buys is not speed but the removal of a dependency -- the app works
/// on a Mac with no Python, no ffmpeg and no command line.
@MainActor
final class Engine: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var log = ""
    @Published private(set) var manifest: Manifest?
    @Published private(set) var failure: String?
    @Published private(set) var progress: Double?

    private var cancelled = false

    func cancel() { cancelled = true }

    func say(_ line: String) { log += line + "\n" }

    func run(folders: [URL], profile: Profile, limit: Int, compare: Bool,
             dryRun: Bool, outputDirectory: URL, databaseURL: URL) async {
        guard !isRunning, !folders.isEmpty else { return }
        isRunning = true; cancelled = false; failure = nil; manifest = nil
        log = ""; progress = nil
        defer { isRunning = false; progress = nil }

        do {
            let library = try Library(at: databaseURL)

            say("Measuring \(folders.count) folder(s)…")
            let counts = await Analyzer.run(roots: folders, library: library) { [weak self] step in
                Task { @MainActor in
                    self?.progress = step.total > 0
                        ? Double(step.done) / Double(step.total) : nil
                    if step.failed { self?.say("  failed: \(step.name)") }
                }
            }
            say("  \(counts.found) found, \(counts.analysed) measured, "
                + "\(counts.skipped) already current, \(counts.errors) failed.")
            progress = nil

            // Thinnest low end first -- the tracks the sub stage is for.
            let shape = try library.lowEndShape(under: folders)
            let rows = try library.tracks(under: folders)
                .filter { shape[$0.path] != nil }
                .sorted { (shape[$0.path] ?? 0) < (shape[$1.path] ?? 0) }
                .prefix(limit)
            guard !rows.isEmpty else {
                failure = "Nothing measured under those folders."
                return
            }
            say("\(rows.count) of \(counts.found) track(s) selected.")

            // Sizing per track needs a corpus to measure against. Without
            // one the setting cannot be honoured, and applying the fixed
            // amount instead would be the app quietly doing something other
            // than the policy on screen.
            var curve: [Double: Double] = [:]
            if profile.auto {
                let curves = try library.referenceCurves()
                guard let wanted = profile.reference, !wanted.isEmpty,
                      let name = Library.resolveReference(curves, wanted),
                      let found = curves[name] else {
                    failure = profile.reference?.isEmpty == false
                        ? "No single folder matches \(profile.reference!). "
                          + "Name one of the folders you have measured."
                        : "Sizing the sub per track needs a reference folder. "
                          + "Name one, or turn it off and set an amount."
                    return
                }
                curve = found
                say("Reference: \(name)")
            }

            var tracks: [Manifest.Track] = []
            for (index, row) in rows.enumerated() {
                if cancelled { say("Stopped."); break }
                progress = Double(index) / Double(rows.count)
                var amount = profile.amount
                var gate: String?
                if profile.auto {
                    (amount, gate) = try library.shortfall(of: row.path, against: curve,
                                                           cap: profile.maxAmount)
                }
                if let gate, amount <= 0, profile.punch <= 0, !profile.declip {
                    say("  \(row.name): \(gate)")
                    continue
                }
                if let track = try await process(row, profile: profile, amount: amount,
                                                 compare: compare, dryRun: dryRun,
                                                 outputDirectory: outputDirectory) {
                    tracks.append(track)
                }
            }

            guard !dryRun else { say("Dry run -- nothing written."); return }
            let built = Manifest(version: 1, rate: Int(AudioDecoder.targetRate),
                                 aligned: true, profile: profile.description,
                                 settings: profile, tracks: tracks)
            try write(built, to: outputDirectory.appendingPathComponent("manifest.json"))
            manifest = built
            say("\(tracks.count) track(s) written to \(outputDirectory.path).")
        } catch {
            failure = error.localizedDescription
        }
    }

    /// One track through the chain, in the order the measurements settled on:
    /// de-clip first, on the file as it arrived, because it puts peaks BACK
    /// and everything after has to fit under them; then the sub and the
    /// attack shaping; then levelling, last, because everything before it
    /// moves loudness.
    private func process(_ row: Library.TrackRow, profile: Profile, amount requested: Double,
                         compare: Bool, dryRun: Bool,
                         outputDirectory: URL) async throws -> Manifest.Track? {
        let source = URL(fileURLWithPath: row.path)
        let (original, _) = try AudioDecoder.decode(source)
        var audio = original
        var clipReport = Declip.Report()

        if profile.declip {
            (audio, clipReport) = Declip.restore(audio, rate: AudioDecoder.targetRate,
                                                 maxRestoreDB: profile.declipMax)
        }

        var amount = requested
        var note: String?
        if amount > 0 {
            let activity = SubBass.lowBandActivity(audio, rate: AudioDecoder.targetRate)
            if activity.isFinite, activity < profile.minActivity {
                note = String(format: "sub octave barely moves (%.0f dB) -- "
                              + "a static floor rather than a bassline", activity)
                amount = 0
            }
        }
        if amount <= 0, profile.punch <= 0, clipReport.restored == 0 {
            say("  \(row.name): \(note ?? "nothing to do")")
            return nil
        }

        let (processed, report) = SubBass.enhance(audio, rate: AudioDecoder.targetRate,
                                                  amountDB: amount,
                                                  punchDB: profile.punch,
                                                  punchDecayMS: profile.punchDecay)
        let measured = BS1770.measure(processed)
        say(String(format: "  %@: sub %+.2f dB, punch %+.1f dB, %d clip run(s) "
                   + "restored%@", row.name, report.appliedDB, report.punchDB,
                   clipReport.restored, note.map { ", \($0)" } ?? ""))
        guard !dryRun else { return nil }

        let stem = source.deletingPathExtension().lastPathComponent
        var variants: [Manifest.Variant] = []

        if compare {
            // Level-matched, or the comparison only measures which is louder,
            // and louder wins every blind test regardless of merit. Both are
            // brought DOWN to whichever is quieter, so neither can clip.
            let originalLoudness = BS1770.measure(original).lufsI
            let target = min(originalLoudness, measured.lufsI)
            var a = scale(original, by: target - originalLoudness)
            var b = scale(processed, by: target - measured.lufsI)
            // A restored peak stands above full scale by design, and the
            // writer clips what it is given -- which would put back exactly
            // the flat tops the de-clipper just took out. Trim BOTH equally
            // so the level match survives the headroom.
            let room = max(peak(a), peak(b))
            if room > 0.99 {
                a = scale(a, byFactor: 0.99 / room); b = scale(b, byFactor: 0.99 / room)
            }
            let aURL = outputDirectory.appendingPathComponent("\(stem) -- A original.flac")
            let bURL = outputDirectory.appendingPathComponent("\(stem) -- B \(label(profile, amount)).flac")
            try AudioWriter.writeFLAC(a, to: aURL)
            try AudioWriter.writeFLAC(b, to: bURL)
            variants = [variant("original", aURL, "original", a),
                        variant("processed", bURL, label(profile, amount), b)]
        } else {
            let levelled = levelToTarget(processed, profile: profile, measured: measured)
            let url = outputDirectory.appendingPathComponent("\(stem).flac")
            try AudioWriter.writeFLAC(levelled, to: url)
            variants = [variant("processed", url, label(profile, amount), levelled)]
        }

        return Manifest.Track(source: row.path, name: row.name,
                              folder: source.deletingLastPathComponent().lastPathComponent,
                              subDB: report.appliedDB, punchDB: report.punchDB,
                              clipsRestored: clipReport.restored,
                              clipLiftDB: clipReport.liftDB, variants: variants)
    }

    /// Levelling happens here because the lossless gain path cannot do it:
    /// global_gain exists only in an MP3 bitstream, and what comes out of the
    /// sub stage is FLAC. Without this the pipeline ends un-levelled, which
    /// is the one state worse than not having started.
    private func levelToTarget(_ audio: [[Double]], profile: Profile,
                               measured: BS1770.Result) -> [[Double]] {
        let value = profile.estimator == "lufs_i" ? measured.lufsI : (measured.sP95 ?? measured.lufsI)
        guard value.isFinite else { return audio }
        var wanted = profile.target - value
        if measured.truePeakDBTP.isFinite,
           measured.truePeakDBTP + wanted > profile.peakCeiling {
            wanted = profile.peakCeiling - measured.truePeakDBTP
        }
        return scale(audio, by: wanted)
    }

    private func variant(_ kind: String, _ url: URL, _ label: String,
                         _ audio: [[Double]]) -> Manifest.Variant {
        let m = BS1770.measure(audio)
        return Manifest.Variant(kind: kind, label: label, path: url.path,
                                seconds: Double(audio[0].count) / AudioDecoder.targetRate,
                                lufsI: m.lufsI, sP95: m.sP95, truePeakDBTP: m.truePeakDBTP)
    }

    private func label(_ profile: Profile, _ amount: Double) -> String {
        var parts: [String] = []
        if profile.declip { parts.append("declipped") }
        if amount > 0 { parts.append(String(format: "sub%+.1fdB", amount)) }
        if profile.punch > 0 { parts.append(String(format: "punch%+.0fdB", profile.punch)) }
        return parts.isEmpty ? "unchanged" : parts.joined(separator: " ")
    }

    private func scale(_ audio: [[Double]], by db: Double) -> [[Double]] {
        scale(audio, byFactor: pow(10, db / 20))
    }
    private func scale(_ audio: [[Double]], byFactor factor: Double) -> [[Double]] {
        audio.map { $0.map { $0 * factor } }
    }
    private func peak(_ audio: [[Double]]) -> Double {
        audio.flatMap { $0 }.map(abs).max() ?? 0
    }

    private func write(_ manifest: Manifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url)
    }
}
