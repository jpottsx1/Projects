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
    /// What to say when there is nothing to work on, and what the batch
    /// button calls the tracks. The Loudness view's tab says "ticked", because
    /// that is what its queue does; a host that supplies the tracks itself
    /// says something else.
    var emptyText = "Tick tracks in the list to make intros from them."
    var batchNoun = "ticked"

    @State private var picked: String?
    @AppStorage("introOutputDirectory") private var outputOverride = ""
    @AppStorage("outroOutputDirectory") private var outroOutputOverride = ""
    /// On by default: the cards under "Made" belong to the song they were made
    /// from, and left in place under the next song they read as its edits.
    @AppStorage("introClearMade") private var clearMade = true

    private var outro: Bool { engine.mode == .outro }

    /// Intros and outros each remember where they go.
    private var chosenOutput: String { outro ? outroOutputOverride : outputOverride }

    private var outputDirectory: URL? {
        chosenOutput.isEmpty ? nil : URL(fileURLWithPath: chosenOutput, isDirectory: true)
    }

    private var shownDirectory: URL {
        outputDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/LoudnessLab/\(outro ? "Outro" : "Intro") Edits", isDirectory: true)
    }

    private var current: Queue.Item? {
        ticked.first { $0.path == picked } ?? ticked.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if engine.toolMissing { missing }
                if ticked.isEmpty {
                    PanelCard("Nothing to work on") {
                        Text(emptyText).foregroundStyle(.secondary)
                    }
                } else {
                    trackSection
                    if let track = engine.track { JoinPicker(engine: engine, track: track) }
                    options
                    if engine.track != nil { sourcesSection }
                    renderRow
                    results
                    batchSection
                }
                if let failure = engine.failure {
                    Label {
                        Text(failure).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "xmark.octagon.fill") }
                        .font(.callout).foregroundStyle(.red)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(20)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: current?.path) { old, new in
            if clearMade, old != nil, old != new, !engine.isBusy { engine.forgetMade() }
        }
        .onAppear { if let path = engine.focusPath { picked = path } }
        .onChange(of: engine.focusTick) { _, _ in if let path = engine.focusPath { picked = path } }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(outro ? "Outro edits" : "Intro edits").font(.title2.weight(.semibold))
                Text(outro
                     ? "For a track that ends cold or fades out. Keeps the song up to a bar line, "
                       + "then runs a loop of the track's own instrumental, so there is room to mix out. "
                       + "Writes copies; the original is never touched."
                     : "For a track that starts cold. Builds an intro from the track's own "
                       + "instrumental, then lets the song arrive where it always did. "
                       + "Writes copies; the original is never touched.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Picker("", selection: $engine.mode) {
                ForEach(IntroEngine.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 170)
            .disabled(engine.isBusy)
            .help("Intro: a track that starts cold. Outro: a track that ends cold or fades out. "
                  + "Both work from the same analysis, so switching is quick.")
        }
    }

    private var missing: some View {
        Label("The loudness-lab tool was not found, so there is nothing to make "
              + "edits with. Choose it in Loudness Lab's Process panel.",
              systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var trackSection: some View {
        PanelCard("Track") {
            HStack(spacing: 10) {
                Picker("Track", selection: Binding(
                    get: { current?.path ?? "" },
                    set: { picked = $0 })) {
                    ForEach(ticked) { Text($0.name).tag($0.path) }
                }
                .labelsHidden()
                .disabled(engine.isBusy)
                Button(engine.track?.path == current?.path && engine.track != nil
                       ? "Analyse again" : "Analyse") {
                    if let path = current?.path { Task { await engine.prepare(path) } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(engine.isBusy || current == nil || engine.toolMissing)
                .help("Separate this track into stems and find its beat grid. "
                      + "Takes about half a minute; after that, choosing loops "
                      + "and rendering lengths takes seconds.")
            }
            if let busy = engine.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let track = engine.track { trackSummary(track) }
        }
    }

    private func trackSummary(_ track: IntroEngine.Track) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Chip(String(format: "%.1f BPM", track.bpm), tint: .accentColor)
                Chip(String(format: "first bar at %.2f s", track.joinSeconds))
                if track.pickupSeconds > 0 {
                    Chip(String(format: "vocal pickup %.2f s kept", track.pickupSeconds))
                }
                Text("Bar lines found from \(track.downbeatFrom)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            ForEach(track.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var options: some View {
        PanelCard("Options") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    OptionLabel("Length")
                    HStack(spacing: 6) {
                        ForEach([8, 16, 32], id: \.self) { bars in
                            Toggle("\(bars) bars", isOn: Binding(
                                get: { engine.lengths.contains(bars) },
                                set: { on in
                                    if on { engine.lengths.insert(bars) }
                                    else if engine.lengths.count > 1 { engine.lengths.remove(bars) }
                                }))
                                .toggleStyle(ChipToggleStyle())
                                .disabled(engine.isBusy)
                        }
                    }
                    .help("Pick one or more. Each is its own file, made from the same loop.")
                }
                GridRow {
                    OptionLabel("Loop")
                    Picker("", selection: $engine.loopBars) {
                        ForEach([2, 4, 8], id: \.self) { Text("\($0) bars").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    .disabled(engine.isBusy)
                    .help("How much of the track is repeated to fill the intro. "
                          + "Longer loops sound less repetitive but need a longer "
                          + "stretch with no vocal.")
                }
                if outro {
                    GridRow {
                        OptionLabel("Style")
                        Picker("", selection: $engine.outroStyle) {
                            Text("Strip").tag("strip")
                            Text("Beat").tag("beat")
                            Text("Full loop").tag("full")
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                        .disabled(engine.isBusy)
                        .help("Strip: the band leaves a part at a time and the drums end it. "
                              + "Beat: only the song's own drums and bass throughout, a groove to mix out on. "
                              + "Full loop: the whole instrumental throughout. In the first two the loop's "
                              + "drums and bass also fade in under the song's last bar.")
                    }
                    GridRow {
                        OptionLabel("Ending")
                        Picker("", selection: $engine.outroFadeBars) {
                            Text("Stop").tag(0.0)
                            Text("Fade out").tag(4.0)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                        .disabled(engine.isBusy)
                        .help("Stop: the outro ends on a bar line. Fade out: it fades away over its last four bars.")
                    }
                } else {
                    GridRow {
                        OptionLabel("Style")
                        Picker("", selection: Binding(get: { engine.style }, set: { engine.chooseStyle($0) })) {
                            Text("Build up").tag("build")
                            Text("Full loop").tag("full")
                            Text("Beat").tag("beat")
                            Text("Underlay").tag("underlay")
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 360)
                        .disabled(engine.isBusy)
                        .help(Self.styleHelp)
                    }
                    if let reason = engine.styleReason, let suggested = engine.suggestedStyle {
                        GridRow {
                            Color.clear.frame(width: 1, height: 1)
                            Label("Suggested: \(Self.styleName(suggested)) — \(reason).",
                                  systemImage: "lightbulb")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Toggle("End on the song's own break or fill", isOn: $engine.endOnBreak)
                            .toggleStyle(.checkbox)
                            .disabled(engine.isBusy)
                            .help("Make the intro's last bar the song's own break, the bar before its "
                                  + "drums come back, with the vocal taken out, so the intro leads "
                                  + "into the song the way the song leads into a drop. Only when the "
                                  + "song has one that fits; otherwise the intro ends on the loop. "
                                  + "Off by default: listen to both with Play the join.")
                    }
                }
            }
        }
    }

    private var sourcesSection: some View {
        PanelCard("Loop from", subtitle: "Where in the track the repeating instrumental is taken from.") {
            if engine.sources.isEmpty {
                Text("No stretch of this track is long enough to loop.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                ForEach(Array(engine.sources.enumerated()), id: \.element.id) { index, source in
                    sourceRow(source, best: index == 0)
                }
            }
        }
    }

    private func sourceRow(_ source: IntroSource, best: Bool) -> some View {
        let selected = (engine.chosenBar ?? engine.sources.first?.bar) == source.bar
        return Button {
            engine.chosenBar = source.bar
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(best ? "Best match" : "Bar \(source.bar)")
                    .fontWeight(selected ? .semibold : .regular)
                    .frame(width: 96, alignment: .leading)
                Text("\(clock(source.seconds)) in")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                HStack(spacing: 6) {
                    Chip(source.vocalFree ? "no vocal"
                         : String(format: "vocal %+.0f dB", source.vocalDB ?? 0),
                         tint: source.vocalFree ? .green : .orange)
                    Chip(String(format: "repeats %.2f", source.repeatScore),
                         tint: source.repeatScore >= 0.6 ? .secondary : .orange)
                    if let feel = source.feel {
                        Chip(String(format: "feels like the song %.0f%%", max(0, 1 - feel) * 100),
                             tint: feel <= 0.35 ? .secondary : .orange)
                            .help("How closely the rhythm matches the bars the song arrives with.")
                    }
                    if let off = source.tempoOff, abs(off) >= 0.003 {
                        Chip(String(format: "tempo %+.1f%%", off * 100),
                             tint: abs(off) <= 0.012 ? .secondary : .orange)
                            .help("Against the song at the join. Up to 1.2% is matched by "
                                  + "resampling the loop; more is left alone and will be heard.")
                    }
                    if !source.snapped { Chip("grid-timed", tint: .orange) }
                    // intro.FILL_NOTED in the Python.
                    if (source.fill ?? 0) >= 0.4 {
                        Chip("has a fill", tint: .orange)
                            .help("A bar here differs from the groove around it, and a loop "
                                  + "repeats it every time, the last one running into the song.")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1))
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
        PanelCard("Make it") {
            HStack(spacing: 12) {
                Button {
                    Task { await engine.render() }
                } label: {
                    Text(engine.isBusy ? "Working…" : (outro ? "Make outro" : "Make intro"))
                        .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(engine.isBusy || engine.track == nil || engine.toolMissing)
                .keyboardShortcut(.return, modifiers: .command)
                if engine.track == nil && !engine.isBusy {
                    Text("Analyse a track first.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Button(shownDirectory.lastPathComponent) {
                    try? FileManager.default.createDirectory(
                        at: shownDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(shownDirectory)
                }
                .buttonStyle(.link).lineLimit(1).truncationMode(.head)
                .help("Open \(shownDirectory.path) in Finder")
                Spacer()
                Button("Change…") { chooseOutput() }.buttonStyle(.link)
                if !chosenOutput.isEmpty {
                    Button("Default") {
                        if outro { outroOutputOverride = "" } else { outputOverride = "" }
                    }.buttonStyle(.link)
                }
            }
            .font(.callout)
        }
    }

    /// The edits of the kind being made: switching to the other keeps the
    /// ones made so far, and shows them again on switching back.
    private var shownRenders: [IntroEngine.Render] {
        engine.renders.filter { $0.kind == engine.mode }
    }

    @ViewBuilder private var results: some View {
        if !shownRenders.isEmpty || engine.playing != nil {
            PanelCard("Made") {
                Toggle("Clear when another song is chosen", isOn: $clearMade)
                    .toggleStyle(.checkbox).controlSize(.small)
                    .help("Remove the edits listed here when you pick a different track, "
                          + "so they are not mistaken for the new song's. Unsaved drafts are "
                          + "deleted with them; saved files are kept.")
            } content: {
                VStack(spacing: 10) {
                    ForEach(shownRenders) { render in resultRow(render) }
                }
                if engine.playing != nil { AuditionBar(player: engine.player) }
            }
        }
    }

    /// "On the beat: the join 0.4 ms, the seams within 1.2 ms", from the
    /// file's own kicks. Nil when nothing was measured.
    static func timingLine(_ render: IntroEngine.Render) -> String? {
        guard let timing = render.timing else { return nil }
        let edge = render.kind == .outro ? "the exit" : "the join"
        var parts: [String] = []
        if let ms = timing.edgeOffsetMs { parts.append(String(format: "%@ %.1f ms", edge, abs(ms))) }
        if let ms = timing.worstSeamMs { parts.append(String(format: "the seams within %.1f ms", abs(ms))) }
        guard !parts.isEmpty else { return nil }
        return "Beat check: " + parts.joined(separator: ", ")
    }

    private func resultRow(_ render: IntroEngine.Render) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(render.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
            Text(String(format: "%d bars (%@) · loop from bar %d · %@ · repeats %.2f",
                        render.bars, clock(render.introSeconds), render.sourceBar,
                        render.vocalFree ? "no vocal"
                        : String(format: "vocal %+.0f dB", render.vocalDB ?? 0),
                        render.repeatScore))
                .font(.caption).foregroundStyle(.secondary)
            if render.kind == .outro {
                Text("The song leaves at bar \(render.exitBar) (\(JoinMath.clock(render.exitSeconds)) in)"
                     + (render.tailSeconds > 0.05
                        ? String(format: ", its vocal ringing on %.1f s over the loop", render.tailSeconds) : "")
                     + (render.cutSeconds > 0.5
                        ? "; the last \(JoinMath.clock(render.cutSeconds)) of the original is replaced."
                        : "."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(render.fadeBars > 0
                     ? "\(IntroEngine.outroStyleLabel(render.style)) · fades out over its last \(Int(render.fadeBars)) bars."
                     : "\(IntroEngine.outroStyleLabel(render.style)) · stops on the bar line.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let bar = render.leadInBar, let at = render.leadInSeconds {
                Text("Ends on the song's own bar \(bar) (\(JoinMath.clock(at)) in), vocal removed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let note = render.leadInNote {
                Text(note.prefix(1).uppercased() + note.dropFirst() + ".")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let pct = render.retunedPct, abs(pct) > 0 {
                Text(String(format: "The loop was resampled %+.2f%% to the song's tempo at the join.", pct))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let off = render.tempoOffPct, abs(off) >= 0.5 {
                Label(String(format: "The loop's tempo is %+.1f%% off the song at the join; "
                             + "that is too far to match, so the intro will change speed there.", off),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let envelope = render.envelope {
                EditStrip(engine: engine, render: render, envelope: envelope)
            }
            if render.kind == .intro, render.cutSeconds > 0.5 {
                Text("The song arrives at bar \(render.joinBar); the first "
                     + "\(JoinMath.clock(render.cutSeconds)) of the original is replaced.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let line = Self.timingLine(render) {
                Text(line).font(.caption).foregroundStyle(.secondary)
                    .help("Measured off the finished file: how far its kicks land from where "
                          + "the bars before each seam say they should. Under 5 ms is on the beat.")
            }
            ForEach(render.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button(render.kind == .outro ? "Play the exit" : "Play the join") { engine.play(render) }
                    .help(render.kind == .outro
                          ? "Starts \(Int(IntroEngine.auditionLead)) seconds before the song leaves, "
                            + "which is where a bad seam or a late downbeat shows."
                          : "Starts \(Int(IntroEngine.auditionLead)) seconds before the song "
                            + "arrives, which is where a bad seam or a late downbeat shows.")
                Button("From the start") { engine.play(render, from: 0) }
                if engine.playing == render.id {
                    Button("Stop") { engine.stopPlaying() }
                }
                Spacer()
                if render.isDraft && render.savedAs == nil {
                    Text("Draft: not saved").font(.caption).foregroundStyle(.orange)
                    Button("Discard") { engine.discard(render) }
                        .help("Delete this draft.")
                    Button("Save") { engine.save(render, to: shownDirectory) }
                        .buttonStyle(.borderedProminent)
                        .help("Keep this one: copy it to \(shownDirectory.path). "
                              + "Drafts you do not save are deleted when you pick "
                              + "another song or quit.")
                } else {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                    Button("Remove") { engine.discard(render) }
                        .buttonStyle(.link)
                        .help("Take it off this list. The saved file stays.")
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([render.keptURL])
                    }.buttonStyle(.link)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var batchSection: some View {
        PanelCard("Batch", subtitle: "Every ticked track, in the lengths chosen above. About half a minute a track.") {
            HStack {
                Button(batchNoun == "ticked" ? "Make \(outro ? "outros" : "intros") for all \(ticked.count) ticked"
                       : "Make \(outro ? "outros" : "intros") for all \(ticked.count) \(batchNoun)\(ticked.count == 1 ? "" : "s")") {
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
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text("\(batch.finished.count) made, \(batch.failures.count) failed.")
                        .font(.callout).foregroundStyle(.secondary)
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
        panel.message = outro ? "Where should the outro edits go?" : "Where should the intro edits go?"
        if panel.runModal() == .OK, let url = panel.url {
            if outro { outroOutputOverride = url.path } else { outputOverride = url.path }
        }
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


private extension IntroPanel {
    static let styleHelp = """
        Build up brings the song's own drums in first, then the bass, then the rest of the \
        band, so the intro builds into the song. Full loop plays the whole instrumental from \
        the start. Beat runs only the song's own drums and bass under the whole intro: a \
        groove, with none of the other instruments. Underlay keeps the song's own opening as \
        it is and lays the drums and bass under it, building up to where the song's groove \
        lands; it needs the join set after an opening.
        """

    /// The picker's label for a style the tool named.
    static func styleName(_ style: String) -> String {
        switch style {
        case "beat": return "Beat"
        case "underlay": return "Underlay"
        case "full": return "Full loop"
        default: return "Build up"
        }
    }
}


// MARK: - Shared pieces

/// A titled, bordered section: the one container every group of controls in
/// the panel sits in, so they read as parts of one page.
struct PanelCard<Accessory: View, Content: View>: View {
    let title: String
    let subtitle: String?
    let accessory: Accessory
    let content: Content

    init(_ title: String, subtitle: String? = nil,
         @ViewBuilder accessory: () -> Accessory,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}

extension PanelCard where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// A small rounded label for one fact about something: a tempo, a vocal level.
struct Chip: View {
    let text: String
    let tint: Color

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint == .secondary ? Color.secondary : tint)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(tint.opacity(0.13), in: Capsule())
            .fixedSize()
    }
}

/// The left-hand label of a row of options.
struct OptionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).foregroundStyle(.secondary)
            .frame(width: 64, alignment: .leading)
    }
}

/// A pill that lights up when on, for choices where several can be on.
struct ChipToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 4) {
                if configuration.isOn { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                configuration.label
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .foregroundStyle(configuration.isOn ? Color.white : Color.primary)
            .background(configuration.isOn ? Color.accentColor : Color.secondary.opacity(0.14),
                        in: Capsule())
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }
}
