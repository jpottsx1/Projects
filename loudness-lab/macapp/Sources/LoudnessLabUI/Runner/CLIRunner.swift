import Foundation

/// Runs the `loudness-lab` command and reads back what it wrote.
///
/// The app is a front end, not a second implementation. Every measurement and
/// every sample this displays came out of the Python that has the test suite
/// behind it -- BS.1770 validated against ffmpeg's ebur128, a de-clipper
/// scored against known-clean audio, a sub sized from a measured corpus.
/// Reimplementing any of that in Swift would fork the reference and leave two
/// things to keep honest instead of one.
@MainActor
final class CLIRunner: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var log: String = ""
    @Published private(set) var manifest: Manifest?
    @Published private(set) var failure: String?

    /// The repository root, holding the `loudness-lab` launcher.
    @Published var toolRoot: URL?

    private var process: Process?

    func run(folders: [URL], settings: Settings, profile: String?,
             limit: Int, compare: Bool, dryRun: Bool,
             outputDirectory: URL) async {
        guard !isRunning else { return }
        guard let toolRoot else {
            failure = "Point the app at the loudness-lab folder first."
            return
        }
        let launcher = toolRoot.appendingPathComponent("loudness-lab")
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else {
            failure = "No runnable loudness-lab at \(launcher.path)."
            return
        }

        isRunning = true
        log = ""
        failure = nil
        manifest = nil

        var arguments = ["subbass"] + folders.map(\.path)
        arguments += ["--out", outputDirectory.path, "--limit", String(limit)]
        if let profile, !profile.isEmpty { arguments += ["--profile", profile] }
        if !compare { arguments.append("--no-compare") }
        if dryRun { arguments.append("--dry-run") }
        arguments += settings.flags()

        let status = await stream(launcher: launcher, arguments: arguments)
        isRunning = false

        guard status == 0 else {
            failure = "loudness-lab exited with status \(status). See the log."
            return
        }
        guard !dryRun else { return }

        let path = outputDirectory.appendingPathComponent("manifest.json")
        do {
            manifest = try Manifest.read(path)
        } catch {
            failure = "The run finished but its manifest could not be read: "
                    + error.localizedDescription
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        isRunning = false
    }

    /// Both streams are drained as they arrive. The tool reports progress and
    /// a long folder takes minutes; collecting it at the end would look hung.
    private func stream(launcher: URL, arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = launcher
            task.arguments = arguments
            task.currentDirectoryURL = launcher.deletingLastPathComponent()

            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8)
                else { return }
                Task { @MainActor in self?.log += text }
            }

            task.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: finished.terminationStatus)
            }

            self.process = task
            do {
                try task.run()
            } catch {
                Task { @MainActor [weak self] in
                    self?.log += "\nCould not start: \(error.localizedDescription)\n"
                }
                continuation.resume(returning: -1)
            }
        }
    }
}
