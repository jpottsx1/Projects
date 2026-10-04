import SwiftUI
import AppKit
import LoudnessKit

struct ContentView: View {
    /// Paths a host asked to be ticked once the queue has scanned, and the
    /// flag that makes that happen once rather than on every refresh — a
    /// run measures tracks and refreshes the queue, and re-imposing the
    /// host's original selection there would silently undo whatever the
    /// person had ticked since.
    private let initialInclude: Set<String>?
    private let initialIntroFocus: URL?
    @State private var didSeedSelection = false

    /// - Parameters:
    ///   - initialFolders: folders to scan on appear, for a host that
    ///     already knows what it wants worked on.
    ///   - initialInclude: paths to tick once that scan lands. Nil keeps
    ///     the queue's own default of everything it found.
    ///   - initialIntroFocus: open on the Intro tab with this track selected.
    init(initialFolders: [URL] = [], initialInclude: Set<String>? = nil,
         initialIntroFocus: URL? = nil) {
        self.initialInclude = initialInclude
        self.initialIntroFocus = initialIntroFocus
        _folders = State(initialValue: initialFolders)
        if initialIntroFocus != nil { _rightTab = State(initialValue: .intro) }
    }

    @Environment(\.openWindow) private var openWindow
    @StateObject private var engine = Engine()
    @StateObject private var player = ABPlayer()
    @StateObject private var queue = Queue()
    @StateObject private var personal = PersonalProfiles()
    @StateObject private var intro = IntroEngine()

    @State private var folders: [URL] = []
    @State private var profile = Profile()
    @State private var profileName = ""
    @State private var limit = 10
    /// Off by default: a folder added is a folder meant to be worked on,
    /// and a silent cap of ten on three hundred tracks is a surprise
    /// rather than a convenience.
    @State private var limited = false
    @State private var compare = true
    @State private var dryRun = false
    /// Never remembered between launches: replacing originals is asked
    /// for each time, and confirmed each time.
    @State private var replaceOriginals = false
    @State private var confirmingReplace = false
    @State private var chosen: Manifest.Track?
    @State private var blind = false
    @State private var rightTab = RightTab.survey
    @State private var wideWaveform = false
    @State private var confirmingClearOutput = false
    /// Set only when the search fails and the file is pointed at by hand.
    /// `@AppStorage` so the view redraws the moment it is chosen, and so
    /// the choice survives a restart -- being asked twice for the same
    /// answer is its own small insult.
    @AppStorage(CLI.overrideKey) private var cliOverride = ""
    @AppStorage("outputDirectory") private var outputOverride = ""
    @AppStorage("outputFormat") private var formatName = AudioWriter.Format.flac.rawValue

    /// Survey first, deliberately. You cannot choose a policy for a folder
    /// you have not looked at, and looking at it used to mean a terminal.
    enum RightTab: String, CaseIterable, Identifiable {
        case survey = "Survey", results = "Results", intro = "Intro"
        var id: String { rawValue }
    }

    /// Where processed files go. Changeable, because a DJ library does not
    /// live where an app would like it to.
    private var outputDirectory: URL {
        outputOverride.isEmpty ? defaultDirectory
            : URL(fileURLWithPath: outputOverride, isDirectory: true)
    }

    private var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/LoudnessLab", isDirectory: true)
    }

    /// The database does NOT follow the output directory.
    ///
    /// It holds every measurement ever taken, and pointing the output
    /// somewhere else for one run should not hide them. Moving with the
    /// output would mean a folder measured on Tuesday vanishing on
    /// Wednesday because the files were being written elsewhere.
    private var databaseURL: URL {
        defaultDirectory.appendingPathComponent("library.db")
    }

    private var format: AudioWriter.Format {
        AudioWriter.Format(rawValue: formatName) ?? .flac
    }

    var body: some View {
        HSplitView {
            // What to do.
            VStack(alignment: .leading, spacing: 14) {
                SourcePanel(folders: $folders)
                Divider()
                SettingsPanel(profile: $profile, profileName: $profileName,
                              limit: $limit, limited: $limited,
                              compare: $compare, dryRun: $dryRun,
                              replaceOriginals: $replaceOriginals,
                              personal: personal,
                              folders: engine.survey?.folders.map(\.folder) ?? [])
                Divider()
                runControls
            }
            .padding(16)
            .frame(minWidth: 330, idealWidth: 350, maxWidth: 420)

            // What it will be done to, and what came out of it -- split so
            // that widening the player below can spread under both rather
            // than being boxed into the results column alone.
            VStack(spacing: 0) {
                HSplitView {
                    QueuePanel(queue: queue, limit: limited ? limit : Int.max,
                               previewPlayer: intro.player, previewing: intro.playing,
                               onPreview: { path in
                                   player.stop()
                                   intro.togglePreview(path)
                               })
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)

                    // What the folders are, and what came out of them.
                    VStack(spacing: 0) {
                        Picker("", selection: $rightTab) {
                            ForEach(RightTab.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

                        switch rightTab {
                        case .survey:
                            SurveyPanel(
                                survey: engine.survey,
                                isMeasuring: engine.isRunning,
                                progress: engine.progress,
                                progressNote: engine.progressNote,
                                reference: Binding(get: { profile.reference ?? "" },
                                                   set: { profile.reference = $0 }),
                                onMeasure: measure,
                                onForget: { label in
                                    Task {
                                        await engine.forget(folder: label, folders: folders,
                                                            databaseURL: databaseURL,
                                                            reference: profile.reference)
                                    }
                                },
                                onForgetAll: {
                                    Task { await engine.forgetEverything(databaseURL: databaseURL) }
                                })
                        case .results:
                            ResultsPanel(manifest: engine.manifest, chosen: $chosen)
                        case .intro:
                            IntroPanel(engine: intro,
                                       ticked: queue.items.filter(\.included))
                        }
                        // The A/B player is for a processing run's versions;
                        // the Intro tab has its own player for its own files.
                        if !wideWaveform && rightTab != .intro {
                            Divider()
                            ComparePanel(player: player, track: chosen, blind: $blind,
                                         wide: $wideWaveform, estimator: profile.estimator)
                        }
                        Divider()
                        LogPanel(text: engine.log,
                                 failure: engine.failure ?? player.problem ?? intro.player.problem,
                                 collapsed: rightTab != .survey)
                    }
                    .frame(minWidth: 520)
                }
                if wideWaveform && rightTab != .intro {
                    Divider()
                    ComparePanel(player: player, track: chosen, blind: $blind,
                                 wide: $wideWaveform, estimator: profile.estimator)
                        .padding(.horizontal, 4)
                }
            }
        }
        .onChange(of: chosen) { _, track in loadIntoPlayer(track) }
        // Two players, one pair of ears: whichever tab is left stops.
        .onChange(of: rightTab) { old, new in
            if old == .intro { intro.stopPlaying() }
            if new == .intro { player.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .loudnessLabShowIntro)) { note in
            if let url = note.object as? URL { intro.focus(url.path) }
            rightTab = .intro
        }
        .onAppear {
            if let initialIntroFocus { intro.focus(initialIntroFocus.path) }
        }
        // The queue follows the folders, and refreshes after a run because
        // a run measures tracks that had no numbers before.
        .task(id: folders) {
            await queue.refresh(folders: folders, databaseURL: databaseURL)
            // Once, after the first scan: the host's selection can only be
            // applied to items that exist, and refresh is what creates them.
            if !didSeedSelection, let initialInclude {
                didSeedSelection = true
                queue.setAll(false)
                for path in initialInclude { queue.setIncluded(true, for: path) }
                queue.adopt(initialInclude.map { URL(fileURLWithPath: $0) })
            }
        }
        // Reads the library the moment a folder is added, rather than
        // waiting for Measure -- the reference picker's list is every
        // folder ever measured, and a brand new folder (with nothing of
        // its own yet) is exactly the case it exists to serve.
        .task(id: folders) {
            engine.refreshSurvey(folders: folders, databaseURL: databaseURL,
                                 reference: profile.reference)
        }
        // Changing the reference re-reads the library; it does not re-measure.
        .onChange(of: profile.reference) { _, name in
            engine.refreshSurvey(folders: folders, databaseURL: databaseURL,
                                 reference: name)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showHelp)) { _ in
            openWindow(id: "help")
        }
        .onReceive(NotificationCenter.default.publisher(for: .loudnessLabAddSources)) { note in
            guard let urls = note.object as? [URL] else { return }
            queue.adopt(urls)
        }
    }

    private var runControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(engine.isRunning ? "Running…" : "Process") {
                    if replaceOriginals { confirmingReplace = true } else { start() }
                }
                    .disabled(engine.isRunning || folders.isEmpty
                              || queue.includedPaths.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(replaceOriginals
                          ? "Measure, process the chosen folders, then put each "
                            + "finished track in its original's place (⌘↩). "
                            + "The originals are kept."
                          : "Measure, then process the chosen folders (⌘↩). "
                            + "Originals are never written to.")
                    .confirmationDialog(
                        "Replace the originals?",
                        isPresented: $confirmingReplace
                    ) {
                        Button("Process and Replace") { start() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Each finished \(format.rawValue.uppercased()) "
                             + "is put where its original was, same name, same "
                             + "folder. Originals in another format are left "
                             + "alone. Nothing is deleted: the originals are "
                             + "moved to Music › LoudnessLab › Replaced "
                             + "originals, and Restore Originals puts them "
                             + "back. Check one song's cue points in Serato "
                             + "before doing a whole library.")
                    }
                if engine.isRunning {
                    Button("Stop") { engine.cancel() }
                }
            }
            if engine.isRunning {
                // A bar with a number on it. "Running…" for four minutes
                // with nothing moving is indistinguishable from hung.
                VStack(alignment: .leading, spacing: 3) {
                    if let progress = engine.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(engine.progressNote ?? "Starting…")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if CLI.locate() == nil { toolMissing }
            output
            Text((replaceOriginals
                  ? "Originals will be replaced, and kept in Replaced originals. "
                  : "Originals are never written to. ")
                 + "Every version is rendered "
                 + "from one decode, which is what lets them be switched "
                 + "between mid-bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(Help.folders.detail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Where the results go, and in what.
    private var output: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Format", selection: $formatName) {
                ForEach(AudioWriter.Format.allCases, id: \.rawValue) {
                    Text($0.rawValue).tag($0.rawValue)
                }
            }
            .help(Help.format.summary)
            HStack(spacing: 6) {
                Text("To").frame(width: 24, alignment: .leading)
                Button(outputDirectory.lastPathComponent) {
                    // Nothing has necessarily been written yet -- a first
                    // launch with nothing processed has no folder to open
                    // otherwise, and "take me there" should not depend on
                    // having already run something.
                    try? FileManager.default.createDirectory(
                        at: outputDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(outputDirectory)
                }
                .buttonStyle(.link)
                .lineLimit(1).truncationMode(.head)
                .help("Open \(outputDirectory.path) in Finder")
                Spacer()
                Button("Change…") { chooseOutput() }
                    .buttonStyle(.link)
                Button("Clear") { confirmingClearOutput = true }
                    .buttonStyle(.link)
                    .foregroundStyle(.red)
                    .disabled(audioFilesInOutputDirectory.isEmpty)
                    .help("Delete every audio file in this folder. "
                          + "Anything else in it -- the manifest, "
                          + "anything you put there yourself -- is left "
                          + "alone.")
            }
            .font(.callout)
        }
        .help(Help.output.detail)
        .confirmationDialog(
            "Clear \(outputDirectory.lastPathComponent)?",
            isPresented: $confirmingClearOutput
        ) {
            Button("Delete \(audioFilesInOutputDirectory.count) File(s)",
                  role: .destructive) { clearOutputDirectory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every FLAC, MP3 and M4A file directly in this "
                 + "folder -- both sides of every A/B pair. The manifest "
                 + "and anything else in the folder are left as they "
                 + "are. This cannot be undone.")
        }
    }

    /// Every audio file sitting directly in the destination -- what
    /// `AudioWriter` itself ever writes there, both A and B of a pair,
    /// so this is exactly what "empty of audio, nothing else touched"
    /// needs to find.
    private var audioFilesInOutputDirectory: [URL] {
        let extensions = Set(AudioWriter.Format.allCases.map(\.fileExtension))
        let contents = try? FileManager.default.contentsOfDirectory(
            at: outputDirectory, includingPropertiesForKeys: nil)
        return (contents ?? []).filter { extensions.contains($0.pathExtension.lowercased()) }
    }

    private func clearOutputDirectory() {
        let files = audioFilesInOutputDirectory
        var removed = 0
        for file in files {
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        engine.say("Cleared \(removed) audio file(s) from "
                   + "\(outputDirectory.lastPathComponent).")
    }

    private func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Where should the processed files go?"
        if panel.runModal() == .OK, let url = panel.url {
            outputOverride = url.path
        }
    }

    /// Shown only when the tool cannot be found. The work is done by the
    /// command-line program, so without it the buttons below cannot do
    /// anything -- better to say that here, with the fix attached, than to
    /// let Measure fail and explain afterwards.
    private var toolMissing: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("The loudness-lab tool was not found.",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("It is the file called loudness-lab in the project folder, "
                 + "beside macapp.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose it…") { chooseTool() }
        }
        .padding(8)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func chooseTool() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the loudness-lab file in the project folder."
        if panel.runModal() == .OK, let url = panel.url {
            cliOverride = url.path
        }
    }

    /// Measuring is not processing: it reads the files, writes nothing, and
    /// answers what the folder is rather than what a profile would do to it.
    private func measure() {
        Task {
            await engine.measure(folders: folders, databaseURL: databaseURL,
                                 reference: profile.reference)
            await queue.refresh(folders: folders, databaseURL: databaseURL)
        }
    }

    private func start() {
        player.stop()
        chosen = nil
        Task {
            await engine.run(folders: folders, profile: profile,
                             limit: limited ? limit : Int.max,
                             compare: compare && !replaceOriginals,
                             dryRun: dryRun && !replaceOriginals,
                             outputDirectory: outputDirectory,
                             databaseURL: databaseURL, format: format,
                             only: queue.includedPaths,
                             replaceOriginals: replaceOriginals)
            chosen = engine.manifest?.tracks.first
            // Measurements exist now that did not before, so the order and
            // the numbers in the list are no longer the best available.
            await queue.refresh(folders: folders, databaseURL: databaseURL)
        }
    }

    private func loadIntoPlayer(_ track: Manifest.Track?) {
        // Stepping through the results with the arrow keys while listening
        // carries on listening: the next song starts from the top, on the
        // same side (A or B) that was playing (Jeff, 2026-09-28). Stopped
        // stays stopped.
        let wasPlaying = player.isPlaying
        let side = player.selected.flatMap { id in
            player.loaded.firstIndex { $0.id == id }
        }
        guard let track else { player.stop(); return }
        let gains = track.matchGains(using: estimatorPath)
        player.loadOrReport(track.variants.map {
            ABPlayer.Source(id: $0.id, label: $0.label, url: $0.url,
                            matchGainDB: gains[$0.id] ?? 0)
        })
        if let side, side < player.loaded.count {
            player.select(player.loaded[side].id)
        }
        if wasPlaying && !player.loaded.isEmpty { player.play() }
    }

    private var estimatorPath: KeyPath<Manifest.Variant, Double?> {
        profile.estimator == "lufs_i" ? \.lufsI : \.sP95
    }
}
