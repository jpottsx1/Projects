import Foundation

/// The Intro tab's state, and what drives it.
///
/// A track is PREPARED once (half a minute: it is separated into stems and
/// its beat grid found) and the process holding it stays up, so choosing a
/// loop, rendering a length and rendering another are seconds each. Batch
/// runs over many tracks do not need that and go through the one-shot
/// command instead, which separates, renders and moves on.
@MainActor
final class IntroEngine: ObservableObject {

    /// A prepared track, as the tool reports it.
    struct Track: Equatable {
        let path: String
        let name: String
        let seconds: Double
        let bpm: Double
        let joinSeconds: Double
        let pickupSeconds: Double
        let downbeatFrom: String
        let barsAfterJoin: Int
        let warnings: [String]
        /// Every bar line from the first, in seconds into the ORIGINAL.
        let barSeconds: [Double]
        let suggestedJoinBar: Int
        let joinReason: String

        /// The last bar the song can arrive at: it needs a bar of itself.
        var lastJoinBar: Int { max(0, barSeconds.count - 2) }
    }

    /// One finished intro file.
    struct Render: Identifiable, Equatable {
        let url: URL
        let bars: Int
        let loopBars: Int
        /// Where in the file the original begins, for playing the join.
        let joinSeconds: Double
        let introSeconds: Double
        let sourceBar: Int
        let sourceSeconds: Double
        let vocalDB: Double?
        let vocalFree: Bool
        let repeatScore: Double
        let warnings: [String]
        /// The bar the song arrives at, and how much of the original's
        /// opening was cut out to make room for the intro.
        var joinBar: Int = 0
        var cutSeconds: Double = 0
        /// The finished file drawn the way the original is; nil if the tool
        /// did not send it.
        var envelope: JoinEnvelope?

        var id: String { url.path }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    /// How a batch is going.
    struct Batch: Equatable {
        var index = 0
        var total = 0
        var name = ""
        var finished: [Render] = []
        var failures: [String] = []
    }

    @Published private(set) var track: Track?
    @Published private(set) var sources: [IntroSource] = []
    /// The bar line the song arrives at; everything of the original before
    /// it is replaced by the intro. Starts at the tool's suggestion (where
    /// the groove lands) and is the person's to move.
    @Published var joinBar = 0
    @Published private(set) var envelope: JoinEnvelope?
    /// Nil means the best-ranked stretch, which is what a render uses when
    /// nothing has been picked.
    @Published var chosenBar: Int?
    @Published var lengths: Set<Int> = [16]
    @Published var loopBars = 4 {
        didSet { if oldValue != loopBars, track != nil { Task { await loadSources() } } }
    }
    @Published private(set) var renders: [Render] = []
    /// A sentence saying what is happening, nil when idle. Non-nil also
    /// means the controls are disabled: one request at a time.
    @Published private(set) var busy: String?
    @Published private(set) var batch: Batch?
    @Published private(set) var failure: String?
    @Published private(set) var playing: Render.ID?
    /// The track a host asked to have selected. The panel follows it when it
    /// changes, and picks it up on appearing if it was set before.
    @Published var focusPath: String?
    /// Bumped on every request, so asking for the track already named
    /// still moves the picker back to it.
    @Published private(set) var focusTick = 0
    /// Beats the bar lines have been moved by hand from where the tool put
    /// them, 0-3. Kept here so a reloaded track can be put back the same way.
    @Published private(set) var beatShift = 0
    func focus(_ path: String) { focusPath = path; focusTick += 1 }

    let player = ABPlayer()
    private var session: IntroSession?
    /// A specific tool to run, for a test that stands one in. Nil means
    /// the real one, found as the rest of the app finds it.
    private let toolOverride: URL?

    init(tool: URL? = nil) { toolOverride = tool }
    private let flag = Engine.CancelFlag()

    var isBusy: Bool { busy != nil }
    var toolMissing: Bool { toolOverride == nil && CLI.locate() == nil }

    /// The few seconds either side of the join that are worth hearing.
    static let auditionLead = 8.0

    // MARK: - One track

    /// Separate the track and find its grid. Replaces any track already held.
    func prepare(_ path: String) async {
        guard !isBusy else { return }
        guard let tool = toolOverride ?? CLI.locate() else { failure = CLI.missing; return }
        failure = nil
        stopPlaying()
        track = nil; sources = []; chosenBar = nil; envelope = nil; joinBar = 0
        beatShift = 0
        if session == nil { session = IntroSession(tool: tool) }
        busy = "Separating into stems… about half a minute."
        defer { busy = nil }
        do {
            let events = try await session!.request(
                "prepare", ["path": path], onEvent: { [weak self] event in
                    guard event.event == "stage", let stage = event.stage else { return }
                    Task { @MainActor in self?.stage(stage) }
                })
            guard let prepared = events.first(where: { $0.event == "prepared" }) else {
                failure = "The intro tool did not report the track."
                return
            }
            track = Track(path: prepared.path ?? path,
                          name: prepared.name ?? URL(fileURLWithPath: path).lastPathComponent,
                          seconds: prepared.seconds ?? 0,
                          bpm: prepared.bpm ?? 0,
                          joinSeconds: prepared.joinSeconds ?? 0,
                          pickupSeconds: prepared.pickupSeconds ?? 0,
                          downbeatFrom: prepared.downbeatFrom ?? "",
                          barsAfterJoin: prepared.barsAfterJoin ?? 0,
                          warnings: prepared.warnings ?? [],
                          barSeconds: prepared.barSeconds ?? [],
                          suggestedJoinBar: prepared.suggestedJoinBar ?? 0,
                          joinReason: prepared.joinReason ?? "")
            joinBar = track?.suggestedJoinBar ?? 0
            await loadSources(whileBusy: true)
            await loadEnvelope()
        } catch {
            failure = error.localizedDescription
            session?.close(); session = nil
        }
    }

    /// A request to the held session. If the tool says it no longer holds
    /// the track (it lets it go after sitting idle, to give its memory back,
    /// or was restarted after a crash), the track is prepared again and the
    /// request retried ONCE, so an idle session costs the person a pause and
    /// not an error. Once: a tool that still says so after a prepare is
    /// broken, and looping on it would never end.
    private func ask(_ command: String, _ fields: [String: Any] = [:]) async throws -> [IntroEvent] {
        guard let session, let track else {
            throw IntroSession.Failure("No track is held. Analyse one first.")
        }
        do {
            return try await session.request(command, fields)
        } catch let failure as IntroSession.Failure where failure.code == "no_track" {
            busy = "Loading the track again… about half a minute."
            _ = try await session.request("prepare", ["path": track.path])
            if beatShift != 0 { _ = try await session.request("rephase", ["beats": beatShift]) }
            return try await session.request(command, fields)
        }
    }

    /// Calls another beat the first of the bar, by `beats` (negative: earlier).
    /// The tool picks the downbeat from the accents in the low end, which a
    /// four-on-the-floor record does not have; this is how to correct it by
    /// ear. Nothing is separated again, so it is quick.
    func moveBeatOne(by beats: Int) async {
        guard let old = track, !isBusy else { return }
        failure = nil
        stopPlaying()
        busy = "Moving the bar lines…"
        defer { busy = nil }
        do {
            let events = try await ask("rephase", ["beats": beats])
            guard let grid = events.first(where: { $0.event == "grid" }) else {
                failure = "The intro tool did not report the new bar lines."
                return
            }
            beatShift = ((beatShift + beats) % 4 + 4) % 4
            track = Track(path: old.path, name: old.name, seconds: old.seconds, bpm: old.bpm,
                          joinSeconds: grid.joinSeconds ?? old.joinSeconds,
                          pickupSeconds: grid.pickupSeconds ?? 0,
                          downbeatFrom: grid.downbeatFrom ?? "",
                          barsAfterJoin: grid.barsAfterJoin ?? 0,
                          warnings: grid.warnings ?? [],
                          barSeconds: grid.barSeconds ?? old.barSeconds,
                          suggestedJoinBar: grid.suggestedJoinBar ?? 0,
                          joinReason: grid.joinReason ?? "")
            joinBar = track?.suggestedJoinBar ?? 0
            chosenBar = nil
            await loadSources(whileBusy: true)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func stage(_ name: String) {
        switch name {
        case "separating": busy = "Separating into stems… about half a minute."
        case "rendering": busy = "Rendering…"
        default: break
        }
    }

    /// The picture of the track for the join picker. A failure costs only
    /// the picture: the slider still works, so it is not an error worth
    /// stopping for.
    private func loadEnvelope() async {
        do {
            let events = try await ask("envelope")
            if let made = events.first(where: { $0.event == "envelope" }) {
                envelope = JoinEnvelope(event: made)
            }
        } catch {
            envelope = nil
        }
    }

    func loadSources(whileBusy: Bool = false) async {
        guard track != nil else { return }
        if !whileBusy {
            guard !isBusy else { return }
            busy = "Finding loops…"
        }
        defer { if !whileBusy { busy = nil } }
        do {
            let events = try await ask("sources", ["loop_bars": loopBars, "count": 5])
            sources = events.first(where: { $0.event == "sources" })?.sources ?? []
            if let chosenBar, !sources.contains(where: { $0.bar == chosenBar }) {
                self.chosenBar = nil
            }
        } catch { failure = error.localizedDescription }
    }

    /// Render every chosen length from the held track.
    func render(to outputDirectory: URL?) async {
        guard track != nil, !isBusy, !lengths.isEmpty else { return }
        failure = nil
        defer { busy = nil }
        for bars in lengths.sorted() {
            busy = "Rendering \(bars) bars…"
            var fields: [String: Any] = ["bars": bars, "loop_bars": loopBars,
                                         "join_bar": joinBar]
            if let chosenBar { fields["source_bar"] = chosenBar }
            if let outputDirectory { fields["out"] = outputDirectory.path }
            do {
                let events = try await ask("render", fields)
                if let made = events.first(where: { $0.event == "intro" }),
                   var render = Self.render(from: made) {
                    if let drawn = events.first(where: { $0.event == "render_envelope"
                                                         && $0.output == made.output }) {
                        render.envelope = JoinEnvelope(event: drawn)
                    }
                    renders.removeAll { $0.id == render.id }
                    renders.insert(render, at: 0)
                }
            } catch {
                failure = error.localizedDescription
                return
            }
        }
    }

    // MARK: - Listening

    /// Plays a finished file from `offset`. Without one, from a few seconds
    /// before the original arrives, because the join is the moment to judge.
    func play(_ render: Render, from offset: Double? = nil) {
        if playing != render.id {
            player.loadOrReport([ABPlayer.Source(id: render.id, label: render.name,
                                                 url: render.url, matchGainDB: 0)])
            playing = render.id
        }
        let start = offset ?? max(0, render.joinSeconds - Self.auditionLead)
        player.play(from: start)
    }

    /// Plays the ORIGINAL from `offset`: what the person is choosing a join
    /// in, which the rendered file is not. Starts a few seconds before the
    /// join by default so the lead-in and the downbeat are both heard.
    func playOriginal(from offset: Double? = nil) {
        guard let track else { return }
        if playing != track.path {
            player.loadOrReport([ABPlayer.Source(
                id: track.path, label: track.name,
                url: URL(fileURLWithPath: track.path), matchGainDB: 0)])
            playing = track.path
        }
        let join = JoinMath.seconds(ofBar: joinBar, in: track.barSeconds)
        player.play(from: offset ?? max(0, join - Self.auditionLead))
    }

    /// Where the playhead belongs on the ORIGINAL's timeline, for whatever is
    /// playing now. The original plays as itself. A rendered intro plays the
    /// new intro first, which has no place in the original, so it sweeps the
    /// replaced stretch, and then follows the song from the join on.
    func originalTime(atPlayerPosition position: Double) -> Double? {
        guard let playing else { return nil }
        if let track, playing == track.path { return position }
        guard let render = renders.first(where: { $0.id == playing }) else { return nil }
        return JoinMath.playhead(atFileTime: position, songArrivesAt: render.joinSeconds,
                                 cutSeconds: render.cutSeconds)
    }

    /// Space bar in the track list: the start of a track as it is, before it
    /// is analysed or ticked, to hear whether it starts cold. Again stops it.
    func togglePreview(_ path: String) {
        if playing == path && player.isPlaying { stopPlaying(); return }
        player.loadOrReport([ABPlayer.Source(
            id: path, label: URL(fileURLWithPath: path).lastPathComponent,
            url: URL(fileURLWithPath: path), matchGainDB: 0)])
        playing = path
        player.play(from: 0)
    }

    /// Drops the list of edits made so far, for when another song is chosen.
    func forgetMade() {
        if let playing, renders.contains(where: { $0.id == playing }) { stopPlaying() }
        renders = []
    }

    func stopPlaying() {
        player.stop()
        playing = nil
    }

    // MARK: - Many tracks

    /// Separate and render each of `paths` in turn with the best loop, through
    /// the one-shot command. Skips the held session: that is for choosing, and
    /// holding a track's stems while a crate goes through would double the
    /// memory for nothing.
    func renderBatch(_ paths: [String], to outputDirectory: URL?) async {
        guard !isBusy, !paths.isEmpty, !lengths.isEmpty else { return }
        guard let tool = toolOverride ?? CLI.locate() else { failure = CLI.missing; return }
        failure = nil
        stopPlaying()
        session?.close(); session = nil; track = nil; sources = []
        flag.reset()
        batch = Batch(total: paths.count)
        busy = "Working through \(paths.count) track\(paths.count == 1 ? "" : "s")…"
        defer { busy = nil }

        var arguments = ["intro"] + paths
        arguments += ["--bars"] + lengths.sorted().map(String.init)
        arguments += ["--loop-bars", String(loopBars), "--json"]
        if let outputDirectory { arguments += ["--out", outputDirectory.path] }

        do {
            try await CLI.run(tool, arguments, isCancelled: { [flag] in flag.isCancelled }) { [weak self] line in
                guard let event = IntroEvent(line) else { return }
                Task { @MainActor in self?.apply(batchEvent: event) }
            }
        } catch {
            // A non-zero exit is how the tool says "at least one track
            // failed"; each failure arrived as its own event, so only
            // something with no such event is worth saying again.
            if batch?.failures.isEmpty ?? true { failure = error.localizedDescription }
        }
        if let finished = batch?.finished { renders = finished.reversed() + renders }
    }

    func cancelBatch() { flag.cancel() }

    private func apply(batchEvent event: IntroEvent) {
        switch event.event {
        case "file":
            batch?.index = event.index ?? batch?.index ?? 0
            batch?.total = event.total ?? batch?.total ?? 0
            batch?.name = event.name ?? ""
        case "intro":
            if let render = Self.render(from: event) { batch?.finished.append(render) }
        case "error":
            batch?.failures.append("\(event.name ?? "A track"): \(event.message ?? "failed")")
        default: break
        }
    }

    func reset() {
        stopPlaying()
        session?.close(); session = nil
        track = nil; sources = []; chosenBar = nil; batch = nil; failure = nil
        envelope = nil; joinBar = 0; beatShift = 0
    }

    nonisolated static func render(from event: IntroEvent) -> Render? {
        guard let output = event.output, let bars = event.bars else { return nil }
        return Render(url: URL(fileURLWithPath: output), bars: bars,
                      loopBars: event.loopBars ?? 4,
                      joinSeconds: event.joinInOutput ?? 0,
                      introSeconds: event.secondsOfIntro ?? 0,
                      sourceBar: event.sourceBar ?? 0,
                      sourceSeconds: event.sourceSeconds ?? 0,
                      vocalDB: event.sourceVocalDB,
                      vocalFree: event.vocalFree ?? false,
                      repeatScore: event.loopRepeat ?? 0,
                      warnings: event.warnings ?? [],
                      joinBar: event.joinBar ?? 0,
                      cutSeconds: event.cutSeconds ?? 0)
    }
}

#if DEBUG
extension IntroEngine {
    /// Puts the engine in a state the UI can be looked at in, without
    /// running anything: for the snapshot test, which exists because layout
    /// cannot be judged from code.
    func seedForSnapshot(track: Track?, sources: [IntroSource] = [],
                         renders: [Render] = [], busy: String? = nil,
                         batch: Batch? = nil, failure: String? = nil,
                         envelope: JoinEnvelope? = nil, joinBar: Int = 0) {
        self.envelope = envelope
        self.joinBar = joinBar
        self.track = track
        self.sources = sources
        self.renders = renders
        self.busy = busy
        self.batch = batch
        self.failure = failure
    }
}
#endif
