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
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("To process").font(.headline)
            if queue.scanning { ProgressView().controlSize(.small) }
            Spacer()
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
                ForEach(queue.items) { item in
                    row(item, inRange: willProcess.contains(item.path))
                    Divider()
                }
            }
        }
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
        // "not found", which are very different problems.
        .opacity(item.included ? (inRange ? 1.0 : 0.45) : 0.3)
        .background(inRange && item.included
                    ? Color.accentColor.opacity(0.08) : Color.clear)
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
