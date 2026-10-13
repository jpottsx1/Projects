import SwiftUI
import StashCore

/// Keep It's tag filter, above the list: the tags chosen, then the tags the
/// items shown also have, most used first. Choosing one narrows the list
/// to items with it too; it works with the search and the sidebar.
struct TagFilterBar: View {
    @Environment(Library.self) private var library
    let items: [Item]

    var body: some View {
        let related = library.relatedTags(among: items)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "tag").foregroundStyle(.secondary)
                ForEach(library.tagFilter, id: \.self) { name in
                    Button {
                        library.toggleTagFilter(name)
                    } label: {
                        Label("#" + name, systemImage: "xmark.circle.fill")
                            .labelStyle(TrailingIconLabelStyle())
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("tagFilterChosen-\(name)")
                }
                if related.isEmpty, library.tagFilter.isEmpty {
                    Text("No tags on the items shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(related.prefix(40), id: \.tag) { tag in
                    Button {
                        library.toggleTagFilter(tag.tag)
                    } label: {
                        Text("#\(tag.tag) ") + Text("\(tag.count)").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("tagFilterOption-\(tag.tag)")
                }
                if !library.tagFilter.isEmpty {
                    Button("Clear") { library.tagFilter = [] }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

/// What *Recents* goes by: added, looked at, changed, or any, and how far back.
struct RecentsBar: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        HStack {
            Picker("Show", selection: $library.recentsKind) {
                Text("All").tag(Recents.Kind.all)
                Text("Added").tag(Recents.Kind.added)
                Text("Viewed").tag(Recents.Kind.viewed)
                Text("Modified").tag(Recents.Kind.modified)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Within", selection: $library.recentsDays) {
                Text("Today").tag(1)
                Text("Last 7 Days").tag(7)
                Text("Last 14 Days").tag(14)
                Text("Last 30 Days").tag(30)
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
