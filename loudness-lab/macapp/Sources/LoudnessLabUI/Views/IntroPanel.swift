import SwiftUI
import AppKit

/// Intro edits: a track that starts cold, given an intro made from itself.
///
/// The DJ's problem is a song with nowhere to mix in. This builds 8, 16 or
/// 32 bars in front of it out of its own instrumental (the vocal taken out
/// by separating the stems) and lets the song arrive where it always did,
/// on the grid. The work is the Python's; this chooses, asks, and plays the
/// result back, because a number cannot tell you whether a seam is right
/// and an ear can.
struct IntroPanel: View {
    @ObservedObject var engine: IntroEngine
    /// The ticked tracks in the queue, which is where "what to work on" is
    /// already decided everywhere else in the app.
    let ticked: [Queue.Item]

    @State private var picked: String?
    @AppStorage("introOutputDirectory") private var outputOverride = ""

    private var outputDirectory: URL? {
        outputOverride.isEmpty ? nil : URL(fileURLWithPath: outputOverride, isDirectory: true)
    }

    private var shownDirectory: URL {
        outputDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/LoudnessLab/Intro Edits", isDirectory: true)
    }

    private var current: Queue.Item? {
        ticked.first { $0.path == picked } ?? ticked.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                intro
                if engine.toolMissing { missing }
                if ticked.isEmpty {
                    Text("Tick tracks in the list to make intros from them.")
                        .foregroundStyle(.secondary)
                } else {
                    trackSection
                    options
                    if engine.track != nil { sourcesSection }
                    renderRow
                    results
                    batchSection
                }
                if let failure = engine.failure {
                    Text(failure)
                        .font(.callout).foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if let path = engine.focusPath { picked = path } }
        .onChange(of: engine.focusTick) { _, _ in if let path = engine.focusPath { picked = path } }
    }

    // MARK: - Pieces

    private var intro: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Intro edits").font(.headline)
            Text("For a track that starts cold. Builds an intro from the track's own "
                 + "instrumental, then lets the song arrive where it always did. "
                 + "Writes copies; the original is never touched.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var missing: some View {
        Label("The loudness-lab tool was not found, so there is nothing to make "
              + "intros with. Choose it from the Process panel.",
              systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
    }

    private var trackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Track", selection: Binding(
                    get: { current?.path ?? "" },
                    set: { picked = $0 })) {
                    ForEach(ticked) { Text($0.name).tag($0.path) }
                }
                .disabled(engine.isBusy)
                Button(engine.track?.path == current?.path && engine.track != nil
                       ? "Analyse again" : "Analyse") {
                    if let path = current?.path { Task { await engine.prepare(path) } }
                }
                .disabled(engine.isBusy || current == nil || engine.toolMissing)
                .help("Separate this track into stems and find its beat grid. "
                      + "Takes about half a minute; after that, choosing loops "
                      + "and rendering lengths takes seconds.")
            }
            if let busy = engine.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let track = engine.track {
                trackSummary(track)
                JoinPicker(engine: engine, track: track)
            }
        }
    }

    private func trackSummary(_ track: IntroEngine.Track) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(format: "%.1f BPM · first bar at %.2f s%@",
                        track.bpm, track.joinSeconds,
                        track.pickupSeconds > 0
                        ? String(format: " (vocal pickup %.2f s kept)", track.pickupSeconds) : ""))
                .font(.callout)
            Text("Bar lines found from \(track.downbeatFrom).")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(track.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Length").frame(width: 56, alignment: .leading)
                ForEach([8, 16, 32], id: \.self) { bars in
                    Toggle((engine.lengths.contains(bars) ? "✓ " : "") + "\(bars) bars", isOn: Binding(
                        get: { engine.lengths.contains(bars) },
                        set: { on in
                            if on { engine.lengths.insert(bars) }
                            else if engine.lengths.count > 1 { engine.lengths.remove(bars) }
                        }))
                        .toggleStyle(.button)
                        .tint(.accentColor)
                        .disabled(engine.isBusy)
                }
            }
            .help("Pick one or more. Each is its own file, made from the same loop.")
            HStack(spacing: 10) {
                Text("Loop").frame(width: 56, alignment: .leading)
                Picker("", selection: $engine.loopBars) {
                    ForEach([2, 4, 8], id: \.self) { Text("\($0) bars").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                .disabled(engine.isBusy)
                .help("How much of the track is repeated to fill the intro. "
                      + "Longer loops sound less repetitive but need a longer "
                      + "stretch with no vocal.")
            }
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Loop from").font(.subheadline.weight(.semibold))
            if engine.sources.isEmpty {
                Text("No stretch of this track is long enough to loop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(engine.sources.enumerated()), id: \.element.id) { index, source in
                sourceRow(source, best: index == 0)
            }
        }
    }

    private func sourceRow(_ source: IntroSource, best: Bool) -> some View {
        let selected = (engine.chosenBar ?? engine.sources.first?.bar) == source.bar
        return Button {
            engine.chosenBar = source.bar
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: "%@  ·  %@ in", best ? "Best match" : "Bar \(source.bar)",
                                clock(source.seconds)))
                        .fontWeight(selected ? .semibold : .regular)
                    HStack(spacing: 10) {
                        Text(source.vocalFree ? "no vocal"
                             : String(format: "vocal %+.0f dB", source.vocalDB ?? 0))
                            .foregroundStyle(source.vocalFree ? .green : .orange)
                        Text(String(format: "repeats %.2f", source.repeatScore))
                            .foregroundStyle(source.repeatScore >= 0.6 ? Color.secondary : Color.orange)
                        if !source.snapped { Text("grid-timed").foregroundStyle(.orange) }
                    }
                    .font(.caption)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(engine.isBusy)
        .help("Vocal is how loud the singing is against the instrumental here. "
              + "Repeats is how closely the drums come round again one loop "
              + "later: below 0.6 it is a build or a fill, and the seam will "
              + "not land on the beat.")
    }

    private var renderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(engine.isBusy ? "Working…" : "Make intro") {
                    Task { await engine.render(to: outputDirectory) }
                }
                .disabled(engine.isBusy || engine.track == nil || engine.toolMissing)
                .keyboardShortcut(.return, modifiers: .command)
                Text(engine.track == nil && !engine.isBusy ? "Analyse a track first." : "")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text("To").frame(width: 24, alignment: .leading)
                Button(shownDirectory.lastPathComponent) {
                    try? FileManager.default.createDirectory(
                        at: shownDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(shownDirectory)
                }
                .buttonStyle(.link).lineLimit(1).truncationMode(.head)
                .help("Open \(shownDirectory.path) in Finder")
                Spacer()
                Button("Change…") { chooseOutput() }.buttonStyle(.link)
                if !outputOverride.isEmpty {
                    Button("Default") { outputOverride = "" }.buttonStyle(.link)
                }
            }
            .font(.callout)
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !engine.renders.isEmpty {
                Text("Made").font(.subheadline.weight(.semibold))
            }
            ForEach(engine.renders) { render in resultRow(render) }
            if engine.playing != nil { AuditionBar(player: engine.player) }
        }
    }

    private func resultRow(_ render: IntroEngine.Render) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(render.name).lineLimit(1).truncationMode(.middle)
            Text(String(format: "%d bars (%@) · loop from bar %d · %@ · repeats %.2f",
                        render.bars, clock(render.introSeconds), render.sourceBar,
                        render.vocalFree ? "no vocal"
                        : String(format: "vocal %+.0f dB", render.vocalDB ?? 0),
                        render.repeatScore))
                .font(.caption).foregroundStyle(.secondary)
            if render.cutSeconds > 0.5 {
                Text("The song arrives at bar \(render.joinBar); the first "
                     + "\(JoinMath.clock(render.cutSeconds)) of the original is replaced.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(render.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Play the join") { engine.play(render) }
                    .help("Starts \(Int(IntroEngine.auditionLead)) seconds before the song "
                          + "arrives, which is where a bad seam or a late downbeat shows.")
                Button("From the start") { engine.play(render, from: 0) }
                if engine.playing == render.id {
                    Button("Stop") { engine.stopPlaying() }
                }
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([render.url])
                }.buttonStyle(.link)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var batchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Button("Make intros for all \(ticked.count) ticked") {
                    Task { await engine.renderBatch(ticked.map(\.path), to: outputDirectory) }
                }
                .disabled(engine.isBusy || engine.toolMissing)
                .help("Each track is separated and given the best loop, in the "
                      + "lengths chosen above. About half a minute a track.")
                if engine.batch != nil, engine.isBusy {
                    Button("Stop") { engine.cancelBatch() }
                }
            }
            if let batch = engine.batch {
                if engine.isBusy {
                    ProgressView(value: Double(max(batch.index - 1, 0)),
                                 total: Double(max(batch.total, 1)))
                    Text("\(batch.index) of \(batch.total): \(batch.name)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text("\(batch.finished.count) made, \(batch.failures.count) failed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(batch.failures, id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Helpers

    private func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Where should the intro edits go?"
        if panel.runModal() == .OK, let url = panel.url { outputOverride = url.path }
    }

    private func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// Where the audition is, and a way to move it.
private struct AuditionBar: View {
    @ObservedObject var player: ABPlayer
    @State private var scrubbing = false
    @State private var scrub = 0.0

    var body: some View {
        HStack(spacing: 8) {
            Text(clock(scrubbing ? scrub : player.position))
                .font(.system(.caption, design: .monospaced))
            Slider(value: Binding(
                get: { scrubbing ? scrub : player.position },
                set: { scrub = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                scrubbing = editing
                if !editing { player.seek(to: scrub) }
            }
            Text(clock(player.duration))
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    private func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
