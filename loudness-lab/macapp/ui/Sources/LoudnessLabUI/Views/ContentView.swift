import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var runner = CLIRunner()
    @StateObject private var player = ABPlayer()

    @State private var folders: [URL] = []
    @State private var settings = Settings()
    @State private var profile: String = ""
    @State private var limit = 10
    @State private var compare = true
    @State private var dryRun = false
    @State private var outputDirectory: URL?
    @State private var chosen: Manifest.Track?
    @State private var blind = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                SourcePanel(folders: $folders, toolRoot: $runner.toolRoot)
                Divider()
                SettingsPanel(settings: $settings, profile: $profile,
                              limit: $limit, compare: $compare, dryRun: $dryRun)
                Divider()
                runControls
            }
            .padding(16)
            .frame(minWidth: 330, maxWidth: 400)

            VStack(spacing: 0) {
                ResultsPanel(manifest: runner.manifest, chosen: $chosen)
                Divider()
                ComparePanel(player: player, track: chosen, blind: $blind,
                             estimator: settings.estimator)
                Divider()
                LogPanel(text: runner.log, failure: runner.failure ?? player.problem)
            }
            .frame(minWidth: 560)
        }
        .onChange(of: chosen) { _, track in loadIntoPlayer(track) }
    }

    private var runControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(runner.isRunning ? "Running…" : "Process") { start() }
                    .disabled(runner.isRunning || folders.isEmpty || runner.toolRoot == nil)
                    .keyboardShortcut(.return, modifiers: .command)
                if runner.isRunning {
                    Button("Stop") { runner.cancel() }
                    ProgressView().controlSize(.small)
                }
            }
            Text("Originals are never written to. Every version is rendered "
                 + "from one decode, which is what lets them be switched "
                 + "between mid-bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func start() {
        let destination = outputDirectory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Music/LoudnessLab", isDirectory: true)
        outputDirectory = destination
        player.stop()
        chosen = nil
        Task {
            await runner.run(folders: folders, settings: settings,
                             profile: profile.isEmpty ? nil : profile,
                             limit: limit, compare: compare, dryRun: dryRun,
                             outputDirectory: destination)
            chosen = runner.manifest?.tracks.first
        }
    }

    private func loadIntoPlayer(_ track: Manifest.Track?) {
        guard let track else { player.stop(); return }
        let gains = track.matchGains(using: estimatorPath)
        let sources = track.variants.map {
            ABPlayer.Source(id: $0.id, label: $0.label, url: $0.url,
                            matchGainDB: gains[$0.id] ?? 0)
        }
        player.loadOrReport(sources)
    }

    private var estimatorPath: KeyPath<Manifest.Variant, Double?> {
        settings.estimator == "lufs_i" ? \.lufsI : \.sP95
    }
}
