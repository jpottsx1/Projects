import SwiftUI
import LoudnessKit

/// The middle pane: what was found, in the order it will be worked through.
///
/// The ordering is the information. "10 tracks" from a folder of three
/// hundred means the ten with the thinnest low end, and that is not a thing
/// you can guess from a folder listing -- so the rows that will actually be
/// processed are marked, and the rest are visibly out of range rather than
/// absent.
struct QueuePanel: View {
    @ObservedObject var queue: Queue
    let limit: Int
    /// The path being previewed, if any, and what to do on the space bar.
    @ObservedObject var previewPlayer: ABPlayer
    var previewing: String?
    var onPreview: (String) -> Void = { _ in }

    /// How the list is shown. "Processing order" is the order the run works
    /// through and the "will process" limit counts from; artist and song only
    /// reorder what is on screen, so sorting never changes which tracks a
    /// limited run picks.
    enum SortOrder: String, CaseIterable, Identifiable {
        case processing = "Processing order", artist = "Artist", song = "Song"
        var id: String { rawValue }
    }
    @AppStorage("queueSortOrder") private var sortOrder = SortOrder.processing

    @State private var highlighted: String?
    @FocusState private var listFocused: Bool

    /// Artist and song from an "Artist - Song" name; a name without the
    /// separator is all song.
    private static func split(_ name: String) -> (artist: String, song: String) {
        guard let range = name.range(of: " - ") else { return ("", name) }
        return (String(name[..<range.lowerBound]), String(name[range.upperBound...]))
    }

    /// What the list shows, and what space/arrows walk through.
    private var shown: [Queue.Item] {
        guard sortOrder != .processing else { return queue.items }
        func order(_ a: String, _ b: String) -> ComparisonResult {
            a.localizedCaseInsensitiveCompare(b)
        }
        return queue.items.sorted { l, r in
            let (la, ls) = Self.split(l.name), (ra, rs) = Self.split(r.name)
            let (first, second) = sortOrder == .artist
                ? (order(la, ra), order(ls, rs)) : (order(ls, rs), order(la, ra))
            if first != .orderedSame { return first == .orderedAscending }
            if second != .orderedSame { return second == .orderedAscending }
            return l.path < r.path
        }
    }

    private var willProcess: Set<String> { queue.willProcess(limit: limit) }
    private var includedCount: Int { queue.items.filter(\.included).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if queue.items.isEmpty {
                empty
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(minWidth: 260)
        // A host that owns the keyboard (DiscoTags) drives the same actions.
        .onReceive(NotificationCenter.default.publisher(for: .loudnessLabTogglePreview)) { _ in
            togglePreview()
        }
        .onReceive(NotificationCenter.default.publisher(for: .loudnessLabSkipPreview)) { note in
            skip(by: note.object as? Double ?? 30)
        }
        .onReceive(NotificationCenter.default.publisher(for: .loudnessLabMoveHighlight)) { note in
            _ = move(note.object as? Int ?? 0)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("To process").font(.headline)
            if queue.scanning { ProgressView().controlSize(.small) }
            Spacer()
            Picker("Sort", selection: $sortOrder) {
                ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            .disabled(queue.items.isEmpty)
            .help("Sort the list by artist or song. This changes only how it is shown: "
                  + "which tracks a limited run picks still follows the processing order.")
            Button("All") { queue.setAll(true) }
                .buttonStyle(.link)
                .disabled(queue.items.isEmpty || includedCount == queue.items.count)
            Button("None") { queue.setAll(false) }
                .buttonStyle(.link)
                .disabled(includedCount == 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help(Help.queue.summary)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text(queue.scanning ? "Looking…" : "Add a folder to see what is in it.")
                .foregroundStyle(.secondary)
            if let note = queue.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(shown) { item in
                    row(item, inRange: willProcess.contains(item.path))
                        .contentShape(Rectangle())
                        .onTapGesture { highlighted = item.path; listFocused = true }
                    Divider()
                }
            }
        }
        // Space plays the highlighted track, arrows move the highlight.
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) { togglePreview() ? .handled : .ignored }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
    }

    @discardableResult
    private func togglePreview() -> Bool {
        guard let path = highlighted ?? shown.first?.path else { return false }
        highlighted = path
        onPreview(path)
        return true
    }

    /// fn key: jump the running preview ahead, clamped to the track's end.
    private func skip(by seconds: Double) {
        guard previewPlayer.isPlaying, previewPlayer.duration > 0 else { return }
        previewPlayer.seek(to: min(previewPlayer.position + seconds, previewPlayer.duration))
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let rows = shown
        guard !rows.isEmpty else { return .ignored }
        let at = rows.firstIndex { $0.path == highlighted } ?? (step > 0 ? -1 : rows.count)
        highlighted = rows[min(max(at + step, 0), rows.count - 1)].path
        return .handled
    }

    private func row(_ item: Queue.Item, inRange: Bool) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { item.included },
                set: { queue.setIncluded($0, for: item.path) }))
                .labelsHidden()
                .help("Leave this track out of the run")

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .lineLimit(1).truncationMode(.middle)
                    .fontWeight(inRange ? .semibold : .regular)
                HStack(spacing: 6) {
                    Text(item.folder).lineLimit(1).truncationMode(.head)
                    if let low = item.lowEndDB {
                        Text(String(format: "low %+.1f dB", low))
                    } else {
                        Text("not measured yet")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if previewPlayer.isPlaying && previewing == item.path {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
                    .help("Previewing. Space stops it.")
            }
            if let lufs = item.lufsI {
                Text(String(format: "%.1f", lufs))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        // Out of range is dimmed rather than hidden: the track IS in the
        // folder, and saying so is the difference between "not chosen" and
        // "not found", which are very different problems. Unticked is NOT
        // dimmed: the empty checkbox says it, and a greyed-out name after
        // "None" read as the tracks having gone somewhere (Jeff, 2026-09-28).
        .opacity(item.included && !inRange ? 0.45 : 1.0)
        .background(highlighted == item.path ? Color.accentColor.opacity(0.22)
                    : inRange && item.included ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(summary)
                .font(.caption)
            if let note = queue.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(Help.queue.detail)
    }

    private var summary: String {
        guard !queue.items.isEmpty else { return "Nothing found yet." }
        let marked = willProcess.count
        let found = queue.items.count
        let order = queue.items.contains(where: \.measured)
            ? "thinnest low end first"
            : "not measured yet, so this is name order until you press Process"
        return "\(marked) of \(found) will be processed — \(order)."
    }
}
