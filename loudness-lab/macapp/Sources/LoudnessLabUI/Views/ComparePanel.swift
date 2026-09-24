import SwiftUI

/// The transport, and the switch.
///
/// Two things here are deliberate rather than decorative. The version buttons
/// do not stop or seek anything -- every version is already playing, and the
/// button only decides which one you hear, so the bar you are in continues
/// through the switch. And blind mode exists because knowing which one is
/// the processed version is worth a couple of dB of imagined improvement;
/// the tool has said so in its own output from the beginning, and a UI that
/// labels the buttons hands that bias straight back.
struct ComparePanel: View {
    @ObservedObject var player: ABPlayer
    let track: Manifest.Track?
    @Binding var blind: Bool
    /// Spreads this whole panel under the queue list too, for a track
    /// whose waveform needs more than the results column's own width.
    @Binding var wide: Bool
    let estimator: String

    @State private var shuffled: [String] = []
    @State private var revealed = false
    @State private var scrubbing = false
    @State private var scrubPosition: Double = 0
    /// Keyed by variant path, so switching between two already-looked-at
    /// tracks is instant and re-picking the same one never re-decodes.
    @State private var envelopes: [String: WaveformEnvelope] = [:]
    @State private var waveformMode: WaveformView.Mode = .overlay

    var body: some View {
        VStack(spacing: 10) {
            if let track {
                Text(track.name).font(.headline)
                transport
                waveform(track)
                scrubber
                versions(track)
                footnote
            } else {
                Text("Pick a track above to compare.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(14)
        .onChange(of: track?.id) { _, _ in reshuffle() }
        .onReceive(NotificationCenter.default.publisher(for: .switchVersion)) { _ in
            player.selectNext()
        }
    }

    /// The original's shape, and -- once revealed -- what this run added
    /// on top of it, in the same bass/mid/treble colors a mixer's own
    /// overview waveform uses. Loaded per track rather than for the whole
    /// queue at once: decoding is real work, and most tracks in a batch
    /// are never opened here at all.
    private func waveform(_ track: Manifest.Track) -> some View {
        let original = track.variants.first { $0.kind == "original" } ?? track.variants.first
        let processed = track.variants.first { $0.kind == "processed" }
        let originalEnvelope = original.flatMap { envelopes[$0.id] }
        let processedEnvelope = processed.flatMap { envelopes[$0.id] }
        let hasComparison = processed != nil && processed?.id != original?.id
        let showDifference = !blind || revealed
        return VStack(alignment: .leading, spacing: 4) {
            if hasComparison, showDifference {
                Picker("", selection: $waveformMode) {
                    ForEach(WaveformView.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .help("Overlay shows what changed on top of the original's "
                      + "shape. Compare stacks both full waveforms, "
                      + "original above processed, so a level or shape "
                      + "difference is literal rather than tinted.")
            }
            if let originalEnvelope {
                WaveformView(
                    original: originalEnvelope,
                    processed: processed?.id == original?.id ? nil : processedEnvelope,
                    mode: waveformMode,
                    showDifference: showDifference,
                    progress: player.duration > 0 ? player.position / player.duration : 0,
                    onSeek: { player.seek(to: $0 * player.duration) })
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.85))
                    .frame(height: WaveformView.height)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: track.id) { await loadEnvelopes(for: track) }
    }

    private func loadEnvelopes(for track: Manifest.Track) async {
        for variant in track.variants where envelopes[variant.id] == nil {
            if let envelope = try? await WaveformAnalyzer.analyze(variant.url) {
                envelopes[variant.id] = envelope
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button(action: {
                player.isPlaying ? player.pause() : player.play(from: player.position)
            }) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .font(.title2)
            Button(action: { player.stop() }) { Image(systemName: "stop.fill") }
            Spacer()
            Toggle("Widen", isOn: $wide)
                .toggleStyle(.switch)
                .help("Spread this panel under the queue list as well, "
                      + "for more room to see the waveform in.")
            Toggle("Match loudness", isOn: $player.matchLoudness)
                .toggleStyle(.switch)
                .help(Help.matchLoudness.summary)
            Toggle("Blind", isOn: $blind)
                .toggleStyle(.switch)
                .help(Help.blind.summary)
                .onChange(of: blind) { _, _ in reshuffle() }
        }
    }

    private var scrubber: some View {
        HStack {
            Text(clock(player.position))
                .font(.system(.caption, design: .monospaced))
            Slider(value: Binding(
                get: { scrubbing ? scrubPosition : player.position },
                set: { scrubPosition = $0 }),
                   in: 0...max(player.duration, 0.1),
                   onEditingChanged: { editing in
                       scrubbing = editing
                       if !editing { player.seek(to: scrubPosition) }
                   })
            Text(clock(player.duration))
                .font(.system(.caption, design: .monospaced))
        }
    }

    private func versions(_ track: Manifest.Track) -> some View {
        let order = blind && !shuffled.isEmpty
            ? shuffled.compactMap { id in track.variants.first { $0.id == id } }
            : track.variants
        return HStack(spacing: 10) {
            ForEach(Array(order.enumerated()), id: \.element.id) { index, variant in
                Button {
                    player.select(variant.id)
                } label: {
                    VStack(spacing: 2) {
                        Text(caption(for: variant, at: index))
                            .fontWeight(player.selected == variant.id ? .semibold : .regular)
                        if !blind || revealed, let level = variant.sP95 {
                            Text(String(format: "%.1f LUFS s_p95", level))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(player.selected == variant.id ? .accentColor : .gray.opacity(0.35))
                .keyboardShortcut(shortcut(for: index), modifiers: [])
                .help(Help.switching.summary)
            }
        }
    }

    private var footnote: some View {
        VStack(spacing: 2) {
            Text("Shift-Space switches. Nothing seeks: every version is "
                 + "playing already, so the switch lands mid-bar.")
                .help(Help.switching.detail)
            if blind {
                HStack(spacing: 8) {
                    Text("Order is shuffled per track.")
                    Button(revealed ? "Hide" : "Reveal") { revealed.toggle() }
                        .buttonStyle(.link)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Number keys for the first nine versions; beyond that, none, rather
    /// than a Character built from two digits, which traps.
    private func shortcut(for index: Int) -> KeyEquivalent {
        index < 9 ? KeyEquivalent(Character("\(index + 1)")) : .clear
    }

    private func caption(for variant: Manifest.Variant, at index: Int) -> String {
        (blind && !revealed) ? "\(index + 1)" : variant.label
    }

    private func reshuffle() {
        revealed = false
        shuffled = (track?.variants.map(\.id) ?? []).shuffled()
    }

    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
