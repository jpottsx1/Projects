import SwiftData
import SwiftUI
import StashCore

/// One question asked of the library, and what came back.
struct LibraryAnswer: Identifiable {
    let id = UUID()
    var question: String
    var answer: String?
    var error: String?
    /// The items the answer was given from, in the order of their numbers.
    var sources: [Item] = []
    /// The numbers the answer actually cites.
    var cited: [Int] = []
}

extension Library {
    /// How many items the model is given to answer from.
    static let questionSources = 5

    /// The items most likely to answer a question, best first: found by its
    /// telling words, leaving out what's locked, in the Trash, or a template.
    func sources(for question: String) -> [Item] {
        let words = LibraryQuestion.searchWords(in: question)
        guard let index, let expression = SearchQuery.anyWord(words) else { return [] }
        let ids = index.search(expression, limit: 40)
        return items(withIDs: ids)
            .filter { !$0.isTrashed && !$0.isLocked && !$0.isTemplate }
            .prefix(Self.questionSources)
            .map { $0 }
    }

    func ask(_ question: String) async -> LibraryAnswer {
        var result = LibraryAnswer(question: question)
        let found = sources(for: question)
        guard !found.isEmpty else {
            result.answer = "Nothing in the library seems to be about that."
            return result
        }
        let words = LibraryQuestion.searchWords(in: question)
        let sources = found.map { item in
            LibraryQuestion.Source(title: item.displayTitle,
                                   passage: LibraryQuestion.passage(in: Assistant.text(of: item, limit: 20_000), words: words))
        }
        do {
            let answer = try await Assistant.answer(question, from: sources)
            result.answer = answer
            result.sources = found
            result.cited = LibraryQuestion.citations(in: answer, sourceCount: found.count)
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }
}

/// Ask Your Library: questions about everything in Stash, answered on the
/// device from the items that seem to know, which are listed to open.
struct AskLibraryView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answers: [LibraryAnswer] = []
    @State private var isAsking = false
    @FocusState private var focused: Bool
    var showsDone = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch Assistant.status {
                case .available:
                    conversation
                case .notReady(let reason):
                    ContentUnavailableView("Not Ready Yet", systemImage: "sparkles", description: Text(reason))
                case .unsupported:
                    ContentUnavailableView("Not Available", systemImage: "sparkles",
                                           description: Text("Asking your library needs Apple Intelligence, on iOS or macOS 26."))
                }
            }
            .navigationTitle("Ask Your Library")
            .toolbar {
                if showsDone {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .sheetSize(minWidth: 480, minHeight: 420)
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if answers.isEmpty {
                        Text("Ask about anything you’ve saved: “What did I note about the boiler?”, “Which articles were about sleep?” Answers come from your items, on this device, with the ones they’re from listed.")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(answers) { exchange in
                            AnswerView(exchange: exchange)
                                .id(exchange.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: answers.last?.id) {
                    if let last = answers.last?.id { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
            Divider()
            HStack {
                TextField("Ask a question", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(ask)
                    .accessibilityIdentifier("libraryQuestion")
                if isAsking {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: ask) {
                        Label("Ask", systemImage: "arrow.up.circle.fill")
                            .labelStyle(.iconOnly)
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding()
        }
        .onAppear { focused = true }
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAsking else { return }
        question = ""
        isAsking = true
        answers.append(LibraryAnswer(question: text))
        let index = answers.count - 1
        Task {
            answers[index] = await library.ask(text)
            isAsking = false
        }
    }
}

private struct AnswerView: View {
    @Environment(Library.self) private var library
    let exchange: LibraryAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(exchange.question)
                .bold()
                .frame(maxWidth: .infinity, alignment: .leading)
            if let answer = exchange.answer {
                Text(answer)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("libraryAnswer")
                if !exchange.sources.isEmpty {
                    let shown = exchange.cited.isEmpty ? Array(1...exchange.sources.count) : exchange.cited
                    VStack(alignment: .leading, spacing: 4) {
                        Text(exchange.cited.isEmpty ? "Looked at" : "From")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(shown, id: \.self) { number in
                            let item = exchange.sources[number - 1]
                            Button {
                                library.show(item)
                            } label: {
                                Label("[\(number)] \(item.displayTitle)", systemImage: item.systemImage)
                                    .font(.callout)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("librarySource")
                        }
                    }
                }
            } else if let error = exchange.error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}
