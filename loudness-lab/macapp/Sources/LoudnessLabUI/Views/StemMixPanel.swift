import SwiftUI

/// The stem mix, as a sheet over the window: four stem faders, Bass and
/// Air, a transport, and Commit or Cancel. See `StemMixSession` and
/// `Help.stemMix` for what happens underneath.
struct StemMixPanel: View {
    @StateObject private var session: StemMixSession
    /// The processing command for the current settings, without a selection.
    let arguments: () -> [String]
    let bassSub: Bool
    /// A processing run is already going: Commit waits for it.
    let busy: Bool
    /// Processes this track with the choice file attached; nil once
    /// written, or why not.
    let commit: (URL) async -> String?
    let close: () -> Void

    init(path: String, arguments: @escaping () -> [String], bassSub: Bool, busy: Bool,
         commit: @escaping (URL) async -> String?, close: @escaping () -> Void) {
        _session = StateObject(wrappedValue: StemMixSession(path: path))
        self.arguments = arguments
        self.bassSub = bassSub
        self.busy = busy
        self.commit = commit
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stem Mix").font(.title3.bold())
                Text(session.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(20)
        .frame(width: 560)
        .task { await session.prepare(arguments: arguments(), bassSub: bassSub) }
        .onDisappear { session.cancel() }
        .help(Help.stemMix.summary)
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .idle, .preparing:
            VStack(alignment: .leading, spacing: 10) {
                ProgressView()
                Text("Splitting the track into drums, bass, melody and vocals, "
                     + "and laying out the sub and the air. About a minute.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons(ready: false)
        case .failed(let message):
            Text(message).font(.callout).foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { session.cancel(); close() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") {
                    Task { await session.prepare(arguments: arguments(), bassSub: bassSub) }
                }
            }
        case .ready, .committing:
            if let bundle = session.bundle {
                Transport(player: session.player)
                mixer(bundle)
                Text("Nothing is written until Commit. Commit writes this mix "
                     + "with the current settings' format and output folder, "
                     + "levelled to the target like every finished track.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem = session.problem {
                Text(problem).font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if session.phase == .committing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing the track…").font(.callout)
                }
            }
            buttons(ready: session.phase == .ready)
        case .committed:
            Text("Written. It is in the Results tab, ready to compare.")
                .font(.callout)
            HStack {
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func buttons(ready: Bool) -> some View {
        HStack {
            Button("Reset") { session.reset() }
                .disabled(!ready || !session.hasChanged)
                .help("Every stem back to 0 dB, Bass and Air back to what the settings give this track.")
            Spacer()
            Button("Cancel") { session.cancel(); close() }
                .keyboardShortcut(.cancelAction)
                .help("Close without writing anything. The stems are thrown away.")
            Button("Commit") {
                Task { await session.commit(run: commit) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!ready || busy)
            .help(busy ? "A run is going; Commit when it has finished."
                  : "Write this track with these levels, this Bass and this Air.")
        }
    }

    private func mixer(_ bundle: StemMix.Bundle) -> some View {
        let limits = bundle.limits
        return VStack(alignment: .leading, spacing: 10) {
            GroupBox("Stems") {
                VStack(spacing: 6) {
                    ForEach(StemMix.stems, id: \.self) { stem in
                        control(StemMix.label(stem), value: level(stem),
                                range: limits.floorDB...limits.levelMaxDB,
                                readout: StemMix.readout(level(stem).wrappedValue,
                                                         floor: limits.floorDB),
                                zero: 0)
                    }
                }
                .padding(4)
            }
            GroupBox("Enhancement") {
                VStack(alignment: .leading, spacing: 6) {
                    control("Bass", value: amount(\.subDB), range: 0...limits.subMaxDB,
                            readout: String(format: "+%.1f dB", session.choice?.subDB ?? 0),
                            zero: bundle.defaults.subDB, enabled: bundle.sub.available)
                    if !bundle.sub.available {
                        note("No sub for this track: \(bundle.sub.note ?? "nothing to put it under").")
                    }
                    control("Air", value: amount(\.airDB), range: 0...limits.airMaxDB,
                            readout: String(format: "+%.1f dB", session.choice?.airDB ?? 0),
                            zero: bundle.defaults.airDB, enabled: bundle.air.available)
                    if !bundle.air.available {
                        note("No air for this track: \(bundle.air.note ?? "nothing to make it from").")
                    }
                }
                .padding(4)
            }
        }
        .disabled(session.phase != .ready)
    }

    /// One labelled slider. Double-clicking the reading puts it back.
    private func control(_ label: String, value: Binding<Double>, range: ClosedRange<Double>,
                         readout: String, zero: Double, enabled: Bool = true) -> some View {
        HStack(spacing: 10) {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
            Text(readout)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 76, alignment: .trailing)
                .onTapGesture(count: 2) { value.wrappedValue = zero }
                .help("Double-click to put this back")
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func level(_ stem: String) -> Binding<Double> {
        Binding(get: { session.choice?.levelsDB[stem] ?? 0 },
                set: { session.choice?.levelsDB[stem] = ($0 * 10).rounded() / 10 })
    }

    private func amount(_ key: WritableKeyPath<StemMix.Choice, Double>) -> Binding<Double> {
        Binding(get: { session.choice?[keyPath: key] ?? 0 },
                set: { session.choice?[keyPath: key] = ($0 * 10).rounded() / 10 })
    }
}

/// Play, pause and where we are, for the stem mix's player.
private struct Transport: View {
    @ObservedObject var player: ABPlayer

    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.isPlaying ? player.pause() : player.play(from: player.position)
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play or pause the mix (Space)")
            Slider(value: Binding(get: { player.position },
                                  set: { player.seek(to: $0) }),
                   in: 0...max(player.duration, 0.1))
            Text(Self.time(player.position) + " / " + Self.time(player.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if let problem = player.problem {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    .help(problem)
            }
        }
    }

    static func time(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
