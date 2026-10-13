import SwiftUI
import SwiftData
import StashCore

/// DEVONthink's concordance: the words used across the items chosen, the
/// list showing, or the whole library, with how often and in how many. As
/// a list, or a cloud; choosing a word searches for it.
struct ConcordanceView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Query private var allItems: [Item]
    var showsDone = true

    enum Scope: String, CaseIterable, Identifiable {
        case selected = "Selected Items", shown = "Items Shown", library = "Whole Library"
        var id: String { rawValue }
    }

    enum Order: String, CaseIterable, Identifiable {
        case frequency = "Most Used", alphabetical = "A to Z"
        var id: String { rawValue }
    }

    @State private var scope: Scope = .shown
    @State private var order: Order = .frequency
    @State private var showsCloud = false
    @State private var filter = ""
    @State private var words: [Concordance.Word] = []
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                if isWorking {
                    ProgressView("Counting words…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shownWords.isEmpty {
                    ContentUnavailableView("No Words", systemImage: "textformat.abc",
                                           description: Text(scope == .selected ? "Choose some items first." : "There's no text here to count."))
                } else if showsCloud {
                    ScrollView { WordCloud(words: Array(shownWords.prefix(120)), choose: choose).padding() }
                } else {
                    List(shownWords.prefix(2000), id: \.word) { word in
                        Button { choose(word.word) } label: {
                            HStack {
                                Text(word.word)
                                Spacer()
                                Text("\(word.count)").monospacedDigit()
                                Text(word.documents == 1 ? "in 1 item" : "in \(word.documents) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 80, alignment: .trailing)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Concordance")
            .searchable(text: $filter, prompt: "Find a word")
            .toolbar {
                if showsDone {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
        }
        .sheetSize(minWidth: 480, minHeight: 520)
        .task(id: scope) { await count() }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Words In", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Picker("Show", selection: $showsCloud) {
                    Text("List").tag(false)
                    Text("Cloud").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if !showsCloud {
                    Picker("Order", selection: $order) {
                        ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text("\(words.count) words").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private var shownWords: [Concordance.Word] {
        let filtered = filter.isEmpty ? words : words.filter { $0.word.localizedStandardContains(filter) }
        return order == .alphabetical && !showsCloud ? filtered.sorted { $0.word < $1.word } : filtered
    }

    private func count() async {
        isWorking = true
        let items: [Item]
        switch scope {
        case .selected: items = library.selectedItems
        case .shown: items = library.visibleItems(from: allItems)
        case .library: items = allItems
        }
        words = await library.concordance(of: items)
        isWorking = false
    }

    private func choose(_ word: String) {
        library.searchText = word
        if showsDone { dismiss() }
    }
}

/// Words sized by how often they're used, flowing in lines.
private struct WordCloud: View {
    let words: [Concordance.Word]
    let choose: (String) -> Void

    var body: some View {
        let weights = Concordance.weights(words)
        // In alphabetical order, as clouds usually are; size says how common.
        FlowLayout(spacing: 8) {
            ForEach(words.sorted { $0.word < $1.word }, id: \.word) { word in
                let weight = weights[word.word] ?? 0
                Button(word.word) { choose(word.word) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12 + 26 * weight, weight: weight > 0.6 ? .semibold : .regular))
                    .foregroundStyle(Color.accentColor.opacity(0.45 + 0.55 * weight))
                    .help("\(word.count) times, in \(word.documents) items")
            }
        }
    }
}
