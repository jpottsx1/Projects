import Charts
import SwiftData
import SwiftUI
import StashCore

extension Library {
    /// A light record of everything not in the Trash, for the statistics.
    func statisticsRecords() -> [LibraryStats.Record] {
        let items = (try? context.fetch(FetchDescriptor<Item>(predicate: #Predicate { $0.trashedAt == nil && !$0.isTemplate }))) ?? []
        return items.map { item in
            var category = item.category
            while let parent = category?.parent { category = parent }
            return LibraryStats.Record(
                kind: item.kind.rawValue, created: item.createdAt,
                words: item.kind == .note && !item.isLocked ? LibraryStats.wordCount(item.body) : 0,
                tags: item.sortedTags.map(\.name), category: category?.name,
                highlights: (item.highlights ?? []).count,
                isQueued: item.readLaterAt != nil, progress: item.readingProgress,
                feed: item.feed?.title)
        }
    }
}

/// How the library has grown and been used.
struct StatisticsView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    var showsDone = true
    @State private var stats: LibraryStats?

    var body: some View {
        NavigationStack {
            Group {
                if let stats {
                    content(stats)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Statistics")
            .toolbar {
                if showsDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .sheetSize(minWidth: 560, minHeight: 600)
        .task(id: library.storeVersion) {
            let records = library.statisticsRecords()
            stats = await Task.detached(priority: .userInitiated) { LibraryStats(records) }.value
        }
    }

    private func content(_ stats: LibraryStats) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                totals(stats)
                section("Added Each Month") {
                    Chart {
                        ForEach(stats.months) { month in
                            ForEach(ItemKind.allCases) { kind in
                                BarMark(x: .value("Month", month.start, unit: .month),
                                        y: .value("Items", month.counts[kind.rawValue] ?? 0))
                                    .foregroundStyle(by: .value("Kind", kind.pluralName))
                            }
                        }
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                        AxisGridLine()
                    } }
                    .frame(height: 200)
                    .accessibilityIdentifier("monthlyChart")
                }
                section("Words Written in New Notes") {
                    Chart(stats.months) { month in
                        LineMark(x: .value("Month", month.start, unit: .month), y: .value("Words", month.words))
                        PointMark(x: .value("Month", month.start, unit: .month), y: .value("Words", month.words))
                    }
                    .frame(height: 140)
                }
                HStack(alignment: .top, spacing: 24) {
                    ranking("Top Tags", stats.topTags.map { .init(name: "#" + $0.name, count: $0.count) })
                    ranking("Top Categories", stats.topCategories)
                }
                HStack(alignment: .top, spacing: 24) {
                    section("Reading") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(stats.queued) in Read Later, \(stats.finished) read to the end")
                            if stats.queued > 0 {
                                ProgressView(value: Double(stats.finished), total: Double(stats.queued))
                            }
                            Text("\(stats.highlights) highlights")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ranking("Feed Posts, Last 30 Days", stats.feedPosts)
                }
            }
            .padding()
        }
    }

    private func totals(_ stats: LibraryStats) -> some View {
        HStack(spacing: 12) {
            tile("\(stats.total)", "Items")
            ForEach(ItemKind.allCases) { kind in
                tile("\(stats.byKind[kind.rawValue] ?? 0)", kind.pluralName)
            }
            tile(stats.words.formatted(), "Words in Notes")
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func ranking(_ title: String, _ counts: [LibraryStats.Count]) -> some View {
        section(title) {
            if counts.isEmpty {
                Text("None yet.").foregroundStyle(.secondary)
            } else {
                Chart(counts) { count in
                    BarMark(x: .value("Count", count.count), y: .value("Name", count.name))
                        .annotation(position: .trailing) {
                            Text("\(count.count)").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartYAxis { AxisMarks { _ in AxisValueLabel() } }
                .frame(height: CGFloat(max(counts.count, 1)) * 24 + 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
