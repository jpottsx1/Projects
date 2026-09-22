import Foundation
import LoudnessKit

/// The work, run by the command line tool.
///
/// Both halves go through `loudness-lab` now: `analyze` to measure and
/// `subbass` to process. The Swift port of the DSP under `LoudnessKit` is
/// kept and still tested against the Python's own numbers, but it is not
/// what runs -- the Python is the implementation that was validated
/// against ffmpeg, tuned by measuring rather than guessing, and does its
/// arithmetic in numpy's C rather than in a loop written twice.
///
/// So this class builds arguments, drives the progress bar from the JSON
/// the tool writes a line at a time, and reads back what it left behind.
/// Nothing heavy happens on this actor, which is what keeps the window
/// alive and the Stop button clickable.
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

    /// What the run said about itself, read on the pipe's thread.
    ///
    /// The log and the progress bar are updated by hopping each event onto
    /// the main actor, which is right for them and wrong for this: the hop
    /// is queued, not awaited, so the last few can land AFTER the process
    /// has exited and `CLI.run` has returned. Anything the code below
    /// depends on -- where the manifest went, what the refusal said -- is
    /// therefore recorded synchronously here instead, and the hop is left
    /// to do only what it is safe to be late about.
    ///
    /// It was written the other way first. The symptom would have been a
    /// run that processed a folder correctly and then said "nothing was
    /// written", sometimes.
    final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var manifest: String?
        private var message: String?

        func record(_ event: CLI.Event) {
            lock.lock(); defer { lock.unlock() }
            if event.event == "done", let path = event.manifest { manifest = path }
            if event.event == "error", let said = event.message { message = said }
        }

        var manifestPath: String? { lock.lock(); defer { lock.unlock() }; return manifest }
        var refusal: String? { lock.lock(); defer { lock.unlock() }; return message }
    }


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

        // First line of every run, so a result is never separated from the
        // build that produced it.
        say(BuildInfo.summary)
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

    /// What makes two rows the same record.
    ///
    /// Artist and title, with case, punctuation and spacing thrown away,
    /// because "Earth, Wind & Fire - Let's Groove" and "Earth Wind and
    /// Fire - Lets Groove" are the same song off two compilations. An
    /// untagged file falls back to its own path, which is unique -- so a
    /// track with no tags is never mistaken for another track with no tags.
    static func identity(of row: Library.TrackRow) -> String {
        let artist = row.artist ?? "", title = row.title ?? ""
        guard !artist.isEmpty || !title.isEmpty else { return row.path }
        let joined = (artist + "\u{001F}" + title).lowercased()
        let kept = joined.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "\u{001F}"
        }
        return String(String.UnicodeScalarView(kept))
    }

    /// One line of the CLI's report, turned into what is on screen.
    ///
    /// Only failures and totals are written to the log. A line per track
    /// would bury the few that matter under three hundred that do not, and
    /// the progress bar already says which track is being worked on.
    ///
    /// A processing run has two halves and one bar: it measures whatever
    /// is not already current, then processes. The `phase` on each event
    /// is what keeps "2 of 2" from happening twice with no explanation.
    private func apply(_ event: CLI.Event) {
        switch event.event {
        case "progress":
            if let done = event.done, let total = event.total, total > 0 {
                progress = Double(done) / Double(total)
                let verb = event.phase == "process" ? "Processed" : "Measured"
                progressNote = "\(verb) \(done) of \(total) — \(event.name ?? "")"
            }
            switch event.status ?? "ok" {
            case "ok":
                break
            case "skipped":
                // Not a failure: the policy declining to act, which is most
                // of what a good policy does. Worth a line, because
                // otherwise a run that did nothing looks like a run that
                // broke.
                say("  \(event.name ?? "?"): \(event.reason ?? "skipped")")
            default:
                say("  failed: \(event.name ?? "?")"
                    + ((event.reason ?? event.error).map { " — \($0)" } ?? ""))
            }
        case "measured":
            let seconds = event.seconds.map { String(format: " in %.1fs", $0) } ?? ""
            say("\(event.found ?? 0) found, \(event.analysed ?? 0) measured, "
                + "\(event.skipped ?? 0) already current, "
                + "\(event.errors ?? 0) failed\(seconds).")
            progress = 0
            progressNote = "Choosing what to work on…"
        case "selected":
            if let reference = event.reference { say("Reference: \(reference)") }
            say("\(event.selected ?? 0) track(s) to process"
                + (event.format.map { " as \($0)" } ?? "") + ".")
            if let duplicates = event.duplicates, duplicates > 0 {
                say("  \(duplicates) duplicate(s) skipped — same artist and "
                    + "title already in this batch.")
            }
        case "done":
            let seconds = event.seconds.map { String(format: " in %.1fs", $0) } ?? ""
            // `analyze` and `subbass` both finish with a `done`. The one
            // that wrote files says how many.
            if event.dryRun == true {
                say("Dry run — nothing written. \(event.selected ?? 0) "
                    + "track(s) would be processed\(seconds).")
            } else if let written = event.written {
                say("\(written) track(s) written"
                    + (event.out.map { " to \($0)" } ?? "")
                    + (event.errors.map { $0 > 0 ? ", \($0) failed" : "" } ?? "")
                    + "\(seconds).")
            } else {
                say("  \(event.found ?? 0) found, \(event.analysed ?? 0) measured, "
                    + "\(event.skipped ?? 0) already current, "
                    + "\(event.errors ?? 0) failed\(seconds).")
            }
        case "error":
            // Not shown here: `Outcome` has it, and `run` states it once --
            // as the failure, where the window can show it, rather than as
            // one more line in the log.
            break
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

    /// Process, by running the command line tool.
    ///
    /// The chain is the Python's: it is the implementation that was
    /// validated against ffmpeg, tuned by measuring rather than guessing,
    /// and does its arithmetic in numpy's C. This builds the arguments,
    /// drives the bar from the JSON it writes, and reads the manifest it
    /// leaves behind.
    ///
    /// Every setting is passed explicitly rather than by naming a profile,
    /// so what runs is what is on screen. A profile named on the command
    /// line would be read from the repository's `profiles.json`, which the
    /// app does not edit -- so a slider moved here would have changed
    /// nothing, silently.
    ///
    /// `only` is the queue's selection: the paths the user left ticked. Nil
    /// means everything found. The selection is applied BEFORE the limit,
    /// so unticking a track promotes the next one into range rather than
    /// leaving a gap.
    func run(folders: [URL], profile: Profile, limit: Int, compare: Bool,
             dryRun: Bool, outputDirectory: URL, databaseURL: URL,
             format: AudioWriter.Format = .flac,
             only: Set<String>? = nil) async {
        guard !isRunning, !folders.isEmpty else { return }
        isRunning = true; flag.reset(); failure = nil; manifest = nil
        log = ""; progress = nil
        defer { isRunning = false; progress = nil; progressNote = nil }

        let outcome = Outcome()
        do {
            guard let tool = CLI.locate() else { throw CLI.Failure(CLI.missing) }
            if only?.isEmpty == true {
                failure = "Nothing is ticked in the list."
                return
            }
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)

            // The ticked list goes in a file rather than on the command
            // line. A batch is hundreds of paths and argv has a limit;
            // a file has none, and the tool reads one either way.
            var selection: URL?
            if let only {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("loudnesslab-selection-\(UUID().uuidString).txt")
                try only.sorted().joined(separator: "\n").write(
                    to: url, atomically: true, encoding: .utf8)
                selection = url
            }
            defer { if let selection { try? FileManager.default.removeItem(at: selection) } }

            // First line of every run, so a result is never separated from
            // the build that produced it.
            say(BuildInfo.summary)
            progressNote = "Starting…"

            var arguments = ["subbass"] + folders.map(\.path) + [
                "--db", databaseURL.path,
                "--out", outputDirectory.path,
                "--format", format.cliName,
                "--porcelain",
                // The app's list is already deduplicated by the eye; the
                // batch is not. A library of compilations is mostly the
                // same forty songs.
                "--skip-duplicates",
                "--limit", String(limit == Int.max ? Int(Int32.max) : limit),
                "--target", String(profile.target),
                "--estimator", profile.estimator,
                "--peak-ceiling", String(profile.peakCeiling),
                "--amount", String(profile.amount),
                "--max-amount", String(profile.maxAmount),
                "--min-activity", String(profile.minActivity),
                "--punch", String(profile.punch),
                "--punch-decay", String(profile.punchDecay),
                "--declip-max", String(profile.declipMax),
                "--target-lra", String(profile.targetLRA),
                "--max-attenuation", String(profile.maxAttenuation),
                "--transient", String(profile.transient),
                "--min-crest", String(profile.minCrest),
                "--air", String(profile.air),
                "--air-tune", String(profile.airTune),
            ]
            if profile.auto { arguments += ["--auto"] }
            if let reference = profile.reference, !reference.isEmpty {
                arguments += ["--reference", reference]
            }
            if profile.declip { arguments += ["--declip"] }
            if !compare { arguments += ["--no-compare"] }
            if dryRun { arguments += ["--dry-run"] }
            if let selection { arguments += ["--select", selection.path] }

            try await CLI.run(tool, arguments,
                              isCancelled: { [flag] in flag.isCancelled }) { [weak self] line in
                guard let event = CLI.Event(line) else { return }
                outcome.record(event)
                Task { @MainActor in self?.apply(event) }
            }
            if cancelled { say("Stopped."); return }
            // A refusal can come back with a zero exit status -- "this
            // profile asks for no spectral change" is the tool declining,
            // not failing. Without this the run would end quietly and the
            // reason would only be in the log.
            if let refusal = outcome.refusal { failure = refusal; return }
            guard !dryRun else { return }

            // Read back what the tool wrote, rather than rebuilding it from
            // the events. The manifest is where the run states that a
            // track's versions came out of one decode and are therefore
            // sample-aligned, and that claim belongs to whoever wrote them.
            if let path = outcome.manifestPath {
                manifest = try Manifest.read(URL(fileURLWithPath: path))
            } else {
                say("Nothing was written -- every track was already at the "
                    + "reference, or gated out.")
            }

            let wanted = profile.reference
            survey = await Task.detached(priority: .userInitiated) {
                guard let reader = try? Library(at: databaseURL) else { return nil }
                return try? Survey.of(reader, under: folders, reference: wanted)
            }.value
        } catch {
            // A refusal the tool reported itself says more than its exit
            // status does -- "name one of the folders you have measured"
            // against "exited with 2".
            failure = outcome.refusal ?? error.localizedDescription
        }
    }

}
