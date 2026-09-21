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

    @Published private(set) var progressNote: String?

    /// Cancellation has to be readable from worker tasks that are not on the
    /// main actor, and a `@Published` Bool is not -- reading it from another
    /// thread is exactly the race the compiler exists to stop.
    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        func reset() { lock.lock(); value = false; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    private let flag = CancelFlag()
    private var cancelled: Bool { flag.isCancelled }

    func cancel() { flag.cancel() }

    func say(_ line: String) { log += line + "\n" }

    @Published private(set) var survey: Survey?

    /// Measure and report, touching nothing.
    ///
    /// Separate from `run` because it answers a different question. `run`
    /// asks what a policy would do to a folder; this asks what the folder
    /// IS -- how much of it arrived clipped, how far its low end sits under
    /// another folder's. Those are the numbers a profile's caps are meant
    /// to come from, and until now they only existed in the command line.
    func measure(folders: [URL], databaseURL: URL, reference: String?) async {
        guard !isRunning, !folders.isEmpty else { return }
        isRunning = true; flag.reset(); failure = nil
        log = ""; progress = nil
        defer { isRunning = false; progress = nil; progressNote = nil }

        do {
            try await measurePass(folders: folders, databaseURL: databaseURL)
            if cancelled { say("  Stopped."); return }

            progress = nil
            progressNote = "Building the survey…"
            survey = await Task.detached(priority: .userInitiated) {
                guard let reader = try? Library(at: databaseURL) else { return nil }
                return try? Survey.of(reader, under: folders, reference: reference)
            }.value
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Measure a set of folders into the database, by running the CLI.
    ///
    /// Shared by Measure and by Process, which needs the same numbers
    /// before it can choose what to work on.
    private func measurePass(folders: [URL], databaseURL: URL) async throws {
        guard let tool = CLI.locate() else { throw CLI.Failure(CLI.missing) }
        // The database's folder, because the CLI will not make it and a
        // first run has nowhere to put the file.
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        say("Measuring \(folders.count) folder(s)…")
        progressNote = "Starting…"
        let arguments = ["analyze"] + folders.map(\.path)
            + ["--db", databaseURL.path, "--porcelain"]

        try await CLI.run(tool, arguments,
                          isCancelled: { [flag] in flag.isCancelled }) { [weak self] line in
            guard let event = CLI.Event(line) else { return }
            Task { @MainActor in self?.apply(event) }
        }
    }

    /// One line of the CLI's report, turned into what is on screen.
    ///
    /// Only failures are written to the log. A line per track would bury
    /// the two lines that matter under three hundred that do not, and the
    /// progress bar already says which track is being worked on.
    private func apply(_ event: CLI.Event) {
        switch event.event {
        case "progress":
            if let done = event.done, let total = event.total, total > 0 {
                progress = Double(done) / Double(total)
                progressNote = "Measured \(done) of \(total) — \(event.name ?? "")"
            }
            if event.status != "ok" {
                say("  failed: \(event.name ?? "?")"
                    + (event.error.map { " — \($0)" } ?? ""))
            }
        case "done":
            let seconds = event.seconds.map { String(format: " in %.1fs", $0) } ?? ""
            say("  \(event.found ?? 0) found, \(event.analysed ?? 0) measured, "
                + "\(event.skipped ?? 0) already current, "
                + "\(event.errors ?? 0) failed\(seconds).")
        default:
            break
        }
    }

    /// Recompute the survey from what the library already holds, without
    /// measuring anything -- for when only the reference folder changed.
    func refreshSurvey(folders: [URL], databaseURL: URL, reference: String?) {
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              let library = try? Library(at: databaseURL) else { return }
        survey = try? Survey.of(library, under: folders, reference: reference)
    }

    /// `only` is the queue's selection: the paths the user left ticked. Nil
    /// means everything found, which is what the command line does. The
    /// selection is applied BEFORE the limit, so unticking a track promotes
    /// the next one into range rather than leaving a gap.
    func run(folders: [URL], profile: Profile, limit: Int, compare: Bool,
             dryRun: Bool, outputDirectory: URL, databaseURL: URL,
             only: Set<String>? = nil) async {
        guard !isRunning, !folders.isEmpty else { return }
        isRunning = true; flag.reset(); failure = nil; manifest = nil
        log = ""; progress = nil
        defer { isRunning = false; progress = nil; progressNote = nil }

        do {
            // Measured first, and by the CLI: Process needs the same numbers
            // Measure does, and the database is opened afterwards so the
            // reader is not holding a handle while another process writes.
            try await measurePass(folders: folders, databaseURL: databaseURL)
            if cancelled { say("  Stopped."); return }
            progress = nil

            let library = try Library(at: databaseURL)

            // Thinnest low end first -- the tracks the sub stage is for.
            let shape = try library.lowEndShape(under: folders)
            let rows = try library.tracks(under: folders)
                .filter { shape[$0.path] != nil }
                .filter { only?.contains($0.path) ?? true }
                .sorted { (shape[$0.path] ?? 0) < (shape[$1.path] ?? 0) }
                .prefix(limit)
            guard !rows.isEmpty else {
                failure = only?.isEmpty == true
                    ? "Nothing is ticked in the list."
                    : "Nothing measured under those folders."
                return
            }
            say("\(rows.count) track(s) selected.")

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

            // Sizing first, because it is a database read: quick, and it
            // decides which tracks are worth decoding at all.
            var jobs: [Processor.Job] = []
            for row in rows {
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
                jobs.append(Processor.Job(path: row.path, name: row.name,
                                          amountDB: amount))
            }
            guard !jobs.isEmpty else {
                failure = "Every selected track was gated out. "
                    + "Lower the gate, or turn per-track sizing off."
                return
            }

            // The work itself, off this actor and several at a time. It used
            // to run here, on the main thread, one track after another --
            // which is why the window froze and the Stop button could not be
            // clicked for the length of a run.
            progress = 0
            say("Processing \(jobs.count) track(s), "
                + "\(Processor.defaultJobs()) at a time…")
            let outcomes = await Processor.run(
                jobs, profile: profile, compare: compare, dryRun: dryRun,
                outputDirectory: outputDirectory,
                isCancelled: { [flag] in flag.isCancelled },
                progress: { [weak self] step in
                    Task { @MainActor in
                        self?.progress = Double(step.done) / Double(step.total)
                        self?.progressNote =
                            "\(step.done) of \(step.total) — \(step.name)"
                    }
                })
            if cancelled { say("Stopped.") }

            var tracks: [Manifest.Track] = []
            for outcome in outcomes {
                say(outcome.line)
                guard !outcome.wroteNothing else { continue }
                tracks.append(Manifest.Track(
                    source: outcome.source, name: outcome.name, folder: outcome.folder,
                    subDB: outcome.subDB, punchDB: outcome.punchDB,
                    clipsRestored: outcome.clipsRestored, clipLiftDB: outcome.clipLiftDB,
                    variants: outcome.variants.map {
                        Manifest.Variant(kind: $0.kind, label: $0.label, path: $0.path,
                                         seconds: $0.seconds, lufsI: $0.lufsI,
                                         sP95: $0.sP95, truePeakDBTP: $0.truePeakDBTP)
                    }))
            }

            guard !dryRun else { say("Dry run -- nothing written."); return }
            let built = Manifest(version: 1, rate: Int(AudioDecoder.targetRate),
                                 aligned: true, profile: profile.description,
                                 settings: profile, tracks: tracks)
            try write(built, to: outputDirectory.appendingPathComponent("manifest.json"))
            manifest = built
            say("\(tracks.count) track(s) written to \(outputDirectory.path).")
            let wanted = profile.reference
            survey = await Task.detached(priority: .userInitiated) {
                guard let reader = try? Library(at: databaseURL) else { return nil }
                return try? Survey.of(reader, under: folders, reference: wanted)
            }.value
        } catch {
            failure = error.localizedDescription
        }
    }

    private func write(_ manifest: Manifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url)
    }
}
