import SwiftUI
import SwiftData
import StashCore

/// Apple Intelligence in the side panel: summarise, suggest tags and a
/// category, and ask about the item. Left out where it can't run.
struct AssistantSection: View {
    @Environment(Library.self) private var library
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @Query(sort: \ItemCategory.name) private var categories: [ItemCategory]
    let item: Item

    @State private var summary: String?
    @State private var suggestions: Assistant.Suggestions?
    @State private var question = ""
    @State private var answer: String?
    @State private var working: String?
    @State private var failure: String?

    var body: some View {
        switch Assistant.status {
        case .unsupported:
            EmptyView()
        case .notReady(let message):
            Section("Apple Intelligence") {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        case .available:
            Section {
                Button("Summarize") { run("Summarizing…") { summary = try await Assistant.summarize(text) } }
                if let summary {
                    Text(summary).textSelection(.enabled)
                    Button("Add Summary to Notes") {
                        item.body = item.body.isEmpty ? summary : item.body + "\n\n" + summary
                        library.didEdit(item)
                        self.summary = nil
                    }
                }
                Button("Suggest Tags & Category") {
                    run("Thinking…") {
                        suggestions = try await Assistant.suggest(for: text, tags: allTags.map(\.name),
                                                                  categories: categories.map(\.name))
                    }
                }
                if let suggestions { suggestionButtons(suggestions) }
                HStack {
                    TextField("Ask about this", text: $question)
                        .onSubmit(ask)
                    Button("Ask", action: ask)
                        .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let answer {
                    Text(answer).textSelection(.enabled)
                }
                if let working {
                    ProgressView(working).controlSize(.small)
                }
                if let failure {
                    Text(failure).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text("On this device; nothing is sent anywhere.")
            }
            .buttonStyle(.borderless)
            .disabled(working != nil)
            .onChange(of: item.uuid) {
                summary = nil
                suggestions = nil
                answer = nil
            }
        }
    }

    private var text: String { Assistant.text(of: item) }

    @ViewBuilder
    private func suggestionButtons(_ suggestions: Assistant.Suggestions) -> some View {
        let newTags = suggestions.tags.filter { !item.hasTag(key: TagName.key($0)) }
        if !newTags.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(newTags, id: \.self) { tag in
                    Button("+ #" + tag) { library.addTags(from: tag, to: item) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        if let name = suggestions.category, item.category?.name.lowercased() != name.lowercased() {
            let existing = categories.first { $0.name.lowercased() == name.lowercased() }
            Button(existing != nil ? "File in “\(name)”" : "File in New Category “\(name)”") {
                let category = existing ?? library.newCategory(named: name)
                library.file([item], in: category)
            }
        }
    }

    private func ask() {
        let question = question.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else { return }
        run("Reading…") { answer = try await Assistant.ask(question, about: text) }
    }

    private func run(_ label: String, _ work: @escaping () async throws -> Void) {
        failure = nil
        working = label
        Task {
            do {
                try await work()
            } catch {
                failure = error.localizedDescription
            }
            working = nil
        }
    }
}
