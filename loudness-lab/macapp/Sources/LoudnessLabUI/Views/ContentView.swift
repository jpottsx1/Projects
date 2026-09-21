import SwiftUI
import AppKit
import LoudnessKit

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var engine = Engine()
    @StateObject private var player = ABPlayer()
    @StateObject private var queue = Queue()

    @State private var folders: [URL] = []
    @State private var profile = Profile()
    @State private var profileName = ""
    @State private var limit = 10
    @State private var compare = true
    @State private var dryRun = false
    @State private var chosen: Manifest.Track?
    @State private var blind = false
    @State private var rightTab = RightTab.survey
    /// Set only when the search fails and the file is pointed at by hand.
    /// `@AppStorage` so the view redraws the moment it is chosen, and so
    /// the choice survives a restart -- being asked twice for the same
    /// answer is its own small insult.
    @AppStorage(CLI.overrideKey) private var cliOverride = ""

    /// Survey first, deliberately. You cannot choose a policy for a folder
    /// you have not looked at, and looking at it used to mean a terminal.
    enum RightTab: String, CaseIterable, Identifiable {
        case survey = "Survey", results = "Results"
        var id: String { rawValue }
    }

    private var outputDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/LoudnessLab", isDirectory: true)
    }
    private var databaseURL: URL {
        outputDirectory.appendingPathComponent("library.db")
    }

    var body: some View {
        HSplitView {
            // What to do.
            VStack(alignment: .leading, spacing: 14) {
                SourcePanel(folders: $folders)
                Divider()
                SettingsPanel(profile: $profile, profileName: $profileName,
                              limit: $limit, compare: $compare, dryRun: $dryRun)
                Divider()
                runControls
            }
            .padding(16)
            .frame(minWidth: 330, idealWidth: 350, maxWidth: 420)

            // What it will be done to.
            QueuePanel(queue: queue, limit: limit)
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
                        onMeasure: measure)
                case .results:
                    ResultsPanel(manifest: engine.manifest, chosen: $chosen)
                }
                Divider()
                ComparePanel(player: player, track: chosen, blind: $blind,
                             estimator: profile.estimator)
                Divider()
                LogPanel(text: engine.log, failure: engine.failure ?? player.problem)
            }
            .frame(minWidth: 520)
        }
        .onChange(of: chosen) { _, track in loadIntoPlayer(track) }
        // The queue follows the folders, and refreshes after a run because
        // a run measures tracks that had no numbers before.
        .task(id: folders) { await queue.refresh(folders: folders,
                                                 databaseURL: databaseURL) }
        // Changing the reference re-reads the library; it does not re-measure.
        .onChange(of: profile.reference) { _, name in
            engine.refreshSurvey(folders: folders, databaseURL: databaseURL,
                                 reference: name)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showHelp)) { _ in
            openWindow(id: "help")
        }
    }

    private var runControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(engine.isRunning ? "Running…" : "Process") { start() }
                    .disabled(engine.isRunning || folders.isEmpty
                              || queue.includedPaths.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Measure, then process the chosen folders (⌘↩). "
                          + "Originals are never written to.")
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
            Text("Originals are never written to. Every version is rendered "
                 + "from one decode, which is what lets them be switched "
                 + "between mid-bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(Help.folders.detail)
                .fixedSize(horizontal: false, vertical: true)
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
            await engine.run(folders: folders, profile: profile, limit: limit,
                             compare: compare, dryRun: dryRun,
                             outputDirectory: outputDirectory,
                             databaseURL: databaseURL,
                             only: queue.includedPaths)
            chosen = engine.manifest?.tracks.first
            // Measurements exist now that did not before, so the order and
            // the numbers in the list are no longer the best available.
            await queue.refresh(folders: folders, databaseURL: databaseURL)
        }
    }

    private func loadIntoPlayer(_ track: Manifest.Track?) {
        guard let track else { player.stop(); return }
        let gains = track.matchGains(using: estimatorPath)
        player.loadOrReport(track.variants.map {
            ABPlayer.Source(id: $0.id, label: $0.label, url: $0.url,
                            matchGainDB: gains[$0.id] ?? 0)
        })
    }

    private var estimatorPath: KeyPath<Manifest.Variant, Double?> {
        profile.estimator == "lufs_i" ? \.lufsI : \.sP95
    }
}
