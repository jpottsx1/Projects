import AppIntents
import SwiftUI
import WidgetKit
import StashCore

/// Stash on the Home Screen and the Mac desktop: recent items, favorites
/// or reminders, and a button for a new note.
///
/// Widgets can't open the library, so they read what the app writes into
/// the App Group (`WidgetSnapshot`) -- which needs `SHARE_EXTENSION` on in
/// Config/Stash.xcconfig. Without it the widget says so.
@main
struct StashWidgets: WidgetBundle {
    var body: some Widget {
        StashListWidget()
    }
}

enum WidgetList: String, AppEnum {
    case recent, favorites, reminders

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "List"
    static let caseDisplayRepresentations: [WidgetList: DisplayRepresentation] = [
        .recent: "Recent", .favorites: "Favorites", .reminders: "Reminders",
    ]

    var name: String {
        switch self {
        case .recent: "Recent"
        case .favorites: "Favorites"
        case .reminders: "Reminders"
        }
    }

    var symbol: String {
        switch self {
        case .recent: "clock"
        case .favorites: "star"
        case .reminders: "bell"
        }
    }
}

struct ListConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Stash List"
    static let description = IntentDescription("Recent items, favorites or reminders from Stash.")

    @Parameter(title: "Show", default: .recent) var list: WidgetList
}

struct ListEntry: TimelineEntry {
    let date: Date
    let list: WidgetList
    /// Nil when the app hasn't written anything the widget can read.
    let snapshot: WidgetSnapshot?

    var items: [WidgetSnapshot.Entry] {
        switch list {
        case .recent: snapshot?.recent ?? []
        case .favorites: snapshot?.favorites ?? []
        case .reminders: snapshot?.reminders ?? []
        }
    }
}

struct ListProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ListEntry {
        ListEntry(date: .now, list: .recent, snapshot: WidgetSnapshot(updatedAt: .now, recent: [
            .init(id: UUID(), title: "Trip plans", kind: "note", subtitle: "Flights and hotels"),
            .init(id: UUID(), title: "Sourdough", kind: "link", subtitle: "en.wikipedia.org"),
            .init(id: UUID(), title: "Lease", kind: "document", subtitle: "PDF document"),
        ]))
    }

    func snapshot(for configuration: ListConfiguration, in context: Context) async -> ListEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: ListConfiguration, in context: Context) async -> Timeline<ListEntry> {
        // The app asks for a new timeline when things change; this is a fallback.
        Timeline(entries: [entry(for: configuration)], policy: .after(.now.addingTimeInterval(30 * 60)))
    }

    private func entry(for configuration: ListConfiguration) -> ListEntry {
        ListEntry(date: .now, list: configuration.list, snapshot: WidgetSnapshot.folder().flatMap(WidgetSnapshot.read))
    }
}

struct StashListWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "StashList", intent: ListConfiguration.self, provider: ListProvider()) { entry in
            ListWidgetView(entry: entry)
        }
        .configurationDisplayName("Stash")
        .description("Recent items, favorites or reminders, and a new note.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ListWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ListEntry

    private var count: Int {
        switch family {
        case .systemSmall: 3
        case .systemLarge: 8
        default: 4
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(entry.list.name, systemImage: entry.list.symbol)
                    .font(.caption.bold())
                    .foregroundStyle(.tint)
                Spacer()
                if family != .systemSmall {
                    Link(destination: WidgetSnapshot.newNoteURL) {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New Note")
                }
            }
            if entry.snapshot == nil {
                Text("Open Stash to fill this in. Widgets need the App Group that sharing uses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if entry.items.isEmpty {
                Text(entry.list == .reminders ? "No reminders." : "Nothing here yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(entry.items.prefix(count)) { item in
                row(item)
            }
            Spacer(minLength: 0)
        }
        .containerBackground(.fill.tertiary, for: .widget)
        // A small widget is one button: the first item, or a new note.
        .widgetURL(family == .systemSmall
                   ? entry.items.first.map { WidgetSnapshot.itemURL($0.id) } ?? WidgetSnapshot.newNoteURL
                   : nil)
    }

    @ViewBuilder
    private func row(_ item: WidgetSnapshot.Entry) -> some View {
        let content = HStack(spacing: 6) {
            Image(systemName: symbol(for: item.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .font(.subheadline)
                    .lineLimit(1)
                if family != .systemSmall {
                    if let date = item.date {
                        Text(date, format: .dateTime.weekday(.abbreviated).hour().minute())
                            .font(.caption2)
                            .foregroundStyle(date <= .now ? .red : .secondary)
                    } else if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        if family == .systemSmall {
            content
        } else {
            Link(destination: WidgetSnapshot.itemURL(item.id)) { content }
        }
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case "link": "link"
        case "document": "doc"
        default: "note.text"
        }
    }
}
