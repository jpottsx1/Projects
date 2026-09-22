import SwiftUI
import AppKit
import LoudnessKit

// MARK: - Choosing what to work on

/// The sources, not their contents.
///
/// This used to list every URL it was given, which meant that adding files
/// put a second copy of the track list in the left column -- the same names
/// the middle pane now shows, in a worse place, pushing the settings down
/// the window. So folders are listed, because a folder is a thing you
/// manage here, and files are rolled into one line, because the list of
/// them belongs in the list.
struct SourcePanel: View {
    @Binding var folders: [URL]

    private var directories: [URL] { folders.filter(SourcePanel.isFolder) }
    private var files: [URL] { folders.filter { !SourcePanel.isFolder($0) } }
    /// Folders, plus one line for however many loose files there are.
    private var sourceRows: Int { directories.count + (files.isEmpty ? 0 : 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Music").font(.headline)
                Spacer()
                // One click rather than one per folder. Seven folders
                // measured means seven minus buttons before a new one can
                // be looked at on its own, and the list in the middle pane
                // is sorted by low end -- so a folder added to an existing
                // set arrives interleaved through it rather than together.
                Button("Clear") { folders.removeAll() }
                    .buttonStyle(.link)
                    .disabled(folders.isEmpty)
                    .help("Remove every folder, to start on something else. "
                          + "Nothing measured is lost -- it stays in the "
                          + "library and comes back the moment the folder "
                          + "is added again.")
            }

            if folders.isEmpty {
                Text("No folders chosen.").font(.caption).foregroundStyle(.secondary)
            } else {
                // Bounded, so twenty folders cannot push the settings and
                // the Process button off the bottom of the window.
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(directories, id: \.self) { folder in
                            row(Image(systemName: "folder"),
                                folder.lastPathComponent) {
                                folders.removeAll { $0 == folder }
                            }
                        }
                        if !files.isEmpty {
                            row(Image(systemName: "music.note"),
                                "\(files.count) file\(files.count == 1 ? "" : "s")") {
                                folders.removeAll { !SourcePanel.isFolder($0) }
                            }
                        }
                    }
                }
                // An explicit height, because a ScrollView takes whatever it
                // is offered: given a range it would claim the full 108 for
                // a single folder and leave a gap under it.
                .frame(height: min(CGFloat(sourceRows) * 24 + 2, 110))
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

    private func row(_ icon: Image, _ label: String,
                     remove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            icon.foregroundStyle(.secondary).font(.caption)
            Text(label).lineLimit(1).truncationMode(.head)
            Spacer()
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove this from the run")
        }
        .font(.callout)
    }

    /// Asked of the file system rather than the URL. `hasDirectoryPath`
    /// reads the trailing slash, which is a fact about how the URL was
    /// spelled and not about what is on disk.
    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path,
                                                    isDirectory: &isDirectory)
        return exists ? isDirectory.boolValue : url.hasDirectoryPath
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
    @Binding var limited: Bool
    @Binding var compare: Bool
    @Binding var dryRun: Bool
    /// The folders already measured, for the reference list.
    let folders: [String]

    /// Marks the free-text row in the reference list. A path is not a
    /// folder label, so it cannot collide with a real one.
    static let otherReference = "\u{0000}other"

    @Environment(\.openWindow) private var openWindow
    @State private var typedReference = false

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

                // Listed from the profiles themselves. Typed out by hand,
                // a profile added to the kit stayed invisible in the app --
                // which is the same drift the help checker exists to catch,
                // one layer down.
                Picker("Profile", selection: $profileName) {
                    Text("none").tag("")
                    ForEach(Profile.builtIn.keys.sorted(), id: \.self) {
                        Text($0).tag($0)
                    }
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
                        slider(Help.declipMax, $profile.declipMax, 1...12, "dB",
                               // A clipped peak that needs more than
                               // 8 dB back is not a clipped peak.
                               sweet: 4...8)
                    }
                }

                Divider()

                slider(Help.amount, $profile.amount, 0...10, "dB",
                       // Measured deficits ran 4.8 to 10.9 dB; as one
                       // figure for everything, the middle of that.
                       sweet: 4...8)
                Text("31.5–63 Hz, laid under the kicks. Zero turns it off.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(Help.amount.detail)
                Toggle("Size it per track against a reference", isOn: $profile.auto)
                    .help(Help.auto.summary)
                if profile.auto {
                    referencePicker
                    if isTypedReference {
                        TextField("folder name or path", text: Binding(
                            get: { profile.reference ?? "" },
                            set: { profile.reference = $0 }))
                            .help(Help.reference.summary)
                    }
                    slider(Help.maxAmount, $profile.maxAmount, 1...12, "dB",
                           // disco-70s caps at 8, eighties at 11, both
                           // just above their measured worst.
                           sweet: 8...11)
                }
                slider(Help.minActivity, $profile.minActivity, 8...30, "dB",
                         // Static rumble swings about 11 dB, a real
                         // groove about 44. The judgement is between.
                         sweet: 16...22)

                Divider()

                slider(Help.punch, $profile.punch, 0...10, "dB",
                   // Off is the default and every profile keeps it
                   // there; past 4 dB it stops being an attack.
                   sweet: 0...4)
                if profile.punch > 0 {
                    slider(Help.punchDecay, $profile.punchDecay, 2...30, "ms",
                       // Default 8. Longer runs into the body of the
                       // kick and reads as a lift, not an attack.
                       sweet: 5...12)
                }

                Divider()

                slider(Help.targetLRA, $profile.targetLRA, 0...14, "LU",
                       // Off is the default. A squashed master measures 3
                       // to 5; past about 9 a track starts ducking under
                       // the next record, which for a DJ is the failure.
                       sweet: 0...9)
                Text("Widens the gap between the quiet parts and the loud "
                     + "ones, by pulling the quiet ones down. Zero turns it off.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(Help.targetLRA.detail)
                if profile.targetLRA > 0 {
                    slider(Help.maxAttenuation, $profile.maxAttenuation, 1...12, "dB",
                           // Past a few dB a quiet intro stops being quiet
                           // and starts being missing.
                           sweet: 3...6)
                }

                slider(Help.transient, $profile.transient, 0...8, "dB",
                       // About half a dB of crest comes back per dB asked
                       // for, measured. Past 4 it stops being an attack.
                       sweet: 0...4)
                if profile.transient > 0 {
                    slider(Help.minCrest, $profile.minCrest, 8...18, "dB",
                           // Limited hard measures 8-11; untouched, 13 up.
                           sweet: 11...14)
                }

                Divider()

                slider(Help.target, $profile.target, -24...(-8), "LUFS",
                       // Measured on this library: at -16 nothing needs
                       // a boost, at -14 almost nothing does.
                       sweet: (-16)...(-14))
                Picker("On", selection: $profile.estimator) {
                    ForEach(Profile.estimators, id: \.self) { Text($0).tag($0) }
                }
                .help(Help.estimator.summary)
                slider(Help.peakCeiling, $profile.peakCeiling, -6...0, "dBTP",
                       // -1 rather than -0.1: true-peak detection is
                       // only good to about 0.5 dB and MP3 moves peaks.
                       sweet: (-2)...(-1))

                Divider()

                HStack {
                    Toggle("Only the first", isOn: $limited)
                    Stepper("\(limit)", value: $limit, in: 1...500)
                        .disabled(!limited)
                    Text(limited ? "tracks" : "— all of them")
                        .foregroundStyle(.secondary)
                }
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
    /// The measured folders, plus a row for typing something else.
    ///
    /// A list rather than a text field because the names are long, exact,
    /// and already known -- "100 Hits - The New Romantics (2011)/Disc 4" is
    /// not something anyone should be asked to type, and a near miss
    /// silently resolves to nothing.
    private var referencePicker: some View {
        Picker("Against", selection: Binding(
            get: {
                let current = profile.reference ?? ""
                return folders.contains(current) ? current
                    : (current.isEmpty ? "" : SettingsPanel.otherReference)
            },
            set: { chosen in
                if chosen == SettingsPanel.otherReference {
                    // Keep whatever was typed; only switch the row.
                    if folders.contains(profile.reference ?? "") {
                        profile.reference = ""
                    }
                    typedReference = true
                } else {
                    typedReference = false
                    profile.reference = chosen
                }
            })) {
            Text("choose…").tag("")
            ForEach(folders, id: \.self) { Text($0).tag($0) }
            Divider()
            Text("Other…").tag(SettingsPanel.otherReference)
        }
        .help(Help.reference.summary)
    }

    private var isTypedReference: Bool {
        typedReference || (!(profile.reference ?? "").isEmpty
                           && !folders.contains(profile.reference ?? ""))
    }

    private func slider(_ help: HelpEntry, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, _ unit: String,
                        sweet: ClosedRange<Double>? = nil) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(help.title).frame(width: 92, alignment: .leading)
                Slider(value: value, in: range, step: 0.5)
                Text(String(format: "%+.1f %@", value.wrappedValue, unit))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(sweet.map { zone(value.wrappedValue, $0).colour }
                                     ?? .primary)
                    .frame(width: 78, alignment: .trailing)
            }
            if let sweet {
                HStack(spacing: 0) {
                    Spacer().frame(width: 96)
                    SettingsPanel.band(range: range, sweet: sweet)
                    Spacer().frame(width: 82)
                }
            }
        }
        .help(help.summary)
    }

    /// Where a value sits relative to what was measured.
    ///
    /// Not a judgement about taste: green is the range this project has
    /// evidence for, and the colours either side say which direction you
    /// have left it in. Blue is conservative -- the setting will do less
    /// than the measurements suggest it could. Orange and red are past
    /// what any corpus here supports, and red is where the setting starts
    /// doing something the stage was not built to do.
    enum Zone {
        case under, right, over, far
        var colour: Color {
            switch self {
            case .under: return .blue
            case .right: return .green
            case .over: return .orange
            case .far: return .red
            }
        }
    }

    func zone(_ value: Double, _ sweet: ClosedRange<Double>) -> Zone {
        if value < sweet.lowerBound { return .under }
        if value <= sweet.upperBound { return .right }
        // A quarter of the sweet spot's own width past it is still just
        // "more than measured"; beyond that it is a different setting.
        let slack = max((sweet.upperBound - sweet.lowerBound) * 0.5, 1.0)
        return value <= sweet.upperBound + slack ? .over : .far
    }

    /// The strip under a slider: blue, green where the evidence is, then
    /// orange and red.
    @ViewBuilder
    static func band(range: ClosedRange<Double>,
                     sweet: ClosedRange<Double>) -> some View {
        let span = max(range.upperBound - range.lowerBound, 0.0001)
        let start = min(max((sweet.lowerBound - range.lowerBound) / span, 0), 1)
        let end = min(max((sweet.upperBound - range.lowerBound) / span, 0), 1)
        LinearGradient(
            stops: [
                .init(color: .blue.opacity(0.55), location: 0),
                .init(color: .green.opacity(0.75), location: start),
                .init(color: .green.opacity(0.75), location: end),
                .init(color: .orange.opacity(0.7),
                      location: min(end + (1 - end) * 0.45, 0.999)),
                .init(color: .red.opacity(0.7), location: 1),
            ],
            startPoint: .leading, endPoint: .trailing)
            .frame(height: 3)
            .clipShape(Capsule())
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
