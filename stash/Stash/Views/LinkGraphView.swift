import SwiftUI
import StashCore

/// How items link to each other: a dot for each item that links or is
/// linked to, and a line for each link. Choosing a dot opens the item.
struct LinkGraphView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Item] = []
    @State private var links: [(Int, Int)] = []
    @State private var points: [LinkGraph.Point] = []
    @State private var hovered: Int?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack {
                    Canvas { context, canvasSize in
                        for (a, b) in links where a < points.count && b < points.count {
                            var line = Path()
                            line.move(to: position(a, in: canvasSize))
                            line.addLine(to: position(b, in: canvasSize))
                            let near = hovered == a || hovered == b || isSelected(a) || isSelected(b)
                            context.stroke(line, with: .color(near ? .accentColor : .secondary.opacity(0.35)),
                                           lineWidth: near ? 1.5 : 1)
                        }
                    }
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        if index < points.count {
                            node(item, index: index)
                                .position(position(index, in: size))
                        }
                    }
                }
            }
            .overlay {
                if !loaded {
                    ProgressView()
                } else if items.isEmpty {
                    ContentUnavailableView("No Links Yet", systemImage: "point.3.connected.trianglepath.dotted",
                                           description: Text("Link items with [[Title]] in a note, or Link to Item… in the side panel."))
                }
            }
            .navigationTitle("Link Graph")
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #endif
        }
        .task(id: library.revision) { await load() }
        .sheetSize(minWidth: 640, minHeight: 480)
    }

    private func node(_ item: Item, index: Int) -> some View {
        let selected = isSelected(index)
        return Button {
            library.show(item)
            #if os(iOS)
            dismiss()
            #endif
        } label: {
            VStack(spacing: 2) {
                Circle()
                    .fill(color(for: item))
                    .frame(width: selected ? 16 : 11, height: selected ? 16 : 11)
                    .overlay(Circle().stroke(Color.primary.opacity(selected ? 0.8 : 0), lineWidth: 2))
                Text(item.displayTitle)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 120)
                    .foregroundStyle(selected || hovered == index ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? index : (hovered == index ? nil : hovered) }
        .help(item.displayTitle)
        .accessibilityLabel(item.displayTitle)
    }

    private func isSelected(_ index: Int) -> Bool {
        index < items.count && items[index] == library.selection
    }

    private func color(for item: Item) -> Color {
        switch item.kind {
        case .note: .orange
        case .link: .blue
        case .document: .green
        }
    }

    private func position(_ index: Int, in size: CGSize) -> CGPoint {
        let point = points[index]
        return CGPoint(x: 40 + point.x * max(size.width - 80, 1), y: 30 + point.y * max(size.height - 60, 1))
    }

    private func load() async {
        let graph = library.linkGraph()
        let count = graph.items.count
        let links = graph.links
        // The layout is a few hundred rounds of arithmetic: off the main thread.
        let laidOut = await Task.detached(priority: .userInitiated) {
            LinkGraph.layout(count: count, edges: links)
        }.value
        items = graph.items
        self.links = links
        points = laidOut
        loaded = true
    }
}
