import Foundation

/// What `loudness-lab intro --serve` says back, one JSON object a line.
///
/// Every field but `event` is optional because several events share the
/// shape (`stage`, `prepared`, `sources`, `intro`, `done`, `error`), the same
/// way `CLI.Event` does for the other commands, and an event this app does
/// not know decodes rather than failing the line.
struct IntroEvent: Decodable, Equatable {
    let event: String
    var id: Int?
    var stage: String?
    var name: String?
    var message: String?
    /// Set on an `error` a program can act on: "no_track" means the tool no
    /// longer holds the track (let go after sitting idle, or restarted).
    var code: String?
    var warnings: [String]?

    // prepared
    var path: String?
    var seconds: Double?
    var bpm: Double?
    var joinSeconds: Double?
    var pickupSeconds: Double?
    var downbeatFrom: String?
    var gridCoherence: Double?
    var barsAfterJoin: Int?
    /// The track's first bar line, and where the song should arrive: the bar
    /// line the full groove lands on, an index into `barSeconds`.
    var firstBarSeconds: Double?
    var suggestedJoinBar: Int?
    var joinReason: String?
    /// The time of every bar line from the first, for snapping to.
    var barSeconds: [Double]?

    // sources
    var loopBars: Int?
    var sources: [IntroSource]?

    // intro (one rendered file)
    var output: String?
    var source: String?
    var bars: Int?
    var secondsOfIntro: Double?
    var leadSeconds: Double?
    var sourceBar: Int?
    var sourceSeconds: Double?
    var sourceVocalDB: Double?
    var vocalFree: Bool?
    var loopRepeat: Double?
    var loopSnapped: Bool?
    var joinBar: Int?
    var cutSeconds: Double?

    // envelope: the track as three bands over time, for drawing the picker
    var perSecond: Double?
    var bass: [Int]?
    var mid: [Int]?
    var treble: [Int]?

    // batch (`intro <files> --json`): `file` announces one, `intro` and `error`
    // report it.
    var index: Int?
    var total: Int?

    enum CodingKeys: String, CodingKey {
        case event, id, stage, name, message, code, warnings, path, seconds, bpm
        case firstBarSeconds = "first_bar_seconds"
        case suggestedJoinBar = "suggested_join_bar"
        case joinReason = "join_reason"
        case barSeconds = "bar_seconds"
        case joinBar = "join_bar"
        case cutSeconds = "cut_seconds"
        case perSecond = "per_second"
        case bass, mid, treble
        case joinSeconds = "join_seconds"
        case pickupSeconds = "pickup_seconds"
        case downbeatFrom = "downbeat_from"
        case gridCoherence = "grid_coherence"
        case barsAfterJoin = "bars_after_join"
        case loopBars = "loop_bars"
        case sources, output, source, bars
        case secondsOfIntro = "seconds_of_intro"
        case leadSeconds = "lead_seconds"
        case sourceBar = "source_bar"
        case sourceSeconds = "source_seconds"
        case sourceVocalDB = "source_vocal_db"
        case vocalFree = "vocal_free"
        case loopRepeat = "loop_repeat"
        case loopSnapped = "loop_snapped"
        case index, total
    }

    init?(_ line: String) {
        guard let data = line.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(IntroEvent.self, from: data)
        else { return nil }
        self = decoded
    }

    /// Where in the finished file the original begins: the intro, plus the
    /// few milliseconds the file starts early so the first kick is whole.
    var joinInOutput: Double? {
        guard let secondsOfIntro else { return nil }
        return secondsOfIntro + (leadSeconds ?? 0)
    }
}

/// One stretch of the track offered as the loop.
struct IntroSource: Decodable, Identifiable, Equatable {
    let bar: Int
    let seconds: Double
    /// How loud the vocal is against the instrumental there, in dB. Nil
    /// where it was not measured.
    let vocalDB: Double?
    let vocalFree: Bool
    /// How well its drums come round again one loop later, -1 to 1. A
    /// stretch that does not (a build, a fill) makes a seam that misses.
    let repeatScore: Double
    let snapped: Bool
    /// How far its most unusual bar is from the groove around it: 0 for the
    /// same pattern again, about 1 for a fill or a break. Heard on every repeat.
    var fill: Double? = nil

    var id: Int { bar }

    enum CodingKeys: String, CodingKey {
        case bar, seconds, snapped, fill
        case vocalDB = "vocal_db"
        case vocalFree = "vocal_free"
        case repeatScore = "repeat"
    }
}

/// The long-running `loudness-lab intro --serve` process, and a way to ask it
/// things.
///
/// Separating a song into stems is half a minute; everything after it is
/// seconds. Run as one command per click, every change of length or loop
/// would pay the half minute again. So one process is kept, holding the
/// separated track in memory, and requests go to it a line at a time.
///
/// One request at a time: the interface disables its controls while one is
/// outstanding, and the Python answers in order, so a request's events are
/// simply everything up to its `done` or `error`.
final class IntroSession: @unchecked Sendable {

    struct Failure: LocalizedError {
        let errorDescription: String?
        /// The tool's own code for the failure, where it gave one.
        let code: String?
        init(_ message: String, code: String? = nil) {
            errorDescription = message
            self.code = code
        }
    }

    private let tool: URL
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var nextID = 1
    private var collected: [IntroEvent] = []
    private var pending: CheckedContinuation<[IntroEvent], Error>?
    private var pendingID: Int?
    private var onEvent: (@Sendable (IntroEvent) -> Void)?
    private let stderrText = CLI.Collected()

    init(tool: URL) { self.tool = tool }

    deinit { close() }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    /// Ask for something and wait for all of it. Throws the tool's own
    /// message for an `error` event, and a described failure if the process
    /// dies mid-request. `onEvent` sees each event as it arrives -- the
    /// `stage` ones are what says "separating" while half a minute goes by.
    func request(_ command: String, _ fields: [String: Any] = [:],
                 onEvent: (@Sendable (IntroEvent) -> Void)? = nil) async throws -> [IntroEvent] {
        try launchIfNeeded()
        let id: Int = {
            lock.lock(); defer { lock.unlock() }
            defer { nextID += 1 }
            return nextID
        }()
        var body = fields
        body["cmd"] = command
        body["id"] = id
        let data = try JSONSerialization.data(withJSONObject: body) + Data([0x0A])

        let events: [IntroEvent] = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pending = continuation
            pendingID = id
            collected = []
            self.onEvent = onEvent
            let handle = input
            lock.unlock()
            guard let handle else {
                finish(throwing: Failure("The intro tool is not running."))
                return
            }
            do {
                try handle.write(contentsOf: data)
            } catch {
                finish(throwing: Failure("Could not reach the intro tool: \(error.localizedDescription)"))
            }
        }
        if let failure = events.last(where: { $0.event == "error" }) {
            throw Failure(failure.message ?? "The intro tool reported an error.",
                          code: failure.code)
        }
        return events
    }

    /// Ends the process, which drops the track it was holding.
    func close() {
        lock.lock()
        let running = process
        process = nil
        input = nil
        lock.unlock()
        try? running?.standardInput.flatMap { $0 as? Pipe }?.fileHandleForWriting.close()
        if running?.isRunning == true { running?.terminate() }
    }

    // MARK: - The process

    private func launchIfNeeded() throws {
        lock.lock()
        if process?.isRunning == true { lock.unlock(); return }
        lock.unlock()

        let process = Process()
        process.executableURL = tool
        process.arguments = ["intro", "--serve"]
        process.environment = CLI.environment()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let lines = CLI.LineReader { [weak self] line in self?.receive(line) }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { lines.append(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [stderrText] handle in
            let data = handle.availableData
            if !data.isEmpty { stderrText.append(data) }
        }
        process.terminationHandler = { [weak self] finished in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            lines.append(stdout.fileHandleForReading.readDataToEndOfFile())
            lines.flush()
            self?.died(status: finished.terminationStatus)
        }
        do { try process.run() } catch {
            throw Failure("Could not start the intro tool: \(error.localizedDescription)")
        }
        lock.lock()
        self.process = process
        input = stdin.fileHandleForWriting
        lock.unlock()
    }

    private func receive(_ line: String) {
        guard let event = IntroEvent(line) else { return }
        lock.lock()
        let mine = pendingID
        let listener = onEvent
        lock.unlock()
        // An event for a request nobody is waiting on any more (it was
        // abandoned by a close) is dropped rather than credited to the
        // next one.
        guard event.id == nil || event.id == mine else { return }
        listener?(event)
        lock.lock()
        collected.append(event)
        let finished = event.event == "done" || event.event == "error"
        lock.unlock()
        if finished { finish(throwing: nil) }
    }

    private func finish(throwing error: Error?) {
        lock.lock()
        let waiting = pending
        let events = collected
        pending = nil
        pendingID = nil
        onEvent = nil
        lock.unlock()
        if let error { waiting?.resume(throwing: error) } else { waiting?.resume(returning: events) }
    }

    private func died(status: Int32) {
        lock.lock()
        let waiting = pending != nil
        process = nil
        input = nil
        lock.unlock()
        guard waiting else { return }
        let tail = stderrText.text().split(separator: "\n").suffix(6).joined(separator: "\n")
        var message = "The intro tool stopped (exit \(status))."
        if !tail.isEmpty { message += "\n\(tail)" }
        finish(throwing: Failure(message))
    }
}
