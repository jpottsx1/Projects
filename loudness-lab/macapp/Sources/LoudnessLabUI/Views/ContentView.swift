import SwiftUI
import LoudnessKit

struct ContentView: View {
    @StateObject private var engine = Engine()
    @StateObject private var player = ABPlayer()

    @State private var folders: [URL] = []
    @State private var profile = Profile()
    @State private var profileName = ""
    @State private var limit = 10
    @State private var compare = true
    @State private var dryRun = false
    @State private var chosen: Manifest.Track?
    @State private var blind = false

    private var outputDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/LoudnessLab", isDirectory: true)
    }
    private var databaseURL: URL {
        outputDirectory.appendingPathComponent("library.db")
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                SourcePanel(folders: $folders)
                Divider()
                SettingsPanel(profile: $profile, profileName: $profileName,
                              limit: $limit, compare: $compare, dryRun: $dryRun)
                Divider()
                runControls
            }
            .padding(16)
            .frame(minWidth: 330, maxWidth: 400)

            VStack(spacing: 0) {
                ResultsPanel(manifest: engine.manifest, chosen: $chosen)
                Divider()
                ComparePanel(player: player, track: chosen, blind: $blind,
                             estimator: profile.estimator)
                Divider()
                LogPanel(text: engine.log, failure: engine.failure ?? player.problem)
            }
            .frame(minWidth: 560)
        }
        .onChange(of: chosen) { _, track in loadIntoPlayer(track) }
    }

    private var runControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(engine.isRunning ? "Running…" : "Process") { start() }
                    .disabled(engine.isRunning || folders.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                if engine.isRunning {
                    Button("Stop") { engine.cancel() }
                    if let progress = engine.progress {
                        ProgressView(value: progress).frame(width: 90)
                    } else {
                        ProgressView().controlSize(.small)
                    }
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
        player.stop()
        chosen = nil
        Task {
            await engine.run(folders: folders, profile: profile, limit: limit,
                             compare: compare, dryRun: dryRun,
                             outputDirectory: outputDirectory,
                             databaseURL: databaseURL)
            chosen = engine.manifest?.tracks.first
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
