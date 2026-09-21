import SwiftUI
import AppKit
import LoudnessKit

// MARK: - Choosing what to work on

struct SourcePanel: View {
    @Binding var folders: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Music").font(.headline)
            if folders.isEmpty {
                Text("No folders chosen.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(folders, id: \.self) { folder in
                    HStack {
                        Text(folder.lastPathComponent).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button(action: { folders.removeAll { $0 == folder } }) {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.callout)
                }
            }
            HStack {
                Button("Add folder…") { pick(folders: true) { folders += $0 } }
                    .help(Help.folders.summary)
                Button("Add files…") { pick(folders: false) { folders += $0 } }
                    .help(Help.folders.summary)
            }
            Text("Measured into ~/Music/LoudnessLab. Nothing is written to "
                 + "the folders you choose.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(Help.folders.detail)
        }
    }

    private func pick(folders wantFolders: Bool, then apply: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = wantFolders
        panel.canChooseFiles = !wantFolders
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { apply(panel.urls) }
    }
}

// MARK: - The variables

struct SettingsPanel: View {
    @Binding var profile: Profile
    @Binding var profileName: String
    @Binding var limit: Int
    @Binding var compare: Bool
    @Binding var dryRun: Bool

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Settings").font(.headline)
                    Spacer()
                    // Every control below says what it does on hover. This
                    // opens the longer answer, including why the defaults
                    // are the numbers they are.
                    Button(action: { openWindow(id: "help") }) {
                        Image(systemName: "questionmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("What every setting does, and why (⌘?)")
                }

                Picker("Profile", selection: $profileName) {
                    Text("none").tag("")
                    Text("level-only").tag("level-only")
                    Text("restore").tag("restore")
                    Text("disco-70s").tag("disco-70s")
                }
                .help(Help.profile.summary)
                .onChange(of: profileName) { _, name in
                    // A profile replaces every setting at once, so that what
                    // is on screen is the policy being run and not a mixture
                    // of it and whatever was there before.
                    if let chosen = Profile.builtIn[name] { profile = chosen }
                }
                Text(profile.description.isEmpty
                     ? "A profile fixes what is allowed. How much each track "
                       + "gets still comes from measuring that track."
                     : profile.description)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(Help.profile.detail)

                Group {
                    Toggle("Restore clipped peaks", isOn: $profile.declip)
                        .help(Help.declip.summary)
                    if profile.declip {
                        slider(Help.declipMax, $profile.declipMax, 1...12, "dB")
                    }
                }

                Divider()

                slider(Help.amount, $profile.amount, 0...10, "dB")
                Text("31.5–63 Hz, laid under the kicks. Zero turns it off.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(Help.amount.detail)
                Toggle("Size it per track against a reference", isOn: $profile.auto)
                    .help(Help.auto.summary)
                if profile.auto {
                    TextField("reference folder", text: Binding(
                        get: { profile.reference ?? "" },
                        set: { profile.reference = $0 }))
                        .help(Help.reference.summary)
                    slider(Help.maxAmount, $profile.maxAmount, 1...12, "dB")
                }
                slider(Help.minActivity, $profile.minActivity, 8...30, "dB")

                Divider()

                slider(Help.punch, $profile.punch, 0...10, "dB")
                if profile.punch > 0 {
                    slider(Help.punchDecay, $profile.punchDecay, 2...30, "ms")
                }

                Divider()

                slider(Help.target, $profile.target, -24...(-8), "LUFS")
                Picker("On", selection: $profile.estimator) {
                    ForEach(Profile.estimators, id: \.self) { Text($0).tag($0) }
                }
                .help(Help.estimator.summary)
                slider(Help.peakCeiling, $profile.peakCeiling, -6...0, "dBTP")

                Divider()

                Stepper("Tracks: \(limit)", value: $limit, in: 1...500)
                    .help(Help.limit.summary)
                Toggle("Write A/B pairs", isOn: $compare)
                    .help(Help.compare.summary)
                Toggle("Dry run (measure, write nothing)", isOn: $dryRun)
                    .help(Help.dryRun.summary)
            }
        }
    }

    /// Takes a help entry rather than a string, so the label and the
    /// explanation cannot come apart -- and so a new slider cannot be added
    /// without someone having to write down what it does.
    private func slider(_ help: HelpEntry, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, _ unit: String) -> some View {
        HStack {
            Text(help.title).frame(width: 92, alignment: .leading)
            Slider(value: value, in: range, step: 0.5)
            Text(String(format: "%+.1f %@", value.wrappedValue, unit))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 78, alignment: .trailing)
        }
        .help(help.summary)
    }
}

// MARK: - What came out

struct ResultsPanel: View {
    let manifest: Manifest?
    @Binding var chosen: Manifest.Track?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let manifest {
                Table(manifest.tracks, selection: Binding(
                    get: { chosen.map { Set([$0.id]) } ?? [] },
                    set: { ids in chosen = manifest.tracks.first { ids.contains($0.id) } })) {
                    TableColumn("Track", value: \.name)
                    TableColumn("Sub") { Text(String(format: "%+.2f dB", $0.subDB)) }
                    TableColumn("Punch") { Text(String(format: "%+.1f dB", $0.punchDB)) }
                    TableColumn("Clips") { Text("\($0.clipsRestored)") }
                    TableColumn("Lift") { Text(String(format: "%+.2f dB", $0.clipLiftDB)) }
                }
                .help(Help.results.detail)
            } else {
                Text("Nothing processed yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minHeight: 180)
    }
}

struct LogPanel: View {
    let text: String
    let failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout).padding(.horizontal, 8)
            }
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .frame(minHeight: 120, maxHeight: 200)
    }
}
