import Foundation

/// Running the command-line tool, and reading what it says back.
///
/// The measuring and the processing are the Python's job. It is the
/// implementation that was validated against ffmpeg, tuned by measuring
/// rather than guessing, and does its arithmetic in numpy's C rather than
/// in a loop somebody wrote twice. This is the app asking it to work and
/// showing what it reports.
enum CLI {

    /// One line of `--porcelain` output.
    ///
    /// Every field is optional because two different events share the
    /// shape: `progress` carries done/total/name, `done` carries the
    /// counts. Decoding them into one type keeps the reader a switch
    /// rather than two parsers.
    struct Event: Decodable {
        let event: String
        var done: Int?, total: Int?
        var name: String?, path: String?, status: String?, error: String?
        var found: Int?, analysed: Int?, skipped: Int?, errors: Int?
        var seconds: Double?

        init?(_ line: String) {
            guard let data = line.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Event.self, from: data)
            else { return nil }
            self = decoded
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static let missing = """
        Could not find the loudness-lab command. It lives in the project \
        folder, next to macapp. If this is a fresh checkout, run setup.sh \
        there once to build its environment.
        """

    /// Walk up from the running binary looking for the launcher.
    ///
    /// The app is built inside the project -- either into `.build` or as
    /// `macapp/LoudnessLab.app` -- so the launcher is always a few levels
    /// above it. Checked as a regular executable file rather than by name
    /// alone, because the FOLDER is also called loudness-lab and finding
    /// the directory instead of the script would fail later and less
    /// clearly.
    static func locate() -> URL? {
        if let override = UserDefaults.standard.string(forKey: "loudnessLabCLI"),
           isRunnable(URL(fileURLWithPath: override)) {
            return URL(fileURLWithPath: override)
        }
        var directory = Bundle.main.bundleURL.resolvingSymlinksInPath()
        for _ in 0..<10 {
            let candidate = directory.appendingPathComponent("loudness-lab")
            if isRunnable(candidate) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    private static func isRunnable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return manager.isExecutableFile(atPath: url.path)
    }

    /// Run it, delivering stdout a line at a time as it arrives.
    ///
    /// A line at a time rather than all at the end, because the whole point
    /// is a progress bar that moves while the work happens.
    @discardableResult
    static func run(_ tool: URL, _ arguments: [String],
                    isCancelled: @escaping @Sendable () -> Bool = { false },
                    onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        // Boxed, so the watchdog below can hold it without Process itself
        // having to be Sendable.
        let box = Running()
        let process = box.process
        process.executableURL = tool
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let lines = LineReader(onLine: onLine)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { lines.append(data) }
        }

        // stderr is the human progress and any traceback. Kept for the
        // message if this fails, not shown otherwise.
        let stderrText = Collected()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stderrText.append(data) }
        }

        // Stop has to reach a separate process, and the only thing that
        // does is a signal. Polled rather than pushed because there is
        // nothing to push to: checked four times a second, which is well
        // under the time anyone waits before deciding a button is broken.
        let watchdog = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if isCancelled() { box.stop(); return }
                if box.hasFinished() { return }
            }
        }
        defer { watchdog.cancel() }

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                // Whatever was still in the pipe when it exited. Without
                // this the last few lines -- including the one carrying the
                // totals -- can be lost.
                lines.append(output.fileHandleForReading.readDataToEndOfFile())
                stderrText.append(errors.fileHandleForReading.readDataToEndOfFile())
                lines.flush()
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
                box.markStarted()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        if status != 0 && !isCancelled() {
            let tail = stderrText.text().split(separator: "\n").suffix(6)
                .joined(separator: "\n")
            throw Failure("loudness-lab exited with \(status)."
                          + (tail.isEmpty ? "" : "\n\(tail)"))
        }
        return status
    }

    /// Holds the process so a watchdog can signal it.
    ///
    /// `started` matters: without it the watchdog can see a process that
    /// has not begun yet, decide it has finished, and stop watching before
    /// the work starts.
    private final class Running: @unchecked Sendable {
        let process = Process()
        private let lock = NSLock()
        private var started = false

        func markStarted() { lock.lock(); started = true; lock.unlock() }

        func hasFinished() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return started && !process.isRunning
        }

        func stop() {
            lock.lock(); defer { lock.unlock() }
            if started && process.isRunning { process.terminate() }
        }
    }

    /// Reassembles lines from whatever sizes the pipe hands over.
    ///
    /// A read is not a line: one can arrive split down the middle of a JSON
    /// object, and two can arrive together. Holding the remainder until a
    /// newline turns up is the difference between a reliable reader and one
    /// that works until the buffer boundary lands badly.
    private final class LineReader: @unchecked Sendable {
        private let lock = NSLock()
        private var partial = ""
        private let onLine: @Sendable (String) -> Void

        init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

        func append(_ data: Data) {
            guard let text = String(data: data, encoding: .utf8) else { return }
            var ready: [String] = []
            lock.lock()
            partial += text
            while let index = partial.firstIndex(of: "\n") {
                ready.append(String(partial[partial.startIndex..<index]))
                partial = String(partial[partial.index(after: index)...])
            }
            lock.unlock()
            for line in ready where !line.isEmpty { onLine(line) }
        }

        func flush() {
            lock.lock()
            let rest = partial
            partial = ""
            lock.unlock()
            if !rest.isEmpty { onLine(rest) }
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.lock(); data += more; lock.unlock() }
        func text() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
